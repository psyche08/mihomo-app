import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool) {
    precondition(condition()); count += 1
}
let request = SOCKSConnect.request(host: "example.com", port: 443)!
check(request.prefix(5) == Data([5, 1, 0, 3, 11]))
check(request.suffix(2) == Data([1, 187]))
check(String(decoding: request.dropFirst(5).dropLast(2), as: UTF8.self) == "example.com")
for host in ["", "x\r\ninjected", "a..b", "-bad.com", "bad-.com", String(repeating: "a", count: 64)+".com"] {
    check(SOCKSConnect.request(host: host, port: 443) == nil)
}
check(SOCKSConnect.request(host: "example.com", port: 0) == nil)
check(SOCKSConnect.replyAddressLength(Data([5, 0, 0, 1])) == 6)
check(SOCKSConnect.replyAddressLength(Data([5, 0, 0, 4])) == 18)
check(SOCKSConnect.replyAddressLength(Data([5, 0, 0, 3])) == 0)
for header: [UInt8] in [[5, 1, 0, 1], [4, 0, 0, 1], [5, 0, 1, 1], [5, 0, 0, 8], [5, 0, 0], [5, 0, 0, 1, 0]] {
    check(SOCKSConnect.replyAddressLength(Data(header)) == nil)
}
print("SOCKS framing checks passed: \(count)")

check(SOCKSConnect.request(host: "192.0.2.1", port: 8443) == Data([5,1,0,1,192,0,2,1,32,251]))
check(SOCKSConnect.request(host: "2001:db8::1", port: 443)?.prefix(4) == Data([5,1,0,4]))
check(SOCKSConnect.request(host: "EXAMPLE.COM.", port: 443) == request)
for host in ["example.com", "192.0.2.1", "2001:db8::1"] {
    let encoded = SOCKSDatagram.encode(host: host, port: 443, payload: Data([1,2,3]))!
    let decoded = SOCKSDatagram.decode(encoded)!
    check(decoded.host == host && decoded.port == 443 && decoded.payload == Data([1,2,3]))
    for cut in 0..<(encoded.count - 3) { check(SOCKSDatagram.decode(Data(encoded.prefix(cut))) == nil) }
    var fragmented = encoded; fragmented[2] = 1
    check(SOCKSDatagram.decode(fragmented) == nil)
}
check(SOCKSDatagram.encode(host: "example.com", port: 443, payload: Data(count: 65001)) == nil)
check(SOCKSDatagram.decode(Data([0,0,0,1,192,0,2,1,0,0])) == nil)
print("TCP/UDP framing checks passed: \(count)")
