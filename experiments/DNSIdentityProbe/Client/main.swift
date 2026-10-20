import Foundation
import Darwin

// Fixed public test names only. Never print request/response bytes or resolved addresses.
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? "system"
let testCase = arguments.dropFirst().first ?? "a"
let name = testCase == "b" ? "example.org" : testCase == "fresh" ? UUID().uuidString.lowercased()+".example.com" : "example.com"
func finish(_ result: [String: Any], _ code: Int32 = 0) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self)); exit(code)
}
func fail(_ stage: String) -> Never { finish(["mode": mode, "case": testCase, "ok": false, "stage": stage], 1) }
func reportDNS(_ data: Data, id: [UInt8]) {
    let b = [UInt8](data)
    guard b.count >= 12, Array(b.prefix(2)) == id, b[2] & 0x80 != 0 else { fail("invalid_response") }
    finish(["mode": mode, "case": testCase, "ok": true, "rcode": Int(b[3] & 15), "answer_count": Int(b[6])*256+Int(b[7])])
}
if mode == "helper" {
    let process = Process()
    process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/MihomoDNSHelper.app/Contents/MacOS/MihomoDNSHelper")
    process.arguments = ["system", testCase]
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) } catch { fail("helper_launch") }
} else if mode == "system" {
    var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    let error = getaddrinfo(name, nil, &hints, &result)
    var count = 0; var fake = false; var current = result
    while let entry = current {
        count += 1
        if let address = entry.pointee.ai_addr, entry.pointee.ai_family == AF_INET {
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            fake = fake || (ip & 0xfffe0000 == 0xc6120000)
        }
        current = entry.pointee.ai_next
    }
    if let result { freeaddrinfo(result) }
    finish(["mode": mode, "case": testCase, "ok": error == 0, "resolver_code": Int(error), "answer_count": count, "fake_ip": fake], error == 0 ? 0 : 1)
} else if mode == "https" {
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]; c.urlCache = nil; c.timeoutIntervalForResource = 15
    let session = URLSession(configuration: c)
    session.dataTask(with: URL(string: "https://"+name+"/")!) { _, response, error in
        finish(["mode": mode, "case": testCase, "ok": error == nil, "status": (response as? HTTPURLResponse)?.statusCode ?? 0], error == nil ? 0 : 1)
    }.resume()
    dispatchMain()
} else if mode == "udp" || mode == "tcp" {
    let id = [UInt8.random(in: 0...255), UInt8.random(in: 0...255)]
    var query = Data(id+[1,0,0,1,0,0,0,0,0,0])
    for label in name.split(separator: ".") { query.append(UInt8(label.utf8.count)); query.append(contentsOf: label.utf8) }
    query.append(contentsOf: [0,0,1,0,1])
    let fd = socket(AF_INET, mode == "udp" ? SOCK_DGRAM : SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket") }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(53).bigEndian; inet_pton(AF_INET, "1.1.1.1", &address.sin_addr)
    let connected = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard connected == 0 else { fail("connect") }
    var outgoing = Data()
    if mode == "tcp" { outgoing.append(contentsOf: [UInt8(query.count>>8), UInt8(query.count&255)]) }
    outgoing.append(query)
    let sent = outgoing.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard sent == outgoing.count else { fail("send") }
    func readExact(_ length: Int) -> Data {
        var result = Data()
        while result.count < length {
            var part = [UInt8](repeating: 0, count: length-result.count)
            let n = recv(fd, &part, part.count, 0)
            guard n > 0 else { fail("receive") }; result.append(contentsOf: part.prefix(n))
        }
        return result
    }
    if mode == "tcp" {
        let prefix = [UInt8](readExact(2)); let response = readExact(Int(prefix[0])*256+Int(prefix[1]))
        close(fd); reportDNS(response, id: id)
    } else {
        var b = [UInt8](repeating: 0, count: 65535); let n = recv(fd, &b, b.count, 0); close(fd)
        guard n > 0 else { fail("receive") }; reportDNS(Data(b.prefix(n)), id: id)
    }
} else { fail("usage_system_udp_tcp_https_helper") }
