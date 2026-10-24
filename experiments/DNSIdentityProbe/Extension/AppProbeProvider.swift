import Foundation
import Darwin
import Network
import NetworkExtension
import os
import SystemConfiguration

private let appLog = Logger(subsystem: "dev.linsheng.mihomo-dns-probe", category: "app-proxy")

final class AppProbeProvider: NEAppProxyProvider {
    private let queue = DispatchQueue(label: "app-probe.flows")
    private var closers: [UUID: () -> Void] = [:]
    private var counts: [String: Int] = [:]
    private var expiry: DispatchWorkItem?
    private var active = false
    private var aiConfiguration: AIProxyConfiguration?
    private var accessLease: AppProxyAccessLease?
    private var pendingAccess: (AIProxyConfiguration, AppProxyAccessLease)?
    private var generationGate: AppProxyGenerationGate?
    private var leaseTimer: DispatchSourceTimer?
    private var lastRenewal: TimeInterval = 0
    private var lastFailure: AppProxyIdentityFailure?
    private var flowEvidence: [AppProxyFlowEvidence] = []
    private var dnsRequests: [UUID: AppProxyDNSRequest] = [:]

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        guard let raw = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration else {
            completionHandler(NSError(domain: "AppProbe", code: 1)); return
        }
        let deadline: TimeInterval?
        if raw["mode"] as? String == "ai" {
            guard let config = try? AIProxyConfiguration(raw, now: Date().timeIntervalSince1970) else {
                completionHandler(NSError(domain: "AppProbe", code: 1)); return
            }
            do {
                #if MAIN_APP_PROXY
                guard let snapshot = config.snapshot else { throw AppProxyIdentityFailure.needsAuthorization }
                guard Self.consoleUID() == snapshot.ownerUID else { throw AppProxyIdentityFailure.wrongUser }
                accessLease = try AppProxyAccessLease(snapshot)
                generationGate = AppProxyGenerationGate(snapshot.generation)
                lastRenewal = ProcessInfo.processInfo.systemUptime
                #endif
            } catch {
                let reason = error as? AppProxyIdentityFailure ?? .permission
                lastFailure = reason
                appLog.error("app_code_access_failed \(reason.rawValue, privacy: .public)")
                completionHandler(NSError(domain: "MihomoBox.AppProxy.Authorization", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: reason.rawValue])); return
            }
            aiConfiguration = config; deadline = config.deadline
        } else {
            #if MAIN_APP_PROXY
            completionHandler(NSError(domain: "AppProxy", code: 1)); return
            #else
            guard let config = try? ProbeSessionConfiguration(options: raw, now: Date().timeIntervalSince1970), config.strictUnknown else {
                completionHandler(NSError(domain: "AppProbe", code: 1)); return
            }
            deadline = config.deadline
            #endif
        }
        let settings = NETunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        // Advertise the managed TUN DNS address, not loopback port 53: macOS
        // can resolve selected apps outside handleNewFlow for loopback DNS,
        // where nothing listens. Captured DNS still goes to shared TCP 1153.
        let dns = NEDNSSettings(servers: ["198.18.0.1"])
        // App rules scope this resolver to selected applications. An empty
        // match domain publishes a supplemental default resolver and can send
        // unselected system lookups to a resolver outside their normal scope.
        // Leave matchDomains unset, as in Apple's App Proxy sample.
        settings.dnsSettings = dns
        setTunnelNetworkSettings(settings) { error in
            self.queue.async {
                guard error == nil else { completionHandler(error); return }
                self.active = true
                self.startLeaseTimer()
                if let deadline {
                let expiry = DispatchWorkItem { [weak provider = self] in
                    provider?.active = false
                    provider?.cancelProxyWithError(NSError(domain: "AppProbe", code: 2))
                }
                self.expiry = expiry
                self.queue.asyncAfter(deadline: .now() + max(0, deadline - Date().timeIntervalSince1970), execute: expiry)
                }
                appLog.notice("app_probe_started")
                completionHandler(nil)
            }
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.active = false; self.expiry?.cancel(); self.leaseTimer?.cancel(); self.leaseTimer = nil
            self.accessLease = nil; self.pendingAccess = nil; self.generationGate = nil
            for close in Array(self.closers.values) { close() }
            self.closers.removeAll()
            for request in Array(self.dnsRequests.values) { request.cancel() }
            self.dnsRequests.removeAll()
            appLog.notice("app_probe_stopped")
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        queue.async {
            let receipt = UUID()
            let activeIdentity = self.aiConfiguration?.classify(flow.metaData)
            let pendingIdentity = activeIdentity == nil ? self.pendingAccess?.0.classify(flow.metaData) : nil
            let generation = pendingIdentity != nil ? self.pendingAccess?.1.snapshot.generation : self.accessLease?.snapshot.generation
            let identity = activeIdentity ?? pendingIdentity ?? (self.aiConfiguration == nil ? classifyProbeIdentity(flow.metaData) : "unknown")
            self.record(receipt, flow.metaData.sourceAppAuditToken, "handleNewFlow", generation: generation)
            if let snapshot = self.aiConfiguration?.snapshot, Self.consoleUID() != snapshot.ownerUID {
                self.lastFailure = .wrongUser
                self.record(receipt, flow.metaData.sourceAppAuditToken, "identity_wrongUser", generation: generation)
                self.record(receipt, flow.metaData.sourceAppAuditToken, "providerRejected", generation: generation)
                self.reject(flow); return
            }
            guard self.active, (self.aiConfiguration != nil ? identity != "unknown" : ["selected", "helper"].contains(identity)), self.closers.count < (self.aiConfiguration == nil ? 128 : 1024) else {
                if let config = self.aiConfiguration {
                    do { _ = try config.classifyValidated(flow.metaData) }
                    catch { self.record(receipt, flow.metaData.sourceAppAuditToken, "identity_" + (error as? AppProxyIdentityFailure ?? .runtimeIdentity).rawValue, generation: generation) }
                }
                self.record(receipt, flow.metaData.sourceAppAuditToken, "providerRejected", generation: generation); self.count("rejected_identity_or_capacity")
                self.reject(flow); return
            }
            guard let proxyPort = self.aiConfiguration.map({ $0.proxyPort(for: identity) }) ?? UInt16(7897) else {
                self.count("rejected_unattributed_tool"); self.reject(flow); return
            }
            self.record(receipt, flow.metaData.sourceAppAuditToken, "providerValidated", generation: generation)
            self.count("flow_" + identity)
            let id = UUID()
            let finished = { self.closers.removeValue(forKey: id); return }
            if let tcp = flow as? NEAppProxyTCPFlow,
               let endpoint = tcp.remoteEndpoint as? NWHostEndpoint {
                if endpoint.port == "53" {
                    self.startDNS(flow, id: id, identity: identity, receipt: receipt, generation: generation, finished: finished)
                } else {
                    // Prefer metadata's original name; retain numeric destinations
                    // when low-level clients have already resolved them.
                    let local = self.aiConfiguration != nil && (Self.isLoopback(endpoint.hostname)
                        || self.aiConfiguration?.bypass.contains(endpoint.hostname) == true)
                    let candidate = local ? endpoint.hostname : (flow.remoteHostname.flatMap { $0.isEmpty ? nil : $0 } ?? endpoint.hostname).lowercased()
                    guard let port = UInt16(endpoint.port), port > 0,
                          SOCKSConnect.request(host: candidate, port: port) != nil,
                          self.aiConfiguration != nil || (["example.com", "example.org"].contains(candidate) && port == 443) else {
                        self.count("rejected_missing_or_unexpected_hostname"); self.reject(flow); return
                    }
                    guard !local || Self.isLoopback(candidate) || flow.networkInterface != nil else {
                        self.count("rejected_missing_bypass_interface"); self.reject(flow); return
                    }
                    self.count("hostname_tcp_" + identity)
                    let bridge = AppProbeTCPBridge(flow: tcp, host: candidate, port: port, local: local, proxyPort: proxyPort, queue: self.queue,
                                                   count: { key in
                        self.count(key)
                        if ["socks_rejected", "upstream_failed", "upstream_timeout", "flow_open_failed", "upstream_connected"].contains(key) {
                            self.record(receipt, flow.metaData.sourceAppAuditToken, key, generation: generation)
                        }
                    }, finished: finished)
                    self.closers[id] = { bridge.close() }; bridge.start()
                }
            } else if let udp = flow as? NEAppProxyUDPFlow {
                if self.aiConfiguration != nil {
                    let bridge = AppProxyUDPBridge(flow: udp, proxyPort: proxyPort, bypass: self.aiConfiguration!.bypass, queue: self.queue, forwardDNS: { query, reply in
                        self.forwardDNS(query, identity: identity, receipt: receipt, generation: generation, token: flow.metaData.sourceAppAuditToken, reply: reply)
                    }, count: { key in
                        self.count(key)
                        if ["socks_rejected", "upstream_failed", "upstream_timeout", "flow_open_failed", "upstream_connected"].contains(key) {
                            self.record(receipt, flow.metaData.sourceAppAuditToken, key, generation: generation)
                        }
                    }, finished: finished)
                    self.closers[id] = { bridge.close() }; bridge.start()
                } else { self.startDNS(flow, id: id, identity: identity, receipt: receipt, generation: generation, finished: finished) }
            } else { self.count("rejected_flow_type"); self.reject(flow) }
        }
        // Accepted flows are bridged by policy or explicitly closed. Returning
        // false is not used as an implicit NetworkExtension routing fallback.
        return true
    }

    static func isLoopback(_ host: String) -> Bool {
        var address = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 {
            return UInt32(bigEndian: address.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255, bytes[12] == 127 { return true }
        }
        return host.lowercased() == "localhost"
    }

    private func startDNS(_ flow: NEAppProxyFlow, id: UUID, identity: String, receipt: UUID, generation: UUID?, finished: @escaping () -> Void) {
        let handler = FlowHandler(flow: flow, queue: queue, forward: { query, reply in
            self.forwardDNS(query, identity: identity, receipt: receipt, generation: generation, token: flow.metaData.sourceAppAuditToken, reply: reply)
        }, acceptsEndpoint: { ($0 as? NWHostEndpoint)?.port == "53" }, finished: finished)
        closers[id] = { handler.close() }; handler.start()
    }

    private func forwardDNS(_ query: Data, identity: String, receipt: UUID, generation: UUID?, token: Data?, reply: @escaping (Data?) -> Void) {
        guard active, query.count >= 12, query.count <= 65535, query[2] & 0x80 == 0 else { reply(nil); return }
        guard dnsRequests.count < 128 else { record(receipt, token, "dnsFailed", generation: generation); count("dns_overload"); reply(nil); return }
        count("dns_query_" + identity)
        let id = UUID()
        let request = AppProxyDNSRequest(query: query, queue: queue) { data in
            self.dnsRequests.removeValue(forKey: id)
            guard self.active, let data else {
                self.record(receipt, token, "dnsFailed", generation: generation); self.count("dns_failed_" + identity); reply(nil); return
            }
            self.record(receipt, token, "dnsAnswered", generation: generation); self.count("dns_answered_" + identity); reply(data)
        }
        dnsRequests[id] = request
        request.start()
    }

    private func record(_ flow: UUID, _ token: Data?, _ stage: String, generation: UUID?) {
        flowEvidence.append(.init(flow: flow, token: token, stage: stage, generation: generation))
        if flowEvidence.count > 64 { flowEvidence.removeFirst(flowEvidence.count - 64) }
    }
    private static func consoleUID() -> UInt32? {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid != 0 else { return nil }
        return uid
    }
    private func startLeaseTimer() {
        guard accessLease != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, let snapshot = self.accessLease?.snapshot else { return }
            if self.generationGate?.expirePrepared(now: ProcessInfo.processInfo.systemUptime) == true { self.pendingAccess = nil }
            if Self.consoleUID() != snapshot.ownerUID || ProcessInfo.processInfo.systemUptime - self.lastRenewal > 90 {
                self.lastFailure = Self.consoleUID() != snapshot.ownerUID ? .wrongUser : .staleAuthorization
                self.active = false
                self.cancelProxyWithError(NSError(domain: "MihomoBox.AppProxy.Authorization", code: 2))
            }
        }
        leaseTimer = timer; timer.resume()
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        queue.async {
            var failure: AppProxyIdentityFailure?
            do {
                guard messageData.count <= AppProxyIdentitySnapshot.maximumBytes + 65536,
                      let lease = self.accessLease, self.generationGate != nil, Self.consoleUID() == lease.snapshot.ownerUID else { throw AppProxyIdentityFailure.wrongUser }
                let message = try JSONDecoder().decode(AppProxyRuntimeMessage.self, from: messageData)
                switch message.action {
                case .status: break
                case .prepare:
                    guard let data = message.configuration, data.count <= AppProxyIdentitySnapshot.maximumBytes,
                          let raw = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw AppProxyIdentityFailure.malformed }
                    let config = try AIProxyConfiguration(raw, now: Date().timeIntervalSince1970)
                    guard let snapshot = config.snapshot, snapshot.ownerUID == lease.snapshot.ownerUID,
                          config.ports == self.aiConfiguration?.ports,
                          let expected = message.expected else { throw AppProxyIdentityFailure.malformed }
                    let prepared = try AppProxyAccessLease(snapshot)
                    try self.generationGate?.prepare(snapshot.generation, expected: expected, now: ProcessInfo.processInfo.systemUptime)
                    self.pendingAccess = (config, prepared)
                case .commit:
                    guard let expected = message.expected, let pending = self.pendingAccess,
                          pending.1.snapshot.generation == expected else { throw AppProxyIdentityFailure.generationMismatch }
                    try pending.1.revalidate()
                    try self.generationGate?.commit(expected, now: ProcessInfo.processInfo.systemUptime)
                    self.aiConfiguration = pending.0; self.accessLease = pending.1; self.pendingAccess = nil
                    self.lastRenewal = ProcessInfo.processInfo.systemUptime; self.lastFailure = nil
                case .abort: self.pendingAccess = nil; self.generationGate?.abort()
                case .renew:
                    guard message.expected == lease.snapshot.generation else { throw AppProxyIdentityFailure.generationMismatch }
                    try lease.revalidate()
                    self.lastRenewal = ProcessInfo.processInfo.systemUptime
                }
            } catch { failure = error as? AppProxyIdentityFailure ?? .malformed }
            let status = AppProxyRuntimeStatus(generation: self.accessLease?.snapshot.generation,
                ready: self.active && failure == nil && self.lastFailure == nil,
                verifiedTargets: self.accessLease?.snapshot.records.count ?? 0,
                failure: failure ?? self.lastFailure, counters: self.counts, recentFlows: self.flowEvidence)
            completionHandler?(try? JSONEncoder().encode(status))
        }
    }

    private func reject(_ flow: NEAppProxyFlow) {
        let error = NSError(domain: "AppProbe", code: 3)
        flow.closeReadWithError(error); flow.closeWriteWithError(error)
    }

    private func count(_ key: String) {
        counts[key, default: 0] += 1
        let value = counts[key]!
        if value > 8, value & (value - 1) != 0 { return }
        appLog.notice("app_counter \(key, privacy: .public)=\(self.counts[key]!, privacy: .public)")
    }
}

