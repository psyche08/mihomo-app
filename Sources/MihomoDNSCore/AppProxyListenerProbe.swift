import Darwin
import Foundation

/// Checks an App Proxy application port the way the extension uses it: a
/// SOCKS5 greeting offering no authentication must be accepted. A bare TCP
/// accept is not enough, because another process could hold the port.
public enum AppProxyListenerProbe {
    public static func answersSOCKS(port: UInt16, timeoutSeconds: Int = 1) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return false }
        let greeting: [UInt8] = [5, 1, 0]
        guard greeting.withUnsafeBytes({ send(descriptor, $0.baseAddress, $0.count, 0) }) == greeting.count
        else { return false }
        var reply = [UInt8](repeating: 0, count: 2)
        var received = 0
        while received < reply.count {
            let count = reply.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress! + received, $0.count - received, 0)
            }
            guard count > 0 else { return false }
            received += count
        }
        return reply == [5, 0]
    }
}
