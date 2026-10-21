import Foundation
import Network

/// Reuse the daemon-owned Mihomo DNS resolver, including its TUN/Fake-IP policy.
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
