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

    func testResidentReloadKeepsPIDProxyStreamsAndIndependentDNSPolicy() throws {
        try checkPinnedMihomo(standby: true, residentReload: true)
    }

    private func checkPinnedMihomo(standby: Bool, residentReload: Bool = false) throws {
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
        // All sockets are isolated loopback test endpoints. TUN stays disabled;
        // the test never changes system DNS/routes or uses production settings.
        let reservations = try (0..<3).map { _ in
            try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        }
        let ports = try reservations.map { try XCTUnwrap($0.localAddress?.port) }
        for channel in reservations { try channel.close().wait() }
        let controllerPort = ports[0], mixedPort = ports[1], appPort = ports[2]
        let extra = residentReload ? """
        external-controller: 127.0.0.1:\(controllerPort)
        secret: resident-test-only
        mixed-port: \(mixedPort)
        listeners:
          - name: resident-app
            type: mixed
            listen: 127.0.0.1
            port: \(appPort)
            rule: resident-app
        sub-rules:
          resident-app:
            - MATCH,DIRECT

        """ : ""
        let initialProfile = """
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

        """
        try (extra + initialProfile).write(to: config, atomically: true, encoding: .utf8)
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
        // The Unix listener can exist before the pinned core's DNS handler is
        // ready. Probe readiness instead of treating socket creation as readiness.
        // Only startup is retried; the assertions and shutdown probes below are not.
        let realQuery = try XCTUnwrap(DNSMessage.addressQuery(for: "real.example.invalid"))
        var readyResponse: Data?
        var startupError: Error?
        while process.isRunning, Date() < deadline {
            do {
                readyResponse = try client.forward(realQuery, on: group.next()).wait()
                break
            } catch {
                startupError = error
                usleep(20_000)
            }
        }
        guard let real = readyResponse else {
            throw startupError ?? LocalDoHIPC.IPCError.unavailable
        }
        XCTAssertEqual(DNSMessage.firstIPv4Answer(real), "203.0.113.9")
        let fake = try routed.forward(fakeQuery, on: group.next()).wait()
        if standby {
            XCTAssertEqual(DNSMessage.firstIPv4Answer(fake), "203.0.113.9")
        } else {
            XCTAssertTrue(DNSMessage.firstIPv4Answer(fake)?.hasPrefix("198.18.") == true)
        }
        if residentReload {
            let echo = try ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.addHandler(ResidentEchoHandler())
            }.bind(host: "127.0.0.1", port: 0).wait()
            defer { try? echo.close().wait() }
            let echoPort = try XCTUnwrap(echo.localAddress?.port)
            // DNS and proxy listeners become reachable before the core has
            // completed all startup stages. Establish data-plane readiness for
            // the initial streams; reload/retained-stream checks never retry.
            let mixed = try ResidentProxyStream.ready(proxyPort: mixedPort, targetPort: echoPort)
            let app = try ResidentProxyStream.ready(proxyPort: appPort, targetPort: echoPort)
            let pid = process.processIdentifier
            let configuration = ProxyConfiguration(
                manageSystemDNS: false, enhancedTUNEnabled: false,
                mihomoProcess: .init(binaryPath: binary.path, configDirectory: directory.path,
                                     configPath: config.path),
                controllerEndpoint: .init(host: "127.0.0.1", port: controllerPort),
                controllerSecret: "resident-test-only", localDoH: .init()
            )
            try mixed.checkEcho(label: "initial mixed"); try app.checkEcho(label: "initial app")
            let sourceProfile = (extra + initialProfile)
                .replacingOccurrences(of: "enable: false", with: "enable: true")
                .replacingOccurrences(of: "fake-ip-filter-mode: rule", with: "fake-ip-filter-mode: blacklist")
                .replacingOccurrences(of: "MATCH,real-ip", with: "real.example.invalid")
            for nextStandby in [false, true, false, true] {
                var policy = configuration
                policy.enhancedTUNEnabled = !nextStandby
                var profile = try MihomoConfigurator.residentProfile(
                    String(contentsOf: config, encoding: .utf8), sourceProfile: sourceProfile, configuration: policy
                )
                // Exercise the production DNS rewrite without creating a
                // privileged interface in this isolated loopback-only test.
                profile = profile.replacingOccurrences(of: "tun:\n  enable: true", with: "tun:\n  enable: false")
                // The live Direct choice must survive a source profile in Rule mode.
                profile = profile.replacingOccurrences(of: "mode: direct", with: "mode: rule")
                try profile.write(to: config, atomically: true, encoding: .utf8)
                try MihomoRuntimeInspector.reloadResidentMihomo(configuration: configuration)
                MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: configuration)
                XCTAssertTrue(process.isRunning)
                XCTAssertEqual(process.processIdentifier, pid)
                XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("mode: direct"))
                let address = DNSMessage.firstIPv4Answer(try client.forward(fakeQuery, on: group.next()).wait())
                if nextStandby { XCTAssertEqual(address, "203.0.113.9") }
                else { XCTAssertTrue(address?.hasPrefix("198.18.") == true) }
                // Both established streams AND newly accepted connections must work.
                try mixed.checkEcho(label: "retained mixed standby=\(nextStandby)")
                try app.checkEcho(label: "retained app standby=\(nextStandby)")
                try ResidentProxyStream(proxyPort: mixedPort, targetPort: echoPort).checkEcho()
                try ResidentProxyStream(proxyPort: appPort, targetPort: echoPort).checkEcho()
            }
            // A rejected parse cannot kill the core or existing proxy connections.
            try "tun: [invalid".write(to: config, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try MihomoRuntimeInspector.reloadResidentMihomo(configuration: configuration))
            XCTAssertTrue(process.isRunning)
            try mixed.checkEcho(); try app.checkEcho()
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

private final class ResidentEchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// Bounded TCP checks through the real pinned core, with no external network.
private final class ResidentProxyStream {
    private let descriptor: Int32
    static func ready(proxyPort: Int, targetPort: Int) throws -> ResidentProxyStream {
        let deadline = Date().addingTimeInterval(5)
        while true {
            do {
                let stream = try ResidentProxyStream(proxyPort: proxyPort, targetPort: targetPort)
                try stream.checkEcho(label: "startup readiness")
                return stream
            } catch {
                guard Date() < deadline else { throw error }
                usleep(10_000)
            }
        }
    }
    init(proxyPort: Int, targetPort: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "ResidentTestSocket", code: 1) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(proxyPort).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(descriptor); throw NSError(domain: "ResidentTestConnect", code: 1) }
        do {
            try sendAll(Data("CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n".utf8))
            var header = Data()
            while header.count < 4096, !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
                header.append(try receive(count: 1))
            }
            guard String(decoding: header, as: UTF8.self).hasPrefix("HTTP/1.1 200") else {
                throw NSError(domain: "ResidentTestCONNECT", code: 1)
            }
        } catch { close(descriptor); throw error }
    }
    deinit { close(descriptor) }
    func checkEcho(label: String = "new stream") throws {
        let payload = Data(UUID().uuidString.utf8)
        do {
            try sendAll(payload)
            let received = try receive(count: payload.count)
            XCTAssertEqual(received, payload, label)
        } catch {
            throw NSError(domain: "ResidentTestEcho: " + label, code: 1, userInfo: [NSUnderlyingErrorKey: error])
        }
    }
    private func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw NSError(domain: "ResidentTestSend", code: 1) }
                offset += count
            }
        }
    }
    private func receive(count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let size = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            guard size > 0 else { throw NSError(domain: "ResidentTestReceive", code: 1) }
            result.append(contentsOf: buffer.prefix(size))
        }
        return result
    }
}
