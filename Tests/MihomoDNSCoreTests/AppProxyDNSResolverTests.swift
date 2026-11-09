import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import XCTest
@testable import MihomoDNSCore

final class AppProxyDNSResolverTests: XCTestCase {
    private let query = DNSMessage.addressQuery(for: "example.com", identifier: 0x2468)!

    func testAnswersFromTheCoreListenerArePassedThroughUnchanged() throws {
        var answer = query
        answer[2] = 0x81; answer[3] = 0x80; answer[7] = 1
        answer.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 1, 0, 4, 198, 18, 0, 7])
        let server = try UDPResponder { _ in answer }
        defer { server.close() }
        let resolver = AppProxyDNSResolver(endpoint: server.endpoint, timeoutMilliseconds: 1_000)
        defer { resolver.shutdown() }
        XCTAssertEqual(try resolve(query, with: resolver), .success(answer))
        XCTAssertEqual(resolver.outstanding, 0)
    }

    func testMismatchedOrMissingAnswersFailClosed() throws {
        var mismatched = query
        mismatched[2] = 0x81; mismatched[0] ^= 1
        let server = try UDPResponder { _ in mismatched }
        defer { server.close() }
        let resolver = AppProxyDNSResolver(endpoint: server.endpoint, timeoutMilliseconds: 300)
        defer { resolver.shutdown() }
        // The client drops answers whose ID does not match, so the query times out.
        XCTAssertEqual(try resolve(query, with: resolver), .failure(.unavailable))

        let silent = try UDPResponder { _ in nil }
        defer { silent.close() }
        let quiet = AppProxyDNSResolver(endpoint: silent.endpoint, timeoutMilliseconds: 200)
        defer { quiet.shutdown() }
        XCTAssertEqual(try resolve(query, with: quiet), .failure(.unavailable))
        XCTAssertEqual(quiet.outstanding, 0)
    }

    func testInvalidQueriesAndExcessLoadAreRejectedWithoutSending() throws {
        let server = try UDPResponder { _ in XCTFail("nothing may be sent"); return nil }
        defer { server.close() }
        let resolver = AppProxyDNSResolver(endpoint: server.endpoint, timeoutMilliseconds: 200)
        defer { resolver.shutdown() }
        XCTAssertEqual(try resolve(Data([1, 2, 3]), with: resolver), .failure(.invalidQuery))
        var response = query; response[2] |= 0x80
        XCTAssertEqual(try resolve(response, with: resolver), .failure(.invalidQuery))

        let saturated = AppProxyDNSResolver(
            endpoint: server.endpoint, timeoutMilliseconds: 200, maximumInFlight: 0
        )
        defer { saturated.shutdown() }
        XCTAssertEqual(try resolve(query, with: saturated), .failure(.busy))

        let closed = AppProxyDNSResolver(endpoint: server.endpoint, timeoutMilliseconds: 200)
        closed.shutdown()
        XCTAssertEqual(try resolve(query, with: closed), .failure(.busy))
    }

    private func resolve(
        _ query: Data, with resolver: AppProxyDNSResolver
    ) throws -> Result<Data, AppProxyDNSResolver.Failure> {
        let done = expectation(description: "resolved")
        let box = ResultBox()
        resolver.resolve(query) { result in
            box.set(result)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(box.result)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, AppProxyDNSResolver.Failure>?
    var result: Result<Data, AppProxyDNSResolver.Failure>? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func set(_ value: Result<Data, AppProxyDNSResolver.Failure>) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }
}

/// A loopback UDP responder standing in for the core's DNS listener.
private final class UDPResponder: @unchecked Sendable {
    private let socket: Int32
    private let thread: Thread
    let endpoint: Endpoint

    init(answer: @escaping @Sendable (Data) -> Data?) throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        self.socket = socket
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { Darwin.close(socket); throw POSIXError(.EADDRNOTAVAIL) }
        endpoint = Endpoint(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)))
        thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socket, &buffer, buffer.count, 0, $0, &peerLength)
                    }
                }
                guard count > 0 else { return }
                guard let reply = answer(Data(buffer[0..<count])) else { continue }
                _ = reply.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socket, bytes.baseAddress, bytes.count, 0, $0, peerLength)
                        }
                    }
                }
            }
        }
        thread.start()
    }

    func close() {
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }
}
