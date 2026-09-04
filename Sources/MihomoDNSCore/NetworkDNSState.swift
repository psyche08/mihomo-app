import Foundation
import SystemConfiguration

// These public SystemConfiguration symbols are present on macOS but are not
// imported by the Swift module map in every SDK/Xcode combination.
@_silgen_name("SCDynamicStoreCopyDHCPInfo")
private func copyDHCPInfo(
    _ store: SCDynamicStore?,
    _ serviceID: CFString?
) -> Unmanaged<CFDictionary>?

@_silgen_name("DHCPInfoGetOptionData")
private func dhcpInfoGetOptionData(
    _ info: CFDictionary,
    _ code: UInt8
) -> Unmanaged<CFData>?

public struct DNSUpstreamSelection: Equatable {
    public var interfaceName: String?
    public var serviceID: String?
    public var servers: [String]

    public init(interfaceName: String?, serviceID: String?, servers: [String]) {
        self.interfaceName = interfaceName
        self.serviceID = serviceID
        self.servers = servers
    }
}

public struct SplitDNSRoute: Equatable {
    public var domain: String
    public var matchOrder: Int
    public var upstream: DNSUpstreamSelection

    public init(domain: String, matchOrder: Int = Int.max, upstream: DNSUpstreamSelection) {
        self.domain = Self.normalize(domain)
        self.matchOrder = matchOrder
        self.upstream = upstream
    }

    fileprivate static func normalize(_ domain: String) -> String {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}

public struct NetworkDNSSnapshot: Equatable {
    public var interfaceName: String?
    public var serviceID: String?
    public var servers: [String]
    public var splitRoutes: [SplitDNSRoute]

    public init(
        interfaceName: String?,
        serviceID: String?,
        servers: [String],
        splitRoutes: [SplitDNSRoute] = []
    ) {
        self.interfaceName = interfaceName
        self.serviceID = serviceID
        self.servers = servers
        self.splitRoutes = splitRoutes
    }

    public func upstream(for questionName: String?) -> DNSUpstreamSelection {
        let defaultUpstream = DNSUpstreamSelection(
            interfaceName: interfaceName,
            serviceID: serviceID,
            servers: servers
        )
        guard let questionName else { return defaultUpstream }
        let name = SplitDNSRoute.normalize(questionName)
        guard !name.isEmpty else { return defaultUpstream }
        return splitRoutes
            .filter { route in
                name == route.domain || name.hasSuffix(".\(route.domain)")
            }
            .sorted { lhs, rhs in
                if lhs.domain.count != rhs.domain.count {
                    return lhs.domain.count > rhs.domain.count
                }
                return lhs.matchOrder < rhs.matchOrder
            }
            .first?.upstream ?? defaultUpstream
    }
}

private func dynamicStoreCallback(
    store: SCDynamicStore,
    changedKeys: CFArray,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<NetworkDNSState>.fromOpaque(info).takeUnretainedValue().refresh(signal: .dynamicStore)
}

private func preferencesCallback(
    preferences: SCPreferences,
    notificationType: SCPreferencesNotification,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<NetworkDNSState>.fromOpaque(info).takeUnretainedValue()
        .preferencesChanged(preferences, notificationType: notificationType)
}

public enum NetworkChangeSignal: String, Sendable {
    case dynamicStore = "dynamic_store"
    case preferencesCommit = "preferences_commit"
    case preferencesApply = "preferences_apply"
    case routeTable = "route_table"

    static func fromPreferencesNotification(
        _ notificationType: SCPreferencesNotification
    ) -> Self? {
        if notificationType.contains(.apply) {
            return .preferencesApply
        }
        if notificationType.contains(.commit) {
            return .preferencesCommit
        }
        return nil
    }
}

public final class NetworkDNSState: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.network")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let excludedServers: Set<String>
    private let fallbackServers: [String]
    private let preferencesID: String?
    private var value: NetworkDNSSnapshot
    private var store: SCDynamicStore?
    private var preferences: SCPreferences?
    private var refreshHandler: (@Sendable (NetworkChangeSignal) -> Void)?

