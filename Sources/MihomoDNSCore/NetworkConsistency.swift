import Darwin
import Foundation

public final class NetworkSafetyState: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimeReady = false

    public init() {}

    public func setRuntimeReady(_ ready: Bool) {
        lock.lock()
        runtimeReady = ready
        lock.unlock()
    }

    public func isRuntimeReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runtimeReady
    }
}

public enum DNSCacheMaintenance {
    public static func flushSystemCaches() {
        run("/usr/bin/dscacheutil", arguments: ["-flushcache"])
        run("/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    }

    private static func run(_ path: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
}

public struct NetworkConsistencyHealth: Codable, Equatable {
    public var controllerReachable: Bool
    public var tunEnabled: Bool
    public var tunInterface: String?
    public var fakeIPMode: Bool
    public var fakeIPRouteReady: Bool
    public var dnsBridgeReady: Bool
    public var mihomoDNSReady: Bool
    public var systemDNSManaged: Bool
    public var networkConsistent: Bool

    enum CodingKeys: String, CodingKey {
        case controllerReachable = "controller_reachable"
        case tunEnabled = "tun_enabled"
        case tunInterface = "tun_interface"
        case fakeIPMode = "fake_ip_mode"
        case fakeIPRouteReady = "fake_ip_route_ready"
        case dnsBridgeReady = "dns_bridge_ready"
        case mihomoDNSReady = "mihomo_dns_ready"
        case systemDNSManaged = "system_dns_managed"
        case networkConsistent = "network_consistent"
    }
}

enum RuntimeRecoveryDecision: Equatable {
    case none
    case debounce
    case start
    case wait
    case recovered
    case failed
}

struct RuntimeRecoveryPolicy {
    private(set) var deadlineNanoseconds: UInt64?
    private(set) var consecutiveFailures = 0
    let graceNanoseconds: UInt64
    let requiredFailures: Int

    init(graceSeconds: UInt64 = 8, requiredFailures: Int = 3) {
        graceNanoseconds = graceSeconds * 1_000_000_000
        self.requiredFailures = max(1, requiredFailures)
    }

    mutating func decide(runtimeReady: Bool, networkOwned: Bool, nowNanoseconds: UInt64) -> RuntimeRecoveryDecision {
        if runtimeReady {
            let recovered = deadlineNanoseconds != nil
            deadlineNanoseconds = nil
            consecutiveFailures = 0
            return recovered ? .recovered : .none
        }
        guard networkOwned else {
            deadlineNanoseconds = nil
            consecutiveFailures = 0
            return .none
        }
        if let deadlineNanoseconds {
            if nowNanoseconds < deadlineNanoseconds {
                return .wait
            }
            self.deadlineNanoseconds = nil
            consecutiveFailures = 0
            return .failed
        }
        consecutiveFailures += 1
        guard consecutiveFailures >= requiredFailures else {
            return .debounce
        }
        consecutiveFailures = 0
        deadlineNanoseconds = nowNanoseconds &+ graceNanoseconds
        return .start
    }
}

public enum MihomoRuntimeInspector {
    private static let defaultController = Endpoint(host: "127.0.0.1", port: 9090)
    private static let fakeIPProbe = "198.18.0.1"

    public static func inspect(
        configuration: ProxyConfiguration,
        globalDNS: GlobalDNSPreferences? = nil
    ) -> NetworkConsistencyHealth {
        let controller = controllerConfiguration(configuration: configuration)
        let fakeIPMode = configuration.mihomoProcess
            .map { inspectFakeIPMode(path: $0.configPath) } ?? false
        let routeInterface = fakeIPRouteInterface()
        let dnsBridgeReady = dnsEndpointResponds(endpoint: configuration.systemDNSListen)
        let mihomoDNSReady = dnsEndpointResponds(endpoint: configuration.mihomoDNS)
        let systemDNSManaged: Bool
        if let globalDNS {
            systemDNSManaged = ((try? globalDNS.isApplied()) == true) && globalDNS.isEffective()
        } else {
            let preferences = GlobalDNSPreferences(
                servers: [configuration.systemDNSListen.host],
                backupPath: configuration.systemDNSBackupPath
            )
            systemDNSManaged = ((try? preferences.isApplied()) == true) && preferences.isEffective()
        }
        let tunEnabled = controller.tunEnabled
        let routeReady = routeInterface != nil
        let runtimeReady = controller.reachable && tunEnabled && routeReady
            && dnsBridgeReady && mihomoDNSReady
        let networkConsistent = systemDNSManaged ? runtimeReady : (!tunEnabled || routeReady)
        return NetworkConsistencyHealth(
            controllerReachable: controller.reachable,
            tunEnabled: tunEnabled,
            tunInterface: routeInterface,
            fakeIPMode: fakeIPMode,
            fakeIPRouteReady: fakeIPMode && routeReady,
            dnsBridgeReady: dnsBridgeReady,
            mihomoDNSReady: mihomoDNSReady,
            systemDNSManaged: systemDNSManaged,
            networkConsistent: networkConsistent
        )
    }

    static func inspectFakeIPMode(path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var section: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") && trimmed.hasSuffix(":") {
                section = String(trimmed.dropLast())
                continue
            }
            guard section == "dns", line.hasPrefix("  "), !line.hasPrefix("    ") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "enhanced-mode" else { continue }
            let value = parts[1]
                .split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value?.lowercased() == "fake-ip"
        }
        return false
    }

    public static func flushMihomoDNSCaches(configuration: ProxyConfiguration) {
        _ = httpRequest(method: "POST", path: "/cache/fakeip/flush", configuration: configuration)
        _ = httpRequest(method: "POST", path: "/cache/dns/flush", configuration: configuration)
    }

    private static func dnsEndpointResponds(endpoint: Endpoint) -> Bool {
        return (try? SocketDNSClient.query(
            DNSMessage.runtimeHealthQuery,
            endpoint: endpoint,
            timeoutMilliseconds: 2_000,
            interfaceName: nil
        )) != nil
    }

    private static func controllerConfiguration(
        configuration: ProxyConfiguration
    ) -> (reachable: Bool, tunEnabled: Bool) {
        guard let data = httpRequest(method: "GET", path: "/configs", configuration: configuration),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tun = object["tun"] as? [String: Any],
              let enabled = tun["enable"] as? Bool else {
            return (false, false)
        }
        return (true, enabled)
    }

    private static func httpRequest(
        method: String,
        path: String,
        configuration: ProxyConfiguration
    ) -> Data? {
        let controller = configuration.controllerEndpoint ?? defaultController
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(controller.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(controller.host))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let authorization = configuration.controllerSecret
            .flatMap { $0.isEmpty ? nil : "Authorization: Bearer \($0)\r\n" } ?? ""
        let request = "\(method) \(path) HTTP/1.0\r\n" +
            "Host: \(controller.host):\(controller.port)\r\n" + authorization +
            "Content-Length: 0\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { pointer in
            Darwin.send(descriptor, pointer, strlen(pointer), 0)
        }
        guard sent == request.utf8.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while response.count <= 1_048_576 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { return nil }
            response.append(buffer, count: count)
        }
        guard response.starts(with: Data("HTTP/1.1 200".utf8))
                || response.starts(with: Data("HTTP/1.0 200".utf8)),
              let headerRange = response.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        return response.subdata(in: headerRange.upperBound..<response.endIndex)
    }

    private static func fakeIPRouteInterface() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", fakeIPProbe]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" else {
                continue
            }
            let interface = parts[1].trimmingCharacters(in: .whitespaces)
            return interface.hasPrefix("utun") ? interface : nil
        }
        return nil
    }
}

