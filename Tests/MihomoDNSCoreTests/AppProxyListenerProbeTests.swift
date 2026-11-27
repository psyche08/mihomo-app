import Darwin
import XCTest
@testable import MihomoDNSCore

final class AppProxyListenerProbeTests: XCTestCase {
    /// Accepts one connection, reads the three-byte greeting and answers with `reply`.
    private func serve(reply: [UInt8]) throws -> (port: UInt16, done: XCTestExpectation) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, length) == 0 && Darwin.listen(listener, 1) == 0
                    && getsockname(listener, $0, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let done = expectation(description: "served")
        DispatchQueue.global().async {
            defer { close(listener); done.fulfill() }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var greeting = [UInt8](repeating: 0, count: 3)
            _ = greeting.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, MSG_WAITALL) }
            _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        }
        return (UInt16(bigEndian: address.sin_port), done)
    }

    func testAcceptsAListenerThatAllowsNoAuthentication() throws {
        let server = try serve(reply: [5, 0])
        XCTAssertTrue(AppProxyListenerProbe.answersSOCKS(port: server.port))
        wait(for: [server.done], timeout: 5)
    }

    func testRejectsAListenerThatRequiresAuthenticationOrSpeaksAnotherProtocol() throws {
        let authenticated = try serve(reply: [5, 0xFF])
        XCTAssertFalse(AppProxyListenerProbe.answersSOCKS(port: authenticated.port))
        wait(for: [authenticated.done], timeout: 5)
        let other = try serve(reply: Array("HTTP/1.1 400\r\n".utf8))
        XCTAssertFalse(AppProxyListenerProbe.answersSOCKS(port: other.port))
        wait(for: [other.done], timeout: 5)
    }

    func testRejectsAClosedPort() throws {
        let server = try serve(reply: [5, 0])
        XCTAssertTrue(AppProxyListenerProbe.answersSOCKS(port: server.port))
        wait(for: [server.done], timeout: 5)
        // The one-shot server has closed its listener.
        XCTAssertFalse(AppProxyListenerProbe.answersSOCKS(port: server.port))
    }
}
