import Foundation
import Network

let queue = DispatchQueue(label: "app-proxy-dns-test")
let query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7]) + Data("example".utf8) + Data([3]) + Data("com".utf8) + Data([0, 0, 1, 0, 1])
var response = query; response[2] = 0x81; response[3] = 0x83 // Valid NXDOMAIN must survive unchanged.

func check(_ name: String, wire: Data?, expected: Data?, cancel: Bool = false, input: Data = query) throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var peers: [NWConnection] = []
    listener.stateUpdateHandler = { state in
        if case .ready = state { ready.signal() }
    }
    listener.newConnectionHandler = { peer in
        peers.append(peer)
        peer.start(queue: queue)
        peer.receive(minimumIncompleteLength: input.count + 2, maximumLength: input.count + 2) { _, _, _, _ in
            guard let wire else { return } // Deliberately silent server for timeout/cancellation.
            // Exercise fragmented length and body delivery.
            peer.send(content: wire.prefix(1), completion: .contentProcessed { _ in
                peer.send(content: wire.dropFirst(), isComplete: true, completion: .contentProcessed { _ in })
            })
        }
    }
    listener.start(queue: queue)
    precondition(ready.wait(timeout: .now() + 3) == .success, "listener: " + name)
    let request = AppProxyDNSRequest(query: input, queue: queue, port: listener.port!, timeout: 0.3) { actual in
        precondition(actual == expected, "response: " + name)
        done.signal()
    }
    queue.async {
        request.start()
        if cancel { request.cancel(); request.cancel() }
    }
    precondition(done.wait(timeout: .now() + 3) == .success, "completion: " + name)
    queue.sync {
        request.cancel() // Completion must occur exactly once even after a reply.
        peers.forEach { $0.cancel() }; listener.cancel()
    }
    precondition(done.wait(timeout: .now() + 0.02) == .timedOut, "duplicate completion: " + name)
}
func frame(_ bytes: Data) -> Data { Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]) + bytes }
try check("negative answer, fragmented TCP", wire: frame(response), expected: response)
var fakeIP = response
fakeIP[3] = 0x80; fakeIP[7] = 1
fakeIP.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 198, 18, 0, 42])
try check("core Fake-IP answer preserved", wire: frame(fakeIP), expected: fakeIP)
var wrong = response; wrong[0] ^= 1
try check("transaction mismatch", wire: frame(wrong), expected: nil)
wrong = response; wrong[2] &= 0x7f
try check("not a response", wire: frame(wrong), expected: nil)
wrong = response; wrong[2] ^= 8
try check("opcode mismatch", wire: frame(wrong), expected: nil)
try check("short DNS", wire: frame(Data(repeating: 0, count: 11)), expected: nil)
try check("truncated TCP body", wire: frame(response).dropLast(), expected: nil)
try check("timeout", wire: nil, expected: nil)
try check("cancel", wire: nil, expected: nil, cancel: true)
try check("invalid query", wire: nil, expected: nil, input: Data([0]))
print("App Proxy core DNS transport: 10 cases passed")