enum DNSBridgeFailureDecision: Equatable {
    case none
    case debounce
    case restoreOriginalDNS
}

struct DNSBridgeFailurePolicy {
    private let requiredFailures: Int
    private var consecutiveFailures = 0

    init(requiredFailures: Int = 3) {
        self.requiredFailures = max(1, requiredFailures)
    }

    mutating func decide(
        bridgeReady: Bool,
        upstreamRuntimeReady: Bool,
        networkOwned: Bool
    ) -> DNSBridgeFailureDecision {
        guard upstreamRuntimeReady, !bridgeReady, networkOwned else {
            consecutiveFailures = 0
            return .none
        }
        consecutiveFailures += 1
        return consecutiveFailures >= requiredFailures ? .restoreOriginalDNS : .debounce
    }
}

public final class NetworkConsistencyController: @unchecked Sendable {
    private let configuration: ProxyConfiguration
    private let globalDNS: GlobalDNSPreferences
    private let aliasManager: LoopbackAliasManager
    private let safetyState: NetworkSafetyState
    private let runtimeRecoveryHandler: @Sendable () -> Void
    private let unsafeRuntimeHandler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.consistency")
    private var timer: DispatchSourceTimer?
    private var previous: NetworkConsistencyHealth?
    private var recoveryPolicy = RuntimeRecoveryPolicy()
    private var bridgeFailurePolicy = DNSBridgeFailurePolicy()

