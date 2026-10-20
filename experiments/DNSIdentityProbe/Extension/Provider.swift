import Foundation
import NetworkExtension
import Security
import os

private let probeTeam = "89LGY6BD53"
private let selectedIDs: Set<String> = ["dev.linsheng.mihomo-dns-probe.selected", "dev.linsheng.mihomo-dns-probe.selected.helper"]
private let controlID = "dev.linsheng.mihomo-dns-probe.control"
private let log = Logger(subsystem: "dev.linsheng.mihomo-dns-probe", category: "dns")

final class DNSProbeProvider: NEDNSProxyProvider {
    private let queue = DispatchQueue(label: "dns-probe.flows")
    private var flows: [UUID: FlowHandler] = [:]
    private var counts: [String: Int] = [:]
    private var strictUnknown = false
    private var expiry: DispatchWorkItem?
    private lazy var local = makeSession(proxy: false)
    private lazy var proxied = makeSession(proxy: true)

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let config = options ?? [:]
        let deadline = config["deadline"] as? Double ?? 0
        guard deadline > Date().timeIntervalSince1970, deadline <= Date().timeIntervalSince1970 + 660 else {
            completionHandler(NSError(domain: "DNSProbe", code: 1)); return
        }
        strictUnknown = config["strictUnknown"] as? Bool ?? false
        let work = DispatchWorkItem { [weak self] in
            self?.cancelProxyWithError(NSError(domain: "DNSProbe", code: 2))
        }
        expiry = work
        queue.asyncAfter(deadline: .now() + max(1, deadline - Date().timeIntervalSince1970), execute: work)
        log.notice("probe_started strict_unknown=\(self.strictUnknown, privacy: .public)")
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.expiry?.cancel()
            for handler in Array(self.flows.values) { handler.close() }
            self.flows.removeAll()
            self.local.invalidateAndCancel(); self.proxied.invalidateAndCancel()
            log.notice("probe_stopped")
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard flow is NEAppProxyUDPFlow || flow is NEAppProxyTCPFlow else { return false }
        let identity = classify(flow.metaData)
        let id = UUID()
        let handler = FlowHandler(flow: flow, queue: queue, forward: { [weak self] query, reply in
            self?.forward(query, identity: identity, reply: reply)
        }, finished: { [weak self] in self?.flows.removeValue(forKey: id) })
        queue.async {
            guard self.flows.count < 128 else {
                self.count("overload"); handler.close(); return
            }
            self.flows[id] = handler
            self.count("flow_" + identity)
            handler.start()
        }
        return true
    }

    private func classify(_ metadata: NEFlowMetaData) -> String {
        let claimed = metadata.sourceAppSigningIdentifier
        guard let token = metadata.sourceAppAuditToken, token.count == 32, !claimed.isEmpty else { return "unknown" }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == claimed else { return "unknown" }
        if selectedIDs.contains(claimed) || claimed == controlID {
            guard values[kSecCodeInfoTeamIdentifier as String] as? String == probeTeam else { return "mismatch" }
            if claimed == controlID { return "control" }
            return claimed.hasSuffix(".helper") ? "helper" : "selected"
        }
        return "other"
    }

    private func count(_ key: String) {
        counts[key, default: 0] += 1
        log.notice("counter \(key, privacy: .public)=\(self.counts[key]!, privacy: .public)")
    }

    private func makeSession(proxy: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.connectionProxyDictionary = proxy ? [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7897,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7897,
        ] : [:]
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func forward(_ query: Data, identity: String, reply: @escaping (Data?) -> Void) {
        guard query.count >= 12, query.count <= 65535, query[2] & 0x80 == 0 else { reply(nil); return }
        count("query_" + identity)
        if identity == "mismatch" || (identity == "unknown" && strictUnknown) {
            var refused = query; refused[2] |= 0x80; refused[3] = (refused[3] & 0xf0) | 5
            for index in 6..<12 { refused[index] = 0 }
            count("refused_" + identity); reply(refused); return
        }
        let useProxy = identity == "selected" || identity == "helper"
        var request = URLRequest(url: URL(string: useProxy ? "https://1.1.1.1/dns-query" : "https://127.0.0.1/dns-query")!)
        request.httpMethod = "POST"; request.httpBody = query
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        (useProxy ? proxied : local).dataTask(with: request) { data, response, error in
            self.queue.async {
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.mimeType == "application/dns-message", let data, data.count >= 12, data.count <= 65535,
                      data.prefix(2) == query.prefix(2), data[2] & 0x80 != 0 else {
                    self.count("failed_" + identity); reply(nil); return
                }
                // No retries through direct DNS for selected identities, no shared cache.
                self.count("answered_" + identity); reply(data)
            }
        }.resume()
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class FlowHandler {
    let flow: NEAppProxyFlow
    let queue: DispatchQueue
    let forward: (Data, @escaping (Data?) -> Void) -> Void
    let finished: () -> Void
    var buffer = Data()
    var closed = false
    var timer: DispatchWorkItem?
    init(flow: NEAppProxyFlow, queue: DispatchQueue,
         forward: @escaping (Data, @escaping (Data?) -> Void) -> Void, finished: @escaping () -> Void) {
        self.flow = flow; self.queue = queue; self.forward = forward; self.finished = finished
    }
    func start() {
        let timer = DispatchWorkItem { [weak self] in self?.close() }; self.timer = timer
        queue.asyncAfter(deadline: .now()+30, execute: timer)
        flow.open(withLocalEndpoint: nil) { error in
            self.queue.async { if error != nil { self.close() } else { self.read() } }
        }
    }
    func close() {
        guard !closed else { return }; closed = true; timer?.cancel()
        flow.closeReadWithError(nil); flow.closeWriteWithError(nil); finished()
    }
    func read() {
        guard !closed else { return }
        if let udp = flow as? NEAppProxyUDPFlow {
            udp.readDatagrams { datagrams, endpoints, error in
                self.queue.async {
                    guard error == nil, let datagrams, let endpoints, datagrams.count == endpoints.count,
                          !datagrams.isEmpty, datagrams.count <= 32 else { self.close(); return }
                    self.forwardUDP(datagrams, endpoints, index: 0, udp: udp)
                }
            }
        } else if let tcp = flow as? NEAppProxyTCPFlow {
            tcp.readData { data, error in
                self.queue.async {
                    guard error == nil, let data, !data.isEmpty, self.buffer.count+data.count <= 131074 else { self.close(); return }
                    self.buffer.append(data); self.consumeTCP(tcp)
                }
            }
        }
    }
    func forwardUDP(_ packets: [Data], _ endpoints: [NWEndpoint], index: Int, udp: NEAppProxyUDPFlow) {
        guard !closed else { return }
        guard index < packets.count else { read(); return }
        forward(packets[index]) { response in
            guard !self.closed, let response else { self.close(); return }
            udp.writeDatagrams([response], sentBy: [endpoints[index]]) { error in
                self.queue.async {
                    if error != nil { self.close() }
                    else { self.forwardUDP(packets, endpoints, index: index+1, udp: udp) }
                }
            }
        }
    }
    func consumeTCP(_ tcp: NEAppProxyTCPFlow) {
        guard !closed else { return }
        guard buffer.count >= 2 else { read(); return }
        let length = Int(buffer[buffer.startIndex])*256+Int(buffer[buffer.startIndex+1])
        guard length >= 12 else { close(); return }
        guard buffer.count >= length+2 else { read(); return }
        let query = Data(buffer.dropFirst(2).prefix(length)); buffer = Data(buffer.dropFirst(length+2))
        forward(query) { response in
            guard !self.closed, let response else { self.close(); return }
            var framed = Data([UInt8(response.count>>8), UInt8(response.count&255)]); framed.append(response)
            tcp.write(framed) { error in
                self.queue.async {
                    if error != nil { self.close() }
                    else if self.buffer.isEmpty { self.read() }
                    else { self.consumeTCP(tcp) }
                }
            }
        }
    }
}