    public init(
        excludedServers: Set<String>,
        fallbackServers: [String],
        preferencesID: String? = nil
    ) {
        self.excludedServers = excludedServers
        self.fallbackServers = fallbackServers
        self.preferencesID = preferencesID
        self.value = NetworkDNSSnapshot(interfaceName: nil, serviceID: nil, servers: fallbackServers)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start() throws {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil,
            "dev.linsheng.mihomo-app.daemon" as CFString,
            dynamicStoreCallback,
            &context
        ) else {
            throw NetworkDNSStateError.dynamicStoreUnavailable
        }
        let keys = [
            "State:/Network/Global/IPv4" as CFString,
            "State:/Network/Global/IPv6" as CFString,
            "State:/Network/Global/DNS" as CFString,
        ] as CFArray
        let patterns = [
            "State:/Network/Service/.*/DNS" as CFString,
            "State:/Network/Service/.*/IPv4" as CFString,
            "State:/Network/Service/.*/IPv6" as CFString,
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, patterns),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            throw NetworkDNSStateError.notificationSetupFailed
        }
        var preferencesContext = SCPreferencesContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let preferences = SCPreferencesCreate(
            nil,
            "dev.linsheng.mihomo-app.daemon.observer" as CFString,
            preferencesID as CFString?
        ) else {
            SCDynamicStoreSetDispatchQueue(store, nil)
            throw NetworkDNSStateError.preferencesUnavailable
        }
        guard SCPreferencesSetCallback(preferences, preferencesCallback, &preferencesContext),
              SCPreferencesSetDispatchQueue(preferences, queue) else {
            SCPreferencesSetCallback(preferences, nil, nil)
            SCDynamicStoreSetDispatchQueue(store, nil)
            throw NetworkDNSStateError.preferencesNotificationSetupFailed
        }
        self.store = store
        self.preferences = preferences
        refresh(signal: nil)
    }

    public func snapshot() -> NetworkDNSSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func setRefreshHandler(_ handler: (@Sendable (NetworkChangeSignal) -> Void)?) {
        lock.lock()
        refreshHandler = handler
        lock.unlock()
    }

    public func handleRouteTableChange() {
        queue.async { [weak self] in
            self?.refresh(signal: .routeTable)
        }
    }

    public func stop() {
        setRefreshHandler(nil)
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        if let preferences {
            SCPreferencesSetDispatchQueue(preferences, nil)
            SCPreferencesSetCallback(preferences, nil, nil)
        }
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
        store = nil
        preferences = nil
    }

    fileprivate func preferencesChanged(
        _ preferences: SCPreferences,
        notificationType: SCPreferencesNotification
    ) {
        // Discard the observer session's cached snapshot before the consistency
        // controller reads Setup:/ and State:/ through its own sessions.
        SCPreferencesSynchronize(preferences)
        if let signal = NetworkChangeSignal.fromPreferencesNotification(notificationType) {
            if signal == .preferencesApply {
                refresh(signal: signal)
            } else {
                signalChange(signal)
            }
        }
    }

    fileprivate func refresh(signal: NetworkChangeSignal?) {
        guard let store else { return }
        let previous = snapshot()
        let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
            as? [String: Any]
        let globalIPv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString)
            as? [String: Any]
        let serviceID = (globalIPv4?["PrimaryService"] as? String)
            ?? (globalIPv6?["PrimaryService"] as? String)
        let interfaceName = (globalIPv4?["PrimaryInterface"] as? String)
            ?? (globalIPv6?["PrimaryInterface"] as? String)

        let dhcpCandidates = serviceID.map { dhcpServers(store: store, serviceID: $0) } ?? []
        var serviceServers: [String] = []

        if let serviceID {
            let key = "State:/Network/Service/\(serviceID)/DNS" as CFString
            let dns = SCDynamicStoreCopyValue(store, key) as? [String: Any]
            serviceServers = dns?["ServerAddresses"] as? [String] ?? []
        }

        let globalDNS = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString)
            as? [String: Any]
        let globalServers = globalDNS?["ServerAddresses"] as? [String] ?? []
        var servers = selectDiscoveredServers(
            dhcpServers: dhcpCandidates,
            serviceServers: serviceServers,
            globalServers: globalServers
        )
        if servers.isEmpty,
           serviceID == previous.serviceID,
           interfaceName == previous.interfaceName,
           !previous.servers.isEmpty {
            // Static/manual DNS disappears from the live service dictionary
            // after that service is pointed at our loopback bridge. Retain only
            // within the same service/interface identity; never leak it across
            // a PrimaryService transition.
            servers = previous.servers
        }
        if servers.isEmpty {
            servers = unique(fallbackServers.filter(isUsableServer))
        }

        let splitRoutes = readSplitRoutes(
            store: store,
            primaryServiceID: serviceID,
            primaryInterfaceName: interfaceName,
            primaryServers: servers
        )

        lock.lock()
        var retainedInterface = interfaceName
        var retainedService = serviceID
        if servers.isEmpty, !previous.servers.isEmpty {
            servers = previous.servers
            retainedInterface = previous.interfaceName
            retainedService = previous.serviceID
        }
        let next = NetworkDNSSnapshot(
            interfaceName: retainedInterface,
            serviceID: retainedService,
            servers: servers,
            splitRoutes: splitRoutes
        )
        value = next
        let handler = refreshHandler
        lock.unlock()

        if previous != next {
            let interfaceDescription = next.interfaceName ?? "none"
            ServiceLog.info(
                "event=network_dns_changed interface=\(interfaceDescription) " +
                "upstream_count=\(next.servers.count) split_route_count=\(next.splitRoutes.count)"
            )
        }
        if let signal {
            handler?(signal)
        }
    }

    private func signalChange(_ signal: NetworkChangeSignal) {
        lock.lock()
        let handler = refreshHandler
        lock.unlock()
        handler?(signal)
    }

    func selectDiscoveredServers(
        dhcpServers: [String],
        serviceServers: [String],
        globalServers: [String]
    ) -> [String] {
        for candidates in [dhcpServers, serviceServers, globalServers] {
            let usable = unique(candidates.filter(isUsableServer))
            if !usable.isEmpty {
                return usable
            }
        }
        return []
    }

    private func readSplitRoutes(
        store: SCDynamicStore,
        primaryServiceID: String?,
        primaryInterfaceName: String?,
        primaryServers: [String]
    ) -> [SplitDNSRoute] {
        guard let keys = SCDynamicStoreCopyKeyList(
            store,
            "State:/Network/Service/.*/DNS" as CFString
        ) as? [String] else {
            return []
        }
        var routes: [SplitDNSRoute] = []
        for key in keys.sorted() {
            let components = key.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 5,
                  components[0] == "State:",
                  components[1] == "Network",
                  components[2] == "Service",
                  components[4] == "DNS" else {
                continue
            }
            let serviceID = String(components[3])
            guard let dns = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
                continue
            }
            let domains = dns["SupplementalMatchDomains"] as? [String] ?? []
            let orders = dns["SupplementalMatchOrders"] as? [Int] ?? []
            guard !domains.isEmpty else { continue }

            var routeServers = unique(
                (dns[kSCPropNetDNSServerAddresses as String] as? [String] ?? []).filter(isUsableServer)
            )
            if routeServers.isEmpty {
                routeServers = unique(dhcpServers(store: store, serviceID: serviceID).filter(isUsableServer))
            }
            if routeServers.isEmpty, serviceID == primaryServiceID {
                routeServers = primaryServers
            }
            guard !routeServers.isEmpty else { continue }

            let interface = serviceInterfaceName(store: store, serviceID: serviceID)
                ?? (serviceID == primaryServiceID ? primaryInterfaceName : nil)
            let upstream = DNSUpstreamSelection(
                interfaceName: interface,
                serviceID: serviceID,
                servers: routeServers
            )
            for (index, rawDomain) in domains.enumerated() {
                let domain = SplitDNSRoute.normalize(rawDomain)
                // A root scoped resolver requires client/interface provenance,
                // which is lost after macOS sends the query to the loopback bridge.
                guard !domain.isEmpty else { continue }
                routes.append(SplitDNSRoute(
                    domain: domain,
                    matchOrder: index < orders.count ? orders[index] : Int.max,
                    upstream: upstream
                ))
            }
        }
        return routes
    }

    private func serviceInterfaceName(store: SCDynamicStore, serviceID: String) -> String? {
        for family in ["IPv4", "IPv6"] {
            let key = "State:/Network/Service/\(serviceID)/\(family)" as CFString
            if let state = SCDynamicStoreCopyValue(store, key) as? [String: Any],
               let interface = state["InterfaceName"] as? String,
               !interface.isEmpty {
                return interface
            }
        }
        return nil
    }

    private func dhcpServers(store: SCDynamicStore, serviceID: String) -> [String] {
        guard let info = copyDHCPInfo(store, serviceID as CFString)?.takeRetainedValue(),
              let option = dhcpInfoGetOptionData(info, 6)?.takeUnretainedValue() else {
            return []
        }
        let bytes = Data(option as Data)
        guard bytes.count % 4 == 0 else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            "\(bytes[offset]).\(bytes[offset + 1]).\(bytes[offset + 2]).\(bytes[offset + 3])"
        }
    }

    private func isUsableServer(_ server: String) -> Bool {
        guard !excludedServers.contains(server), server != "0.0.0.0", server != "::" else {
            return false
        }
        if server.hasPrefix("127.") || server == "::1" || server.hasPrefix("198.18.") || server.hasPrefix("198.19.") {
            return false
        }
        return true
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public enum NetworkDNSStateError: Error {
    case dynamicStoreUnavailable
    case notificationSetupFailed
    case preferencesUnavailable
    case preferencesNotificationSetupFailed
}