    public init(
        configuration: ProxyConfiguration,
        globalDNS: GlobalDNSPreferences,
        aliasManager: LoopbackAliasManager,
        safetyState: NetworkSafetyState,
        runtimeRecoveryHandler: @escaping @Sendable () -> Void,
        unsafeRuntimeHandler: @escaping @Sendable () -> Void
    ) {
        self.configuration = configuration
        self.globalDNS = globalDNS
        self.aliasManager = aliasManager
        self.safetyState = safetyState
        self.runtimeRecoveryHandler = runtimeRecoveryHandler
        self.unsafeRuntimeHandler = unsafeRuntimeHandler
    }

    public func start() {
        queue.sync {
            evaluate()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(2))
            timer.setEventHandler { [weak self] in self?.evaluate() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stopAndRestore() {
        queue.sync {
            timer?.cancel()
            timer = nil
            safetyState.setRuntimeReady(false)
            restoreSafeNetwork(source: "shutdown")
        }
    }

    public func currentHealth() -> NetworkConsistencyHealth {
        queue.sync {
            MihomoRuntimeInspector.inspect(configuration: configuration, globalDNS: globalDNS)
        }
    }

    private func evaluate() {
        let before = MihomoRuntimeInspector.inspect(configuration: configuration, globalDNS: globalDNS)
        let kernelReady = before.controllerReachable && before.tunEnabled && before.tunInterface != nil
        let upstreamRuntimeReady = kernelReady && before.mihomoDNSReady
        let runtimeReady = upstreamRuntimeReady && before.dnsBridgeReady
        let networkOwned = ((try? globalDNS.isApplied()) == true)
            || globalDNS.isEffective()
            || globalDNS.hasManagedBackup()
        var changed = false
        var action = "observe"
        if runtimeReady && !before.systemDNSManaged {
            do {
                try aliasManager.ensure()
                try globalDNS.apply()
                action = "manage_dns"
                changed = true
            } catch {
                ServiceLog.error("event=network_transition_failed action=manage_dns rollback=restore_dns")
                restoreSafeNetwork(source: "manage_dns_failure")
                action = "manage_dns_failed"
                changed = true
            }
        } else if runtimeReady {
            do {
                try aliasManager.ensure()
            } catch {
                ServiceLog.error("event=network_transition_failed action=repair_loopback_alias")
            }
        }

        let bridgeDecision = bridgeFailurePolicy.decide(
            bridgeReady: before.dnsBridgeReady,
            upstreamRuntimeReady: upstreamRuntimeReady,
            networkOwned: networkOwned
        )
        switch bridgeDecision {
        case .none:
            break
        case .debounce:
            safetyState.setRuntimeReady(false)
            action = "debounce_dns_bridge_failure"
        case .restoreOriginalDNS:
            safetyState.setRuntimeReady(false)
            restoreSafeNetwork(source: "dns_bridge_unhealthy")
            action = "restore_original_dns"
            changed = true
            ServiceLog.error(
                "event=dns_bridge_unhealthy action=restore_original_dns " +
                "mihomo_dns_ready=\(before.mihomoDNSReady)"
            )
        }

        let recoveryDecision = recoveryPolicy.decide(
            runtimeReady: upstreamRuntimeReady,
            networkOwned: networkOwned,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        switch recoveryDecision {
        case .none:
            break
        case .debounce:
            safetyState.setRuntimeReady(false)
            action = "debounce_runtime_failure"
        case .start:
            safetyState.setRuntimeReady(false)
            runtimeRecoveryHandler()
            action = "recover_runtime"
            changed = true
            ServiceLog.error(
                "event=network_drift_detected action=recover_runtime " +
                "controller_ready=\(before.controllerReachable) tun_enabled=\(before.tunEnabled) " +
                "route_ready=\(before.fakeIPRouteReady) " +
                "dns_bridge_ready=\(before.dnsBridgeReady) mihomo_dns_ready=\(before.mihomoDNSReady)"
            )
        case .wait:
            safetyState.setRuntimeReady(false)
            action = "await_runtime_recovery"
        case .recovered:
            action = "runtime_recovered"
            changed = true
            ServiceLog.info("event=network_drift_recovered")
        case .failed:
            safetyState.setRuntimeReady(false)
            if networkOwned {
                restoreSafeNetwork(source: "runtime_unhealthy")
                MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: configuration)
                DNSCacheMaintenance.flushSystemCaches()
                unsafeRuntimeHandler()
                action = "rollback_safe"
                changed = true
            }
        }

        let after = changed
            ? MihomoRuntimeInspector.inspect(configuration: configuration, globalDNS: globalDNS)
            : before
        safetyState.setRuntimeReady(
            after.controllerReachable && after.tunEnabled && after.tunInterface != nil
                && after.dnsBridgeReady && after.mihomoDNSReady && after.systemDNSManaged
        )
        if after != previous {
            let transition = UUID().uuidString
            let oldTUN = previous?.tunEnabled.description ?? "unknown"
            let oldDNS = previous?.systemDNSManaged.description ?? "unknown"
            ServiceLog.info(
                "event=network_consistency transition_id=\(transition) " +
                "source=runtime_observer action=\(action) " +
                "old_tun_enabled=\(oldTUN) " +
                "tun_enabled=\(after.tunEnabled) " +
                "old_system_dns_managed=\(oldDNS) " +
                "fake_ip_mode=\(after.fakeIPMode) " +
                "fake_ip_route_ready=\(after.fakeIPRouteReady) " +
                "dns_bridge_ready=\(after.dnsBridgeReady) " +
                "mihomo_dns_ready=\(after.mihomoDNSReady) " +
                "system_dns_managed=\(after.systemDNSManaged) " +
                "network_consistent=\(after.networkConsistent)"
            )
            previous = after
        }
    }

    private func restoreSafeNetwork(source: String) {
        let dnsRestored = retryRestore(
            source: source,
            component: "system_dns",
            operation: { try globalDNS.restore() },
            verify: {
                (try? globalDNS.isApplied()) != true
                    && !globalDNS.isEffective()
                    && !globalDNS.hasManagedBackup()
            }
        )
        if !dnsRestored {
            ServiceLog.error("event=network_restore_failed source=\(source) component=system_dns")
        }
        let aliasRestored = retryRestore(
            source: source,
            component: "loopback_alias",
            operation: { try aliasManager.removeIfManaged() },
            verify: { !aliasManager.isManaged() }
        )
        if !aliasRestored {
            ServiceLog.error("event=network_restore_failed source=\(source) component=loopback_alias")
        }
    }

    private func retryRestore(
        source: String,
        component: String,
        attempts: Int = 3,
        operation: () throws -> Void,
        verify: () -> Bool
    ) -> Bool {
        let maximumAttempts = max(1, attempts)
        for attempt in 1 ... maximumAttempts {
            do {
                try operation()
                if verify() {
                    if attempt > 1 {
                        ServiceLog.info(
                            "event=network_restore_recovered source=\(source) " +
                            "component=\(component) attempts=\(attempt)"
                        )
                    }
                    return true
                }
            } catch {
                // Retry without persisting SystemConfiguration error details.
            }
            if attempt < maximumAttempts {
                ServiceLog.info(
                    "event=network_restore_retry source=\(source) " +
                    "component=\(component) attempt=\(attempt)"
                )
                Thread.sleep(forTimeInterval: Double(attempt) * 0.1)
            }
        }
        return false
    }
}
