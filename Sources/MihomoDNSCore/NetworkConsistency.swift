import CMihomoDNSSystem
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

public struct NetworkConsistencyHealth: Codable, Equatable, Sendable {
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

struct RuntimeDNSHealthProbeResult: Equatable, Sendable {
    var dnsBridgeReady: Bool
    var mihomoDNSReady: Bool
}

enum RuntimeDNSHealthProbePolicy {
    /// The system bridge's exact health query is always sent to Mihomo and may
    /// never use original-DNS fallback. If Mihomo DNS is unavailable, probing
    /// the bridge can only wait for another timeout and still return false.
    static func evaluate(
        mihomoDNS: () -> Bool,
        systemDNSBridge: () -> Bool
    ) -> RuntimeDNSHealthProbeResult {
        guard mihomoDNS() else {
            return RuntimeDNSHealthProbeResult(
                dnsBridgeReady: false,
                mihomoDNSReady: false
            )
        }
        return RuntimeDNSHealthProbeResult(
            dnsBridgeReady: systemDNSBridge(),
            mihomoDNSReady: true
        )
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
    /// Percent-encoded 204 endpoint used for the end-to-end egress probe. Kept
    /// identical to the tray's latency test so both measure the same path.
    private static let egressProbeURL = "https%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204"
    private static let egressProbeTimeoutMilliseconds = 5_000
    private static let egressProbeSocketTimeoutSeconds = 8

    public static func inspect(
        configuration: ProxyConfiguration,
        globalDNS: GlobalDNSPreferences? = nil
    ) -> NetworkConsistencyHealth {
        let controller = controllerConfiguration(configuration: configuration)
        let fakeIPMode = configuration.mihomoProcess
            .map { inspectFakeIPMode(path: $0.configPath) } ?? false
        let routeInterface = fakeIPRouteInterface()
        let dnsHealth = RuntimeDNSHealthProbePolicy.evaluate(
            mihomoDNS: { dnsEndpointResponds(endpoint: configuration.mihomoDNS) },
            systemDNSBridge: {
                dnsEndpointResponds(endpoint: configuration.systemDNSListen)
            }
        )
        let dnsBridgeReady = dnsHealth.dnsBridgeReady
        let mihomoDNSReady = dnsHealth.mihomoDNSReady
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

    /// The configured Fake-IP range, or Mihomo's default when unset.
    static func fakeIPRange(path: String) -> String {
        let fallback = "198.18.0.1/16"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return fallback }
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
            guard parts.count == 2, parts[0] == "fake-ip-range" else { continue }
            let value = parts[1]
                .split(separator: "#", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (value?.isEmpty == false) ? value! : fallback
        }
        return fallback
    }

    public static func flushMihomoDNSCaches(configuration: ProxyConfiguration) {
        _ = httpRequest(method: "POST", path: "/cache/fakeip/flush", configuration: configuration)
        _ = httpRequest(method: "POST", path: "/cache/dns/flush", configuration: configuration)
    }

    /// Probes whether traffic can actually leave and come back through the
    /// selected outbound proxy.
    ///
    /// Unlike every other health signal, this cannot be satisfied locally: the
    /// controller dials the node and fetches a 204 endpoint, so a success proves
    /// the data path works end to end. Returns `.unknown` when no real outbound
    /// proxy is selected (DIRECT/REJECT, or the controller is unreachable),
    /// because in that case a failure would say nothing about the data path.
    static func probeEgress(configuration: ProxyConfiguration) -> EgressProbeOutcome {
        guard let node = selectedOutboundNode(configuration: configuration) else {
            return .unknown
        }
        let query = "timeout=\(egressProbeTimeoutMilliseconds)&url=\(egressProbeURL)"
        // A transport failure here means the *controller* is unreachable, which
        // says nothing about egress — the runtime-recovery policy already owns
        // that case. Only a controller that answers can convict the data path.
        guard let response = httpResponse(
            method: "GET",
            path: "/proxies/\(percentEncoded(node))/delay?\(query)",
            configuration: configuration,
            // The controller applies its own per-node timeout; allow for it plus
            // scheduling slack before giving up on the socket.
            timeoutSeconds: egressProbeSocketTimeoutSeconds
        ) else {
            return .unknown
        }
        guard response.status == 200 else {
            // The controller dialled the node and it failed (mihomo answers a
            // non-2xx carrying a message).
            return .unreachable
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              object["delay"] is NSNumber else {
            return .unreachable
        }
        return .reachable
    }

    /// Resolves the proxy node that the user's traffic actually egresses through.
    ///
    /// This must follow the same path the traffic does, which depends on the
    /// outbound mode: in `global` everything goes through the GLOBAL selector,
    /// but in `rule` — the shipped default — GLOBAL is never written by this app
    /// and sits at its config default (DIRECT), so walking it would either probe
    /// nothing or probe a node that carries no traffic. Returns nil when no real
    /// outbound is involved (direct mode, or the selection resolves to a
    /// built-in), because a failure then says nothing about the data path.
    private static func selectedOutboundNode(configuration: ProxyConfiguration) -> String? {
        guard let data = httpRequest(method: "GET", path: "/proxies", configuration: configuration),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = object["proxies"] as? [String: Any] else {
            return nil
        }
        guard let start = outboundEntryPoint(configuration: configuration) else {
            return nil
        }
        return resolveConcreteOutbound(startingAt: start, proxies: proxies)
    }

    /// The group traffic enters, given the controller's current outbound mode.
    private static func outboundEntryPoint(configuration: ProxyConfiguration) -> String? {
        switch controllerConfiguration(configuration: configuration).mode.lowercased() {
        case "direct":
            // Nothing is proxied; there is no egress node to judge.
            return nil
        case "global":
            return "GLOBAL"
        case "":
            // The mode could not be read (transient controller failure). Guessing
            // would risk convicting a node that carries no traffic, and a wrong
            // verdict costs a kernel restart — so decline to judge.
            return nil
        default:
            // Rule mode (and script/other modes): the catch-all MATCH rule names
            // the group that carries everything not matched more specifically.
            // If there is no usable MATCH rule we deliberately stay dormant
            // rather than probing an arbitrary group.
            return matchRuleTarget(configuration: configuration)
        }
    }

    /// Reads the target of the MATCH rule that actually carries traffic.
    ///
    /// mihomo evaluates rules top-down and MATCH matches everything, so when a
    /// concatenated profile contains more than one MATCH it is the *first* that
    /// wins — scanning backwards would resolve a rule that never fires.
    private static func matchRuleTarget(configuration: ProxyConfiguration) -> String? {
        guard let data = httpRequest(method: "GET", path: "/rules", configuration: configuration),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rules = object["rules"] as? [[String: Any]] else {
            return nil
        }
        for rule in rules {
            guard let type = rule["type"] as? String,
                  type.caseInsensitiveCompare("MATCH") == .orderedSame,
                  let proxy = rule["proxy"] as? String, !proxy.isEmpty else {
                continue
            }
            return proxy
        }
        return nil
    }

    /// Follows nested selectors (PROXY -> sub-group -> node) to a concrete
    /// outbound, guarding against cycles in user-authored group graphs.
    private static func resolveConcreteOutbound(
        startingAt start: String,
        proxies: [String: Any]
    ) -> String? {
        var name = start
        var visited: Set<String> = []
        while visited.insert(name.lowercased()).inserted {
            guard let entry = proxies[name] as? [String: Any],
                  let current = entry["now"] as? String,
                  !current.isEmpty else {
                // Not a group (no "now"): this is already a concrete outbound.
                break
            }
            name = current
        }
        return isBuiltinOutbound(name) ? nil : name
    }

    private static func isBuiltinOutbound(_ name: String) -> Bool {
        switch name.uppercased() {
        case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL":
            return true
        default:
            return false
        }
    }

    private static func percentEncoded(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func dnsEndpointResponds(endpoint: Endpoint) -> Bool {
        return (try? SocketDNSClient.query(
            DNSMessage.runtimeHealthQuery,
            endpoint: endpoint,
            timeoutMilliseconds: 2_000,
            interfaceName: nil
        )) != nil
    }

    /// Re-probes only the loopback system-DNS bridge after the alias has been
    /// repaired. A full runtime inspection would repeat controller, route and
    /// both DNS probes, turning a bounded DNS repair into several unrelated
    /// network operations on the consistency queue.
    static func systemDNSBridgeResponds(configuration: ProxyConfiguration) -> Bool {
        dnsEndpointResponds(endpoint: configuration.systemDNSListen)
    }

    private static func controllerConfiguration(
        configuration: ProxyConfiguration
    ) -> (reachable: Bool, tunEnabled: Bool, mode: String) {
        guard let data = httpRequest(method: "GET", path: "/configs", configuration: configuration),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tun = object["tun"] as? [String: Any],
              let enabled = tun["enable"] as? Bool else {
            return (false, false, "")
        }
        return (true, enabled, object["mode"] as? String ?? "")
    }

    struct ControllerResponse {
        let status: Int
        let body: Data
    }

    /// Body of a 200 response, or nil for any non-200 or transport failure.
    private static func httpRequest(
        method: String,
        path: String,
        configuration: ProxyConfiguration,
        timeoutSeconds: Int = 1
    ) -> Data? {
        guard let response = httpResponse(
            method: method,
            path: path,
            configuration: configuration,
            timeoutSeconds: timeoutSeconds
        ), response.status == 200 else {
            return nil
        }
        return response.body
    }

    /// Full controller response. Returns nil only when the controller could not
    /// be reached at all, which callers must distinguish from an error status:
    /// an unreachable controller is a runtime fault, not an egress verdict.
    private static func httpResponse(
        method: String,
        path: String,
        configuration: ProxyConfiguration,
        timeoutSeconds: Int = 1
    ) -> ControllerResponse? {
        let controller = configuration.controllerEndpoint ?? defaultController
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
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
        guard let headerRange = response.range(of: Data("\r\n\r\n".utf8)),
              let statusLineEnd = response.range(of: Data("\r\n".utf8)),
              let statusLine = String(
                  data: response.subdata(in: response.startIndex ..< statusLineEnd.lowerBound),
                  encoding: .utf8
              ) else {
            return nil
        }
        // "HTTP/1.1 200 OK" -> 200
        let fields = statusLine.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), let status = Int(fields[1]) else {
            return nil
        }
        return ControllerResponse(
            status: status,
            body: response.subdata(in: headerRange.upperBound ..< response.endIndex)
        )
    }

    /// The interface the kernel would route Fake-IP traffic through, or nil
    /// when that is not a tunnel.
    ///
    /// This used to shell out to `/sbin/route -n get` and scrape its output.
    /// The observer asks every two seconds and the daemon asks on every tray
    /// poll, which made it the single largest source of process spawns in the
    /// app — around 2,500 an hour, more than everything else combined. It now
    /// asks the routing socket the same question directly.
    static func fakeIPRouteInterface() -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard mihomo_dns_route_interface(fakeIPProbe, &name, name.count) == 0 else {
            return nil
        }
        let interface = String(cString: name)
        return interface.hasPrefix("utun") ? interface : nil
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

enum DNSAcquisitionDecision: Equatable {
    case none
    case reacquireBridge
    case manage
    case maintain
}

enum DNSAcquisitionAttemptResult: Equatable {
    case bridgeUnavailable
    case managed
}

/// Executes one bounded system-DNS acquisition attempt.
///
/// A rollback can remove the loopback alias, so an acquisition may begin with
/// a failed bridge probe. Repairing the alias and deferring the second probe to
/// the next two-second observer tick creates a latch when the bridge flaps
/// between ticks. The repair, bridge re-probe and System Configuration write
/// therefore belong to one transaction.
struct DNSAcquisitionAttempt {
    static func run(
        reprobeBridge: Bool,
        ensureAlias: () throws -> Void,
        bridgeReady: () -> Bool,
        applyDNS: () throws -> Void
    ) throws -> DNSAcquisitionAttemptResult {
        try ensureAlias()
        if reprobeBridge, !bridgeReady() {
            return .bridgeUnavailable
        }
        try applyDNS()
        return .managed
    }
}

/// Decides whether the observer should (re)take ownership of system DNS.
///
/// The key case is `reacquireBridge`: after a rollback removes the loopback
/// alias, the system-DNS bridge stops answering, so `dnsBridgeReady` reads
/// false even though the Mihomo runtime is healthy. Because re-management used
/// to require a ready bridge — and the alias was only ensured while managing —
/// the observer could latch into passive observation and never recover on its
/// own until the agent was restarted. Re-ensuring the alias (which never
/// touches system DNS) breaks that latch.
struct DNSAcquisitionPolicy {
    private var backoffUntilNanoseconds: UInt64?
    private(set) var consecutiveFailures = 0
    let initialBackoffNanoseconds: UInt64
    let maximumBackoffNanoseconds: UInt64

    init(initialBackoffSeconds: UInt64 = 5, maximumBackoffSeconds: UInt64 = 120) {
        initialBackoffNanoseconds = initialBackoffSeconds * 1_000_000_000
        maximumBackoffNanoseconds = maximumBackoffSeconds * 1_000_000_000
    }

    mutating func decide(
        upstreamRuntimeReady: Bool,
        dnsBridgeReady: Bool,
        systemDNSManaged: Bool,
        nowNanoseconds: UInt64
    ) -> DNSAcquisitionDecision {
        guard upstreamRuntimeReady else { return .none }
        if systemDNSManaged {
            // Already own system DNS; only keep the alias healthy while the
            // bridge answers. A dropped bridge is left to the bridge-failure
            // policy, which restores original DNS.
            return dnsBridgeReady ? .maintain : .none
        }
        // Taking ownership can fail persistently — most realistically when
        // another network extension is fighting us over macOS DNS. Without a
        // backoff the retry runs at tick rate, and because a failed attempt
        // rolls back (removing the loopback alias) while the next tick
        // re-creates it, 127.0.0.53 would be added and removed every couple of
        // seconds for as long as the conflict lasts.
        if let backoffUntilNanoseconds, nowNanoseconds < backoffUntilNanoseconds {
            return .none
        }
        // Not managing yet. Manage as soon as the bridge answers; otherwise
        // repair the alias so a bridge knocked out by an earlier rollback can
        // recover instead of latching the observer into passive mode.
        return dnsBridgeReady ? .manage : .reacquireBridge
    }

    mutating func recordManageSucceeded() {
        consecutiveFailures = 0
        backoffUntilNanoseconds = nil
    }

    /// Backs off exponentially, so a persistent conflict costs one attempt per
    /// `maximumBackoff` rather than one per tick, while still recovering on its
    /// own once the conflict clears.
    mutating func recordManageFailed(nowNanoseconds: UInt64) {
        consecutiveFailures += 1
        let shift = min(UInt64(consecutiveFailures - 1), 32)
        let scaled = initialBackoffNanoseconds << shift
        let delay = (scaled >> shift) == initialBackoffNanoseconds
            ? min(scaled, maximumBackoffNanoseconds)
            : maximumBackoffNanoseconds
        backoffUntilNanoseconds = nowNanoseconds &+ delay
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
    private var acquisitionPolicy = DNSAcquisitionPolicy()
    private var egressPolicy = EgressProbePolicy()
    private let egressProbe: EgressProbeCoordinator
    /// Set by a wake notification; forces the next tick to re-probe egress
    /// immediately instead of waiting out the probe interval.
    private var forceEgressProbe = false
    /// Sequence of the last probe result folded into `egressPolicy`, so a cached
    /// result is never counted twice.
    private var lastFoldedEgressSequence: UInt64 = 0
    private var immediateEvaluationPending = false
    /// Last egress outcome written to the log, so only changes are recorded.
    private var lastLoggedEgressOutcome: EgressProbeOutcome = .unknown
    /// The proxy-server resolution check runs once per runtime, the first time
    /// the kernel is ready enough to answer.
    private var checkedProxyServerResolution = false
    private let healthSnapshotPath: String?
    private let healthGeneration: RuntimeHealthGeneration
    private var runtimeReloadInProgress = false

    public convenience init(
        configuration: ProxyConfiguration,
        globalDNS: GlobalDNSPreferences,
        aliasManager: LoopbackAliasManager,
        safetyState: NetworkSafetyState,
        runtimeRecoveryHandler: @escaping @Sendable () -> Void,
        unsafeRuntimeHandler: @escaping @Sendable () -> Void,
        healthGeneration: RuntimeHealthGeneration = RuntimeHealthGeneration()
    ) {
        self.init(
            configuration: configuration,
            globalDNS: globalDNS,
            aliasManager: aliasManager,
            safetyState: safetyState,
            runtimeRecoveryHandler: runtimeRecoveryHandler,
            unsafeRuntimeHandler: unsafeRuntimeHandler,
            egressProbe: EgressProbeCoordinator(configuration: configuration),
            healthGeneration: healthGeneration
        )
    }

    init(
        configuration: ProxyConfiguration,
        globalDNS: GlobalDNSPreferences,
        aliasManager: LoopbackAliasManager,
        safetyState: NetworkSafetyState,
        runtimeRecoveryHandler: @escaping @Sendable () -> Void,
        unsafeRuntimeHandler: @escaping @Sendable () -> Void,
        egressProbe: EgressProbeCoordinator,
        healthGeneration: RuntimeHealthGeneration = RuntimeHealthGeneration()
    ) {
        self.configuration = configuration
        self.globalDNS = globalDNS
        self.aliasManager = aliasManager
        self.safetyState = safetyState
        self.runtimeRecoveryHandler = runtimeRecoveryHandler
        self.unsafeRuntimeHandler = unsafeRuntimeHandler
        self.egressProbe = egressProbe
        self.healthGeneration = healthGeneration
        healthSnapshotPath = configuration.healthSnapshotPath
    }

    /// Freezes observation while the owned Mihomo child is replaced and moves
    /// the published-health identity to the daemon-requested generation. The
    /// DNS listeners and Global DNS ownership remain in place, but forwarding
    /// falls back safely until the new child is observed ready.
    public func beginRuntimeReload(generation: String) {
        queue.sync {
            runtimeReloadInProgress = true
            safetyState.setRuntimeReady(false)
            invalidateEgressMeasurement()
            healthGeneration.replace(with: generation)
            if let healthSnapshotPath {
                HealthSnapshotStore.remove(at: healthSnapshotPath)
            }
            previous = nil
            recoveryPolicy = RuntimeRecoveryPolicy()
            bridgeFailurePolicy = DNSBridgeFailurePolicy()
        }
    }

    public func finishRuntimeReload() {
        queue.async { [weak self] in
            guard let self else { return }
            self.runtimeReloadInProgress = false
            guard self.timer != nil else { return }
            self.evaluate(chargeFailures: false)
        }
    }

    /// Runs an evaluation as soon as possible instead of waiting for the next
    /// timer tick. Safe to call from any queue — notably from the
    /// SystemConfiguration notification queue and the IOKit power queue, which
    /// is why the hop is `async` rather than `sync`.
    public func scheduleImmediateEvaluation(reason: String) {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            // SystemConfiguration can fire a burst of callbacks for a single
            // network change; coalesce them so one change costs one evaluation.
            guard !self.immediateEvaluationPending else { return }
            self.immediateEvaluationPending = true
            self.queue.async {
                self.immediateEvaluationPending = false
                guard self.timer != nil else { return }
                ServiceLog.info("event=consistency_revalidation_requested reason=\(reason)")
                self.evaluate(chargeFailures: false)
            }
        }
    }

    /// Called on system wake. The measurements taken before sleep no longer
    /// describe the current network, so the cached egress result is discarded
    /// and the next evaluation re-probes immediately.
    public func handleSystemWake() {
        egressProbe.invalidate()
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
            self.forceEgressProbe = true
            self.egressPolicy.reset()
            ServiceLog.info("event=system_wake action=revalidate")
            self.evaluate(chargeFailures: false)
        }
    }

    /// Called when the system is about to sleep. Any in-flight or cached egress
    /// result would otherwise be carried across the boundary and misread as a
    /// live measurement on wake.
    public func handleSystemSleep() {
        egressProbe.invalidate()
        ServiceLog.info("event=system_sleep action=invalidate_egress")
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
            if let healthSnapshotPath {
                HealthSnapshotStore.remove(at: healthSnapshotPath)
            }
            restoreSafeNetwork(source: "shutdown")
        }
    }

    public func currentHealth() -> NetworkConsistencyHealth {
        queue.sync {
            MihomoRuntimeInspector.inspect(configuration: configuration, globalDNS: globalDNS)
        }
    }

    /// - Parameter chargeFailures: whether this evaluation may advance the
    ///   consecutive-failure counters. `RuntimeRecoveryPolicy` and
    ///   `DNSBridgeFailurePolicy` count *calls*, not time, and were tuned around
    ///   being driven solely by the 2-second timer (3 calls ≈ 6 seconds). Now
    ///   that wakes and network changes can also drive an evaluation, only
    ///   timer-driven ticks are allowed to accrue failures — otherwise a burst
    ///   of SystemConfiguration callbacks would satisfy the threshold instantly
    ///   and restart the kernel. Off-tick evaluations still observe and still
    ///   (re)acquire DNS; they just do not vote towards recovery.
    private func evaluate(chargeFailures: Bool = true) {
        guard !runtimeReloadInProgress else { return }
        let before = MihomoRuntimeInspector.inspect(configuration: configuration, globalDNS: globalDNS)
        let kernelReady = before.controllerReachable && before.tunEnabled && before.tunInterface != nil
        let upstreamRuntimeReady = kernelReady && before.mihomoDNSReady
        let networkOwned = ((try? globalDNS.isApplied()) == true)
            || globalDNS.isEffective()
            || globalDNS.hasManagedBackup()
        var bridgeReadyForPolicies = before.dnsBridgeReady
        var changed = false
        var action = "observe"
        let acquisitionDecision = acquisitionPolicy.decide(
            upstreamRuntimeReady: upstreamRuntimeReady,
            dnsBridgeReady: before.dnsBridgeReady,
            systemDNSManaged: before.systemDNSManaged,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        switch acquisitionDecision {
        case .none:
            break
        case .manage, .reacquireBridge:
            do {
                let result = try DNSAcquisitionAttempt.run(
                    reprobeBridge: acquisitionDecision == .reacquireBridge,
                    ensureAlias: { try aliasManager.ensure() },
                    bridgeReady: {
                        MihomoRuntimeInspector.systemDNSBridgeResponds(
                            configuration: configuration
                        )
                    },
                    applyDNS: { try globalDNS.apply() }
                )
                switch result {
                case .bridgeUnavailable:
                    action = "reacquire_dns_bridge"
                    changed = true
                case .managed:
                    acquisitionPolicy.recordManageSucceeded()
                    bridgeReadyForPolicies = true
                    action = acquisitionDecision == .reacquireBridge
                        ? "reacquire_dns_bridge_and_manage_dns"
                        : "manage_dns"
                    changed = true
                }
            } catch {
                acquisitionPolicy.recordManageFailed(
                    nowNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
                // The numeric SystemConfiguration code is safe to record and is
                // the only thing that makes a persistent conflict diagnosable;
                // no path, server or name is logged.
                ServiceLog.error(
                    "event=network_transition_failed action=manage_dns rollback=restore_dns " +
                    "consecutive=\(acquisitionPolicy.consecutiveFailures) " +
                    "code=\(systemConfigurationCode(error))"
                )
                restoreSafeNetwork(source: "manage_dns_failure")
                action = "manage_dns_failed"
                changed = true
            }
        case .maintain:
            do {
                try aliasManager.ensure()
            } catch {
                ServiceLog.error("event=network_transition_failed action=repair_loopback_alias")
            }
        }

        let bridgeDecision = chargeFailures
            ? bridgeFailurePolicy.decide(
                bridgeReady: bridgeReadyForPolicies,
                upstreamRuntimeReady: upstreamRuntimeReady,
                networkOwned: networkOwned
            )
            : .none
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

        let recoveryDecision = chargeFailures
            ? recoveryPolicy.decide(
                runtimeReady: upstreamRuntimeReady,
                networkOwned: networkOwned,
                nowNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            : .none
        switch recoveryDecision {
        case .none:
            break
        case .debounce:
            safetyState.setRuntimeReady(false)
            action = "debounce_runtime_failure"
        case .start:
            safetyState.setRuntimeReady(false)
            // The kernel is about to be restarted, so any egress measurement
            // describes a runtime that will not exist a moment from now.
            invalidateEgressMeasurement()
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
                invalidateEgressMeasurement()
                restoreSafeNetwork(source: "runtime_unhealthy")
                MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: configuration)
                DNSCacheMaintenance.flushSystemCaches()
                unsafeRuntimeHandler()
                action = "rollback_safe"
                changed = true
            }
        }

        // Egress is only meaningful when the app believes the whole path is up:
        // kernel + DNS bridge + system DNS ownership. If any of those is down,
        // the dedicated policies above already own the response.
        let fullyReady = upstreamRuntimeReady && before.dnsBridgeReady && before.systemDNSManaged
        if upstreamRuntimeReady, !checkedProxyServerResolution {
            checkedProxyServerResolution = true
            reportLoopingProxyServers(tunnelInterface: before.tunInterface)
        }

        if let egressAction = evaluateEgress(runtimeReady: fullyReady) {
            action = egressAction
            changed = true
        }

        let after = changed
            ? MihomoRuntimeInspector.inspect(configuration: configuration, globalDNS: globalDNS)
            : before
        // Publish the reading so the daemon can answer tray polls without
        // repeating this work; it is the most expensive part of a poll.
        if let healthSnapshotPath {
            HealthSnapshotStore.publish(
                HealthSnapshot(health: after, generation: healthGeneration.current()),
                to: healthSnapshotPath
            )
        }
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

    /// Warns when the address a proxy server resolves to is routed back into
    /// the tunnel, which silently prevents every proxied connection from
    /// leaving.
    ///
    /// Nothing else detects this. The config is valid and loads, the interface
    /// is up, DNS answers, direct traffic works, and the health model reports
    /// everything green — because every signal it has is satisfied. Even the
    /// egress probe stays silent, since with no reachable proxy it has nothing
    /// to measure.
    private func reportLoopingProxyServers(tunnelInterface: String?) {
        guard let process = configuration.mihomoProcess else { return }
        let findings = ProxyServerResolution.loopingServers(
            configPath: process.configPath,
            // The escape resolver, which answers with real addresses — the same
            // path the kernel uses for its own proxy servers.
            resolver: configuration.upstreamListen,
            tunnelInterface: tunnelInterface
        )
        for finding in findings {
            ServiceLog.error(
                "event=proxy_server_routed_into_tunnel host=\(finding.host) " +
                "address=\(finding.address) interface=\(finding.interface) " +
                "detail=exclude_the_address_from_tun_auto_route"
            )
        }
    }

    /// Schedules egress probes and folds completed results into a recovery
    /// decision. Returns a transition action when something was acted on.
    ///
    /// The probe itself runs off this queue, so this method never blocks the
    /// 2-second tick; it consumes whatever result was last published.
    private func evaluateEgress(runtimeReady: Bool) -> String? {
        guard runtimeReady else {
            // The runtime is not in a state where egress can be judged. Drop any
            // measurement so it cannot be replayed as a verdict about whatever
            // runtime comes back. This runs on every not-ready tick, so it must
            // not also clear the probe schedule — that would defeat the 60s rate
            // limit the moment readiness returns.
            invalidateEgressMeasurement(rescheduleProbe: false)
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if egressPolicy.isProbeDue(nowNanoseconds: now, forced: forceEgressProbe) {
            // Only consume the interval and the forced flag if a probe really
            // started; otherwise one already in flight would swallow the
            // post-wake revalidation and delay it by a whole interval.
            if egressProbe.schedule() {
                egressPolicy.noteProbeStarted(nowNanoseconds: now)
                forceEgressProbe = false
            }
        }

        // Fold each completed probe exactly once. The consistency timer ticks
        // every 2 seconds while probes run at most once a minute, so counting
        // the cached outcome per tick would turn a single failed probe into a
        // sustained-failure verdict within seconds.
        let reading = egressProbe.latest()
        guard reading.sequence != lastFoldedEgressSequence else { return nil }
        lastFoldedEgressSequence = reading.sequence

        // Record every change in egress state. This is the signal the app
        // previously had no equivalent of at all: under Fake-IP every other
        // health input is answered on loopback, so a data path that stops
        // carrying traffic left no trace anywhere in the logs.
        if reading.outcome != lastLoggedEgressOutcome {
            lastLoggedEgressOutcome = reading.outcome
            ServiceLog.info("event=egress_probe outcome=\(reading.outcome.rawValue)")
        }

        switch egressPolicy.decide(
            outcome: reading.outcome,
            runtimeReady: true,
            nowNanoseconds: now
        ) {
        case .none:
            return nil
        case .debounce:
            ServiceLog.info(
                "event=egress_probe_failed consecutive=\(egressPolicy.consecutiveFailures)"
            )
            return nil
        case .sustainedFailure:
            // Detection only — deliberately no runtime restart. See the doc on
            // EgressRecoveryDecision.sustainedFailure for why.
            ServiceLog.error(
                "event=egress_unhealthy detail=sustained_failure_after_success"
            )
            return "egress_unhealthy"
        }
    }

    /// Drops the current egress measurement and schedules a fresh one, keeping
    /// the folded-sequence cursor in step so the discarded value is never
    /// counted as a new observation.
    /// - Parameter rescheduleProbe: whether the next tick should probe
    ///   immediately rather than waiting out the interval. True for the rare
    ///   kernel-restart paths, where the runtime genuinely changed identity;
    ///   false for the per-tick not-ready path, which would otherwise bypass the
    ///   rate limit on every readiness blip.
    private func invalidateEgressMeasurement(rescheduleProbe: Bool = true) {
        egressProbe.invalidate()
        egressPolicy.reset()
        if rescheduleProbe {
            egressPolicy.clearProbeSchedule()
        }
        lastFoldedEgressSequence = egressProbe.latest().sequence
    }

    /// A log-safe identifier for why taking over system DNS failed: the failing
    /// operation plus its SystemConfiguration error number. Carries no path,
    /// server address or name.
    private func systemConfigurationCode(_ error: Error) -> String {
        guard let error = error as? GlobalDNSPreferencesError else { return "unknown" }
        switch error {
        case .unavailable: return "unavailable"
        case .currentSetMissing: return "current_set_missing"
        case .dynamicStoreUnavailable: return "dynamic_store_unavailable"
        case .primaryServiceMissing: return "primary_service_missing"
        case .invalidBackup: return "invalid_backup"
        case .lockFailed(let code): return "lock/\(code)"
        case .commitFailed(let code): return "commit/\(code)"
        case .applyFailed(let code): return "apply/\(code)"
        case .pathOperationFailed(let operation, let code): return "path_\(operation)/\(code)"
        case .dynamicStateOperationFailed(let operation, let code):
            return "dynamic_\(operation)/\(code)"
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
