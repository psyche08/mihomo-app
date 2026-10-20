import Foundation
import Network
import NetworkExtension
import os

private let appLog = Logger(subsystem: "dev.linsheng.mihomo-dns-probe", category: "app-proxy")

final class AppProbeProvider: NEAppProxyProvider {
    private let queue = DispatchQueue(label: "app-probe.flows")
    private var closers: [UUID: () -> Void] = [:]
    private var counts: [String: Int] = [:]
    private var expiry: DispatchWorkItem?
    private var active = false
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil; c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 10
        c.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897,
                                      "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897]
        return URLSession(configuration: c, delegate: AppProbeNoRedirects(), delegateQueue: nil)
    }()

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        guard let raw = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let config = try? ProbeSessionConfiguration(options: raw, now: Date().timeIntervalSince1970),
              config.strictUnknown else {
            completionHandler(NSError(domain: "AppProbe", code: 1)); return
        }
        let settings = NETunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let dns = NEDNSSettings(servers: ["1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        setTunnelNetworkSettings(settings) { error in
            self.queue.async {
                guard error == nil else { completionHandler(error); return }
                self.active = true
                let expiry = DispatchWorkItem { [weak provider = self] in
                    provider?.active = false
                    provider?.cancelProxyWithError(NSError(domain: "AppProbe", code: 2))
                }
                self.expiry = expiry
                self.queue.asyncAfter(deadline: .now() + max(0, config.deadline - Date().timeIntervalSince1970), execute: expiry)
                appLog.notice("app_probe_started")
                completionHandler(nil)
            }
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.active = false; self.expiry?.cancel()
            for close in Array(self.closers.values) { close() }
            self.closers.removeAll(); self.session.invalidateAndCancel()
            appLog.notice("app_probe_stopped")
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let identity = classifyProbeIdentity(flow.metaData)
        queue.async {
            guard self.active, ["selected", "helper"].contains(identity), self.closers.count < 128 else {
                self.count("rejected_identity_or_capacity")
                self.reject(flow); return
            }
            self.count("flow_" + identity)
            let id = UUID()
            let finished = { self.closers.removeValue(forKey: id); return }
            if let tcp = flow as? NEAppProxyTCPFlow,
               let endpoint = tcp.remoteEndpoint as? NWHostEndpoint {
                if endpoint.port == "53" {
                    self.startDNS(flow, id: id, identity: identity, finished: finished)
                } else {
                    // Fixed allowlist keeps this prototype from becoming a general proxy.
                    // Never reinterpret a cached real/Fake IP as an independently resolved hostname.
                    let candidate = (flow.remoteHostname ?? endpoint.hostname).lowercased()
                    guard ["example.com", "example.org"].contains(candidate), endpoint.port == "443" else {
                        self.count("rejected_missing_or_unexpected_hostname"); self.reject(flow); return
                    }
                    self.count("hostname_tcp_" + identity)
                    let bridge = AppProbeTCPBridge(flow: tcp, host: candidate, queue: self.queue,
                                                   count: self.count, finished: finished)
                    self.closers[id] = { bridge.close() }; bridge.start()
                }
            } else if flow is NEAppProxyUDPFlow {
                self.startDNS(flow, id: id, identity: identity, finished: finished)
            } else { self.count("rejected_flow_type"); self.reject(flow) }
        }
        // Accepted flows are always either forwarded or explicitly closed; no bypass.
        return true
    }

    private func startDNS(_ flow: NEAppProxyFlow, id: UUID, identity: String, finished: @escaping () -> Void) {
        let handler = FlowHandler(flow: flow, queue: queue, forward: { query, reply in
            self.forwardDNS(query, identity: identity, reply: reply)
        }, acceptsEndpoint: { ($0 as? NWHostEndpoint)?.port == "53" }, finished: finished)
        closers[id] = { handler.close() }; handler.start()
    }

    private func forwardDNS(_ query: Data, identity: String, reply: @escaping (Data?) -> Void) {
        guard active, query.count >= 12, query.count <= 65535, query[2] & 0x80 == 0 else { reply(nil); return }
        count("dns_query_" + identity)
        var request = URLRequest(url: URL(string: "https://1.1.1.1/dns-query")!)
        request.httpMethod = "POST"; request.httpBody = query
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            self.queue.async {
                guard self.active, error == nil, let response = response as? HTTPURLResponse,
                      response.statusCode == 200, response.mimeType == "application/dns-message",
                      let data, data.count >= 12, data.count <= 65535,
                      data.prefix(2) == query.prefix(2), data[2] & 0x80 != 0 else {
                    self.count("dns_failed_" + identity); reply(nil); return
                }
                self.count("dns_answered_" + identity); reply(data)
            }
        }.resume()
    }

    private func reject(_ flow: NEAppProxyFlow) {
        let error = NSError(domain: "AppProbe", code: 3)
        flow.closeReadWithError(error); flow.closeWriteWithError(error)
    }

    private func count(_ key: String) {
        counts[key, default: 0] += 1
        appLog.notice("app_counter \(key, privacy: .public)=\(self.counts[key]!, privacy: .public)")
    }
}

private final class AppProbeNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class AppProbeTCPBridge {
    let flow: NEAppProxyTCPFlow
    let host: String
    let queue: DispatchQueue
    let count: (String) -> Void
    let finished: () -> Void
    let connection = NWConnection(host: "127.0.0.1", port: 7897, using: .tcp)
    var closed = false
    var clientEOF = false
    var remoteEOF = false
    var timer: DispatchWorkItem?

    init(flow: NEAppProxyTCPFlow, host: String, queue: DispatchQueue,
         count: @escaping (String) -> Void, finished: @escaping () -> Void) {
        self.flow = flow; self.host = host; self.queue = queue; self.count = count; self.finished = finished
    }
    func start() {
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        self.timer = timer; queue.asyncAfter(deadline: .now() + 30, execute: timer)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.connection.stateUpdateHandler = nil
                self.send(Data([5, 1, 0])) {
                    self.readExact(2) { data in
                        guard data == Data([5, 0]), let request = SOCKSConnect.request(host: self.host, port: 443) else {
                            self.close(); return
                        }
                        self.send(request) {
                            self.readExact(4) { header in
                                guard let size = SOCKSConnect.replyAddressLength(header) else {
                                    self.count("socks_rejected"); self.close(); return
                                }
                                if size > 0 { self.readExact(size) { _ in self.open() } }
                                else {
                                    self.readExact(1) { length in
                                        guard let n = length.first, n > 0 else { self.close(); return }
                                        self.readExact(Int(n) + 2) { _ in self.open() }
                                    }
                                }
                            }
                        }
                    }
                }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ data: Data, then: @escaping () -> Void) {
        guard !closed else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { self.close() } else if !self.closed { then() }
        })
    }
    func readExact(_ length: Int, _ completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
            guard !self.closed, error == nil, let data, data.count == length else { self.close(); return }
            completion(data)
        }
    }
    func open() {
        flow.open(withLocalEndpoint: nil) { error in
            self.queue.async {
                guard !self.closed, error == nil else { self.close(); return }
                self.count("socks_connected"); self.readClient(); self.readRemote()
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
