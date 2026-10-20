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
