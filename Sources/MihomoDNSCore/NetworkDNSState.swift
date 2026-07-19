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

public struct NetworkDNSSnapshot: Equatable {
    public var interfaceName: String?
    public var serviceID: String?
    public var servers: [String]

    public init(interfaceName: String?, serviceID: String?, servers: [String]) {
        self.interfaceName = interfaceName
        self.serviceID = serviceID
        self.servers = servers
    }
}

private func dynamicStoreCallback(
    store: SCDynamicStore,
    changedKeys: CFArray,
    info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<NetworkDNSState>.fromOpaque(info).takeUnretainedValue().refresh()
}

public final class NetworkDNSState: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.network")
    private let excludedServers: Set<String>
    private let fallbackServers: [String]
    private var value: NetworkDNSSnapshot
    private var store: SCDynamicStore?
    private var refreshHandler: (@Sendable () -> Void)?

    public init(excludedServers: Set<String>, fallbackServers: [String]) {
        self.excludedServers = excludedServers
        self.fallbackServers = fallbackServers
        self.value = NetworkDNSSnapshot(interfaceName: nil, serviceID: nil, servers: fallbackServers)
    }

    deinit {
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
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
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, patterns),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            throw NetworkDNSStateError.notificationSetupFailed
        }
        self.store = store
        refresh()
    }

    public func snapshot() -> NetworkDNSSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func setRefreshHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        refreshHandler = handler
        lock.unlock()
    }

    public func stop() {
        setRefreshHandler(nil)
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        queue.sync {}
        store = nil
    }

    fileprivate func refresh() {
        guard let store else { return }
        let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
            as? [String: Any]
        let globalIPv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString)
            as? [String: Any]
        let serviceID = (globalIPv4?["PrimaryService"] as? String)
            ?? (globalIPv6?["PrimaryService"] as? String)
        let interfaceName = (globalIPv4?["PrimaryInterface"] as? String)
            ?? (globalIPv6?["PrimaryInterface"] as? String)

        var servers: [String] = []
        if let serviceID,
           let info = copyDHCPInfo(store, serviceID as CFString)?.takeRetainedValue(),
           let option = dhcpInfoGetOptionData(info, 6)?.takeUnretainedValue() {
            let bytes = Data(option as Data)
            if bytes.count % 4 == 0 {
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    servers.append("\(bytes[offset]).\(bytes[offset + 1]).\(bytes[offset + 2]).\(bytes[offset + 3])")
                }
            }
        }

        if servers.isEmpty, let serviceID {
            let key = "State:/Network/Service/\(serviceID)/DNS" as CFString
            let dns = SCDynamicStoreCopyValue(store, key) as? [String: Any]
            servers = dns?["ServerAddresses"] as? [String] ?? []
        }

        servers = unique(servers.filter(isUsableServer))
        if servers.isEmpty {
            servers = unique(fallbackServers.filter(isUsableServer))
        }

        lock.lock()
        let previous = value
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
            servers: servers
        )
        value = next
        let handler = refreshHandler
        lock.unlock()

        if previous != next {
            let interfaceDescription = next.interfaceName ?? "none"
            ServiceLog.info("event=network_dns_changed interface=\(interfaceDescription) upstream_count=\(next.servers.count)")
        }
        handler?()
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
}
