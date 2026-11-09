import Foundation

// The main App Proxy resolves through the daemon's `dns.resolve` XPC operation.
// A test binary is not signed by the release certificate family, so every case
// must fail closed, without any socket fallback, and complete exactly once.
let queue = DispatchQueue(label: "app-proxy-dns-xpc-test")
let query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7]) + Data("example".utf8) + Data([3]) + Data("com".utf8) + Data([0, 0, 1, 0, 1])

func check(_ name: String, input: Data, cancel: Bool = false) {
    let done = DispatchSemaphore(value: 0)
    let request = AppProxyDNSRequest(query: input, queue: queue, timeout: 2) { actual in
        precondition(actual == nil, "response: " + name)
        done.signal()
    }
    queue.async {
        request.start()
        if cancel { request.cancel(); request.cancel() }
    }
    precondition(done.wait(timeout: .now() + 4) == .success, "completion: " + name)
    queue.sync { request.cancel() }
    precondition(done.wait(timeout: .now() + 0.05) == .timedOut, "duplicate completion: " + name)
}

check("invalid query", input: Data([0]))
var status = query; status[2] = 0x10 // STATUS opcode is not a resolver query.
check("non-standard opcode", input: status)
var response = query; response[2] |= 0x80
check("response instead of query", input: response)
check("caller outside the release signing family", input: query)
check("cancel", input: query, cancel: true)
print("App Proxy daemon DNS transport: 5 fail-closed cases passed")
