import Foundation
import Network
#if MAIN_APP_PROXY
import XPC
#endif

#if MAIN_APP_PROXY
/// Resolves one captured query through the root daemon's `dns.resolve` XPC
/// operation. The daemon forwards it to the daemon-owned Mihomo DNS listener,
/// so answers keep the TUN/Fake-IP policy, and the extension never opens a DNS
/// socket another product's DNS Proxy could intercept. Any failure or timeout
/// answers nothing: there is no system-resolver or public fallback.
/// All methods and callbacks run on the supplied serial queue.
final class AppProxyDNSRequest {
    private let query: Data
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private var completion: ((Data?) -> Void)?
    private var timer: DispatchWorkItem?

    init(query: Data, queue: DispatchQueue,
         timeout: TimeInterval = TimeInterval(AppProxyDNSPolicy.clientTimeoutMilliseconds) / 1_000,
         completion: @escaping (Data?) -> Void) {
        self.query = query; self.queue = queue; self.timeout = timeout
        self.completion = completion
    }

    func start() {
        guard AppProxyDNSPolicy.isAcceptableQuery(query) else { finish(nil); return }
        let timer = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        let query = self.query
        DaemonDNSConnection.shared.resolve(query) { [weak self] response in
            guard let self else { return }
            self.queue.async {
                guard let response, AppProxyDNSPolicy.isMatchingResponse(response, for: query) else {
                    self.finish(nil); return
                }
                // Preserve valid negative answers and the core's Fake-IP data.
                self.finish(response)
            }
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ response: Data?) {
        guard let completion else { return }
        self.completion = nil
        timer?.cancel(); timer = nil
        completion(response)
    }
}

/// One privileged Mach connection to the daemon, shared by every query and
/// recreated only after it is invalidated. The daemon verifies this
/// extension's signing identifier and serves it nothing but DNS answers.
final class DaemonDNSConnection: @unchecked Sendable {
    static let shared = DaemonDNSConnection()

    private let lock = NSLock()
    private let replies = DispatchQueue(label: "dev.linsheng.mihomo-app.app-proxy.dns-xpc")
    private var connection: xpc_connection_t?

    /// Calls `completion` exactly once, on a private queue.
    func resolve(_ query: Data, completion: @escaping (Data?) -> Void) {
        guard let connection = current(),
              let encoded = try? JSONEncoder().encode(ControlRequest(operation: .resolveDNS)) else {
            completion(nil); return
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        encoded.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, "request", bytes.baseAddress, encoded.count)
        }
        query.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, "payload", bytes.baseAddress, bytes.count)
        }
        xpc_connection_send_message_with_reply(connection, message, replies) { reply in
            completion(Self.answer(from: reply))
        }
    }

    private static func answer(from reply: xpc_object_t) -> Data? {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { return nil }
        var length = 0
        guard let pointer = xpc_dictionary_get_data(reply, "response", &length), length > 0,
              let response = try? JSONDecoder().decode(
                  ControlResponse.self, from: Data(bytes: pointer, count: length)
              ), response.success else { return nil }
        var payloadLength = 0
        guard let payload = xpc_dictionary_get_data(reply, "payload", &payloadLength),
              payloadLength >= 12, payloadLength <= 65_535 else { return nil }
        return Data(bytes: payload, count: payloadLength)
    }

    private func current() -> xpc_connection_t? {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        guard let requirement = try? SigningCertificateRequirement.currentProcess() else { return nil }
        let created = xpc_connection_create_mach_service(
            mihomoControlServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        guard xpc_connection_set_peer_code_signing_requirement(created, requirement) == 0 else {
            xpc_connection_cancel(created)
            return nil
        }
        xpc_connection_set_event_handler(created) { [weak self] event in
            // Interrupted connections reconnect on the next message; an
            // invalidated one is replaced.
            guard xpc_get_type(event) == XPC_TYPE_ERROR,
                  event === XPC_ERROR_CONNECTION_INVALID else { return }
            self?.forget(created)
        }
        xpc_connection_resume(created)
        connection = created
        return created
    }

    private func forget(_ stale: xpc_connection_t) {
        lock.lock(); defer { lock.unlock() }
        if let connection, connection === stale { self.connection = nil }
    }
}
#else
/// Probe build: reuse the daemon-owned Mihomo DNS resolver over TCP 1153.
/// TCP avoids UDP truncation and never uses the system resolver or a public fallback.
/// All methods and callbacks run on the supplied serial queue.
final class AppProxyDNSRequest {
    private let query: Data
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let timeout: TimeInterval
    private var completion: ((Data?) -> Void)?
    private var timer: DispatchWorkItem?

    init(query: Data, queue: DispatchQueue, port: NWEndpoint.Port = 1153,
         timeout: TimeInterval = 8, completion: @escaping (Data?) -> Void) {
        self.query = query; self.queue = queue; self.timeout = timeout
        self.completion = completion
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    }

    func start() {
        guard query.count >= 12, query.count <= 65535, query[2] & 0x80 == 0 else {
            finish(nil); return
        }
        let timer = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.completion != nil else { return }
            switch state {
            case .ready:
                self.connection.stateUpdateHandler = nil
                let frame = Data([UInt8(self.query.count >> 8), UInt8(self.query.count & 255)]) + self.query
                self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    guard let self, self.completion != nil else { return }
                    guard error == nil else { self.finish(nil); return }
                    self.read(2) { header in
                        let length = Int(header[0]) << 8 | Int(header[1])
                        guard length >= 12 else { self.finish(nil); return }
                        self.read(length) { response in
                            guard response.prefix(2) == self.query.prefix(2), response[2] & 0x80 != 0,
                                  response[2] & 0x78 == self.query[2] & 0x78 else {
                                self.finish(nil); return
                            }
                            // Preserve valid negative answers and the core's Fake-IP data.
                            self.finish(response)
                        }
                    }
                })
            case .failed, .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() { finish(nil) }

    private func read(_ length: Int, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self, self.completion != nil else { return }
            guard error == nil, let data, data.count == length else { self.finish(nil); return }
            completion(data)
        }
    }

    private func finish(_ response: Data?) {
        guard let completion else { return }
        self.completion = nil
        timer?.cancel(); timer = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        completion(response)
    }
}
#endif
