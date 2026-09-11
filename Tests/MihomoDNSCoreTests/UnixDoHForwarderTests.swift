import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
import XCTest
@testable import MihomoDNSCore

final class UnixDoHForwarderTests: XCTestCase {
    func testUnixPacketRoundTripAndUnsafeDirectoryRejection() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ipc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Darwin Unix socket paths are short; /tmp resolves to private/tmp.
        let path = directory.appendingPathComponent("s").path
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(EchoDNSHandler())
            }
        }.bind(unixDomainSocketPath: path).wait()
        defer { try? server.close().wait() }
        let forwarder = UnixDoHForwarder(path: path, owner: geteuid(), timeoutMilliseconds: 500)
        let originalDNS = RecordingOriginalDNS()
        let routed = LocalDoHForwarder(ipc: forwarder, originalDNS: originalDNS)
        let query = DNSMessage.runtimeHealthQuery
        var expected = query
        expected[2] |= 0x80
        expected[3] = 0x83 // NXDOMAIN must survive intact, not become a transport failure.
        XCTAssertEqual(try forwarder.forward(query, on: group.next()).wait(), expected)
        XCTAssertEqual(try routed.forward(query, on: group.next()).wait(), expected)
        XCTAssertEqual(originalDNS.calls, 0, "NXDOMAIN must not fall back")
        var servfailQuery = query
        servfailQuery[0] = 0xfb
        var servfail = servfailQuery
        servfail[2] |= 0x80
        servfail[3] = 0x82
        XCTAssertEqual(try routed.forward(servfailQuery, on: group.next()).wait(), servfail)
        XCTAssertEqual(originalDNS.calls, 0, "SERVFAIL must not fall back")
        XCTAssertThrowsError(try forwarder.forward(Data([0]), on: group.next()).wait())
        for marker: UInt8 in [0xfe, 0xfd] {
            var failureQuery = query
            failureQuery[0] = marker
            XCTAssertThrowsError(try routed.forward(failureQuery, on: group.next()).wait())
        }
        XCTAssertEqual(originalDNS.calls, 0, "HTTP/protocol errors must not bypass DNS policy")
        var timeoutQuery = query
        timeoutQuery[0] = 0xfc
        let shortDeadline = UnixDoHForwarder(path: path, owner: geteuid(), timeoutMilliseconds: 50)
        XCTAssertThrowsError(try shortDeadline.forward(timeoutQuery, on: group.next()).wait()) { error in
            guard case LocalDoHIPC.IPCError.timeout = error else {
                return XCTFail("expected bounded IPC deadline")
            }
        }
        let timeoutRouted = LocalDoHForwarder(ipc: shortDeadline, originalDNS: originalDNS)
        XCTAssertEqual(try timeoutRouted.forward(timeoutQuery, on: group.next()).wait(), originalDNS.response)
        XCTAssertEqual(originalDNS.calls, 1)
        // A deadline must release its in-flight slot and not poison later requests.
        XCTAssertEqual(try shortDeadline.forward(query, on: group.next()).wait(), expected)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try routed.forward(query, on: group.next()).wait())
        XCTAssertEqual(originalDNS.calls, 1, "unsafe socket permissions must fail closed")
    }

    func testPinnedMihomoResolvesRealAndFakeAddressesOverUnixIPC() throws {
        try checkPinnedMihomo(standby: false)
    }

    func testPinnedMihomoStandbyCatchAllReturnsRealAddressesOverUnixIPC() throws {
        try checkPinnedMihomo(standby: true)
    }

    private func checkPinnedMihomo(standby: Bool) throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = checkout.appendingPathComponent(".build/staging/mihomo-aarch64-apple-darwin")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("fetch pinned arm64 Mihomo before running native IPC integration")
        }
        let directory = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("ipc-native-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s").path
        let config = directory.appendingPathComponent("config.yaml")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let upstream = try DatagramBootstrap(group: group).channelInitializer { channel in
            channel.pipeline.addHandler(StaticDNSUpstream())
        }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try? upstream.close().wait() }
        let port = try XCTUnwrap(upstream.localAddress?.port)
        let client = UnixDoHForwarder(path: path, owner: geteuid(), timeoutMilliseconds: 1500)
        let routed = LocalDoHForwarder(
            ipc: client,
            originalDNS: FixedAsyncDNSForwarder(
                endpoint: Endpoint(host: "127.0.0.1", port: port), timeoutMilliseconds: 1000
            )
        )
        let fakeQuery = try XCTUnwrap(DNSMessage.addressQuery(for: "fake.example.invalid"))
        // No kernel/socket yet: DNS still works through the independent upstream.
        XCTAssertEqual(DNSMessage.firstIPv4Answer(try routed.forward(fakeQuery, on: group.next()).wait()), "203.0.113.9")
        // Isolated test kernel: no TUN, no TCP controller, no proxy listener,
        // no system DNS mutation, no production profile or credentials.
        try """
        mode: direct
        log-level: silent
        external-controller-unix: "\(path)"
        external-doh-server: /dns-query
        tun:
          enable: false
        dns:
          enable: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          fake-ip-filter-mode: \(standby ? "rule" : "blacklist")
          fake-ip-filter:
            - "\(standby ? "MATCH,real-ip" : "real.example.invalid")"
          use-hosts: false
          nameserver:
            - udp://127.0.0.1:\(port)

        """.write(to: config, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-d", directory.path, "-f", config.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: path), process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        let real = try client.forward(XCTUnwrap(DNSMessage.addressQuery(for: "real.example.invalid")), on: group.next()).wait()
        XCTAssertEqual(DNSMessage.firstIPv4Answer(real), "203.0.113.9")
        let fake = try routed.forward(fakeQuery, on: group.next()).wait()
        if standby {
            XCTAssertEqual(DNSMessage.firstIPv4Answer(fake), "203.0.113.9")
        } else {
            XCTAssertTrue(DNSMessage.firstIPv4Answer(fake)?.hasPrefix("198.18.") == true)
        }
        process.terminate()
        let stopDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < stopDeadline { usleep(10_000) }
        XCTAssertFalse(process.isRunning)
        // Same resolver instance automatically falls back after the kernel exits.
        XCTAssertEqual(DNSMessage.firstIPv4Answer(try routed.forward(fakeQuery, on: group.next()).wait()), "203.0.113.9")
    }
}