private final class AppProbeTCPBridge {
    let flow: NEAppProxyTCPFlow
    let host: String
    let port: UInt16
    let queue: DispatchQueue
    let count: (String) -> Void
    let finished: () -> Void
    let connection: AppProxyConnection
    let local: Bool
    var closed = false
    var clientEOF = false
    var remoteEOF = false
    var timer: DispatchWorkItem?

    init(flow: NEAppProxyTCPFlow, host: String, port: UInt16, local: Bool, proxyPort: UInt16, queue: DispatchQueue,
         count: @escaping (String) -> Void, finished: @escaping () -> Void) {
        self.local = local
        self.connection = AppProxyConnection(host: local ? host : "127.0.0.1",
                                             port: local ? port : proxyPort, transport: .tcp,
                                             interface: local && !AppProbeProvider.isLoopback(host) ? flow.networkInterface : nil)
        self.flow = flow; self.host = host; self.port = port; self.queue = queue; self.count = count; self.finished = finished
    }
    func start() {
        let timer = DispatchWorkItem { [weak self] in self?.count("upstream_timeout"); self?.close() }
        self.timer = timer; queue.asyncAfter(deadline: .now() + 30, execute: timer)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.connection.stateUpdateHandler = nil
                if self.local { self.open(); return }
                self.send(Data([5, 1, 0])) {
                    self.readExact(2) { data in
                        guard data == Data([5, 0]), let request = SOCKSConnect.request(host: self.host, port: self.port) else {
                            self.count("socks_rejected"); self.close(); return
                        }
                        self.send(request) {
                            self.readExact(4) { header in
                                guard let size = SOCKSConnect.replyAddressLength(header) else {
                                    self.count("socks_rejected"); self.close(); return
                                }
                                if size > 0 { self.readExact(size) { _ in self.open() } }
                                else {
                                    self.readExact(1) { length in
                                        guard let n = length.first, n > 0 else { self.count("socks_rejected"); self.close(); return }
                                        self.readExact(Int(n) + 2) { _ in self.open() }
                                    }
                                }
                            }
                        }
                    }
                }
            case .failed: self.count("upstream_failed"); self.close()
            case .cancelled: self.close()
            }
        }
        connection.start(queue: queue)
    }
    func send(_ data: Data, then: @escaping () -> Void) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { self.count("upstream_failed"); self.close() } else if !self.closed { then() }
        })
    }
    func readExact(_ length: Int, _ completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
            guard !self.closed else { return }
            guard error == nil, let data, data.count == length else { self.count("upstream_failed"); self.close(); return }
            completion(data)
        }
    }
    func open() {
        count("upstream_connected")
        flow.open(withLocalEndpoint: nil) { error in
            self.queue.async {
                guard !self.closed else { return }
                guard error == nil else { self.count("flow_open_failed"); self.close(); return }
                self.timer?.cancel()
                // The 30-second deadline covers setup only. Streaming responses
                // and WebSockets live until EOF, error or provider shutdown.
                self.count(self.local ? "local_tcp_connected" : "socks_connected"); self.readClient(); self.readRemote()
            }
        }
    }
    func readClient() {
        guard !closed else { return }
        flow.readData { data, error in
            self.queue.async {
                guard !self.closed, error == nil, let data else { self.close(); return }
                if data.isEmpty {
                    self.clientEOF = true
                    self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                         completion: .contentProcessed { error in
                        if error != nil || self.remoteEOF { self.close() }
                    })
                } else { self.send(data) { self.readClient() } }
            }
        }
    }
    func readRemote() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, complete, error in
            guard !self.closed, error == nil else { self.close(); return }
            let next = {
                if complete {
                    self.remoteEOF = true; self.flow.closeWriteWithError(nil)
                    if self.clientEOF { self.close() }
                } else { self.readRemote() }
            }
            if let data, !data.isEmpty {
                self.flow.write(data) { error in
                    self.queue.async { if error != nil { self.close() } else if !self.closed { next() } }
                }
            } else { next() }
        }
    }
    func close() {
        guard !closed else { return }
        closed = true; timer?.cancel(); connection.cancel()
        flow.closeReadWithError(nil); flow.closeWriteWithError(nil); finished()
    }
}