private final class RecordingOriginalDNS: AsyncDNSForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let response = Data(repeating: 0xab, count: 12)
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        lock.lock(); count += 1; lock.unlock()
        return eventLoop.makeSucceededFuture(response)
    }
}

private final class StaticDNSUpstream: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var packet = unwrapInboundIn(data)
        guard var bytes = packet.data.readBytes(length: packet.data.readableBytes), bytes.count >= 12 else { return }
        bytes[2] = 0x81; bytes[3] = 0x80
        bytes[6] = 0; bytes[7] = 1
        bytes[8] = 0; bytes[9] = 0; bytes[10] = 0; bytes[11] = 0
        // Compressed question name, A/IN, TTL=1, fixed documentation-only IPv4.
        bytes += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 1, 0, 4, 203, 0, 113, 9]
        var response = context.channel.allocator.buffer(capacity: bytes.count)
        response.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(.init(remoteAddress: packet.remoteAddress, data: response)), promise: nil)
    }
}

private final class EchoDNSHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var bytes = Data()
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            XCTAssertEqual(head.uri, "/dns-query")
            XCTAssertEqual(head.method, .POST)
        case .body(var buffer): bytes.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            if bytes[0] == 0xfc { return } // Simulate a connected but unresponsive backend.
            bytes[2] |= 0x80
            bytes[3] = bytes[0] == 0xfb ? 0x82 : 0x83
            let headers = HTTPHeaders([("content-type", bytes[0] == 0xfd ? "application/json" : "application/dns-message"),
                                       ("content-length", String(bytes.count))])
            context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: bytes[0] == 0xfe ? .internalServerError : .ok, headers: headers))), promise: nil)
            var body = context.channel.allocator.buffer(capacity: bytes.count)
            body.writeBytes(bytes)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
