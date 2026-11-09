import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import XCTest
@testable import MihomoDNSCore

final class DNSBridgeListenersTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
    }

    /// The m4pro failure without root: SwiftNIO closes the UDP listener on an
    /// unrecoverable send error. A socket bound to loopback that sends off-host
    /// fails with EADDRNOTAVAIL, the same errno a reply from a removed alias
    /// gets. The TCP listener is untouched, and the owner rebinds UDP.
    func testSendErrorClosesOnlyUDPAndTheListenerIsRebound() throws {
        let forwarder = AnsweringForwarder()
        let (listeners, endpoint) = try startListeners(host: "127.0.0.1", forwarder: forwarder)
        defer { listeners.close() }
        let closes = CloseRecorder()
        listeners.setUnexpectedCloseHandler { closes.record($0) }
        let udp = try XCTUnwrap(listeners.channel(for: .udp))
        let tcp = try XCTUnwrap(listeners.channel(for: .tcp))

        var buffer = udp.allocator.buffer(capacity: 12)
        buffer.writeBytes(Data(repeating: 0, count: 12))
        let offHost = AddressedEnvelope(
            remoteAddress: try SocketAddress(ipAddress: "192.0.2.1", port: 53),
            data: buffer
        )
        do {
            try udp.writeAndFlush(offHost).wait()
            throw XCTSkip("this host accepted a loopback-sourced off-host datagram")
        } catch let error as IOError {
            XCTAssertEqual(error.errnoCode, EADDRNOTAVAIL)
        }
        try udp.closeFuture.wait()

        XCTAssertTrue(closes.wait(for: .udp))
        XCTAssertFalse(listeners.isListening)
        XCTAssertTrue(tcp.isActive, "only the datagram channel is closed by a send error")
        XCTAssertEqual(
            DNSListenerErrorClassifier.fields(for: IOError(errnoCode: EADDRNOTAVAIL, reason: "sendmsg")),
            "category=posix code=\(EADDRNOTAVAIL)"
        )

        XCTAssertTrue(listeners.ensureListening())
        XCTAssertTrue(listeners.isListening)
        XCTAssertTrue(listeners.channel(for: .tcp) === tcp, "an open listener is never replaced")
        XCTAssertFalse(listeners.channel(for: .udp) === udp)
        try assertAnswersOverUDPAndTCP(endpoint)
    }

    func testEnsureListeningRebindsAClosedListenerAndReportsTheClose() throws {
        let (listeners, endpoint) = try startListeners(host: "127.0.0.1", forwarder: AnsweringForwarder())
        defer { listeners.close() }
        let closes = CloseRecorder()
        listeners.setUnexpectedCloseHandler { closes.record($0) }

        try XCTUnwrap(listeners.channel(for: .tcp)).close().wait()

        XCTAssertTrue(closes.wait(for: .tcp))
        XCTAssertFalse(listeners.isListening)
        XCTAssertTrue(listeners.ensureListening())
        try assertAnswersOverUDPAndTCP(endpoint)
        XCTAssertTrue(listeners.ensureListening(), "rebinding is idempotent")
    }

    func testRebuildReplacesBothListenersWithoutReportingAnUnexpectedClose() throws {
        let (listeners, endpoint) = try startListeners(host: "127.0.0.1", forwarder: AnsweringForwarder())
        defer { listeners.close() }
        let closes = CloseRecorder()
        listeners.setUnexpectedCloseHandler { closes.record($0) }
        let udp = try XCTUnwrap(listeners.channel(for: .udp))
        let tcp = try XCTUnwrap(listeners.channel(for: .tcp))

        XCTAssertTrue(listeners.rebuild())

        XCTAssertFalse(listeners.channel(for: .udp) === udp)
        XCTAssertFalse(listeners.channel(for: .tcp) === tcp)
        XCTAssertFalse(udp.isActive)
        XCTAssertFalse(tcp.isActive)
        try assertAnswersOverUDPAndTCP(endpoint)
        XCTAssertTrue(closes.transports.isEmpty)
    }

    func testRebindFailureLeavesTheBridgeNotListeningUntilTheAddressIsFree() throws {
        let (listeners, endpoint) = try startListeners(host: "127.0.0.1", forwarder: AnsweringForwarder())
        defer { listeners.close() }
        try XCTUnwrap(listeners.channel(for: .udp)).close().wait()

        let squatter = try bindDatagramSocket(endpoint)
        XCTAssertFalse(listeners.ensureListening())
        XCTAssertFalse(listeners.ensureListening(), "a persistent failure keeps failing")
        XCTAssertFalse(listeners.isListening)
        XCTAssertNotNil(listeners.channel(for: .tcp))

        Darwin.close(squatter)
        XCTAssertTrue(listeners.ensureListening())
        try assertAnswersOverUDPAndTCP(endpoint)
    }

    func testCloseToleratesAListenerSwiftNIOAlreadyClosed() throws {
        let (listeners, _) = try startListeners(host: "127.0.0.1", forwarder: AnsweringForwarder())
        let closes = CloseRecorder()
        listeners.setUnexpectedCloseHandler { closes.record($0) }
        let udp = try XCTUnwrap(listeners.channel(for: .udp))
        let tcp = try XCTUnwrap(listeners.channel(for: .tcp))
        try udp.close().wait()
        XCTAssertTrue(closes.wait(for: .udp))

        listeners.close()

        XCTAssertFalse(tcp.isActive)
        XCTAssertFalse(listeners.isListening)
        XCTAssertFalse(listeners.ensureListening(), "a closed owner never rebinds")
        XCTAssertFalse(listeners.rebuild())
        XCTAssertNil(listeners.channel(for: .udp))
        XCTAssertEqual(closes.transports, [.udp], "an intentional close is not reported")
    }

    /// The exact m4pro sequence on a real loopback alias: a reply is pending
    /// when a rollback removes the alias, the reply fails, SwiftNIO closes the
    /// UDP listener, and after the alias returns only a rebind serves UDP again.
    func testPrivilegedAliasRemovalUnderPendingReplyRebindsUDP() throws {
        guard ProcessInfo.processInfo.environment["MIHOMO_DNS_PRIVILEGED_TESTS"] == "1" else {
            throw XCTSkip("set MIHOMO_DNS_PRIVILEGED_TESTS=1 and run as root")
        }
        // As root the default service log is the installed daemon's own log.
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomo-bridge-test-\(UUID().uuidString)")
        let logPath = logDirectory.appendingPathComponent("service.log").path
        ServiceLog.configure(
            logPath: logPath,
            crashLogPath: logDirectory.appendingPathComponent("crash.log").path
        )
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let alias = LoopbackAliasManager(
            interfaceName: "lo0",
            address: "127.0.0.252",
            netmask: "255.255.255.255",
            markerPath: marker
        )
        if try alias.isPresent() {
            throw XCTSkip("temporary loopback alias is already in use")
        }
        try alias.ensure()
        defer { try? alias.removeIfManaged() }

        let forwarder = HeldForwarder()
        let (listeners, endpoint) = try startListeners(host: "127.0.0.252", forwarder: forwarder)
        defer { listeners.close() }
        let closes = CloseRecorder()
        listeners.setUnexpectedCloseHandler { closes.record($0) }
        let tcp = try XCTUnwrap(listeners.channel(for: .tcp))

        let client = try UDPClient(endpoint: endpoint)
        defer { client.close() }
        let query = DNSMessage.addressQuery(for: "pending.invalid")!
        try client.send(query)
        XCTAssertTrue(forwarder.waitForQuery())

        try alias.removeIfManaged()
        XCTAssertFalse(try alias.isPresent())
        forwarder.releaseAnswer()

        XCTAssertTrue(closes.wait(for: .udp), "the failed reply closes the UDP listener")
        XCTAssertTrue(tcp.isActive)
        XCTAssertNil(try? client.receive(timeoutMilliseconds: 300))
        ServiceLog.flush()
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("event=udp_listener_write_failed category=posix code=\(EADDRNOTAVAIL)"))
        XCTAssertTrue(log.contains("event=dns_bridge_listener_closed protocol=udp"))
        XCTAssertFalse(log.contains("protocol=tcp"))

        try alias.ensure()
        XCTAssertTrue(listeners.ensureListening())
        forwarder.answerImmediately()
        try assertAnswersOverUDPAndTCP(endpoint)
    }

    // MARK: - Helpers

    private func startListeners(
        host: String,
        forwarder: AsyncDNSForwarding
    ) throws -> (DNSBridgeListeners, Endpoint) {
        var lastError: Error?
        for _ in 0 ..< 20 {
            let endpoint = Endpoint(host: host, port: Int.random(in: 20_000 ... 60_000))
            let listeners = DNSBridgeListeners(group: group, endpoint: endpoint, forwarder: forwarder)
            do {
                try listeners.start()
                return (listeners, endpoint)
            } catch {
                listeners.close()
                lastError = error
            }
        }
        throw lastError ?? ChannelError.ioOnClosedChannel
    }

    private func assertAnswersOverUDPAndTCP(
        _ endpoint: Endpoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let query = DNSMessage.addressQuery(for: "bridge.invalid", identifier: 0x5151)!
        let udp = try SocketDNSClient.query(
            query,
            endpoint: endpoint,
            timeoutMilliseconds: 1_000,
            interfaceName: nil
        )
        XCTAssertEqual(udp, AnsweringForwarder.answer(to: query), file: file, line: line)
        let tcp = try SocketDNSClient.queryTCP(
            query,
            endpoint: endpoint,
            timeoutMilliseconds: 1_000,
            interfaceName: nil
        )
        XCTAssertEqual(tcp, AnsweringForwarder.answer(to: query), file: file, line: line)
    }

    private func bindDatagramSocket(_ endpoint: Endpoint) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(endpoint.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(endpoint.host))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL)
        }
        return descriptor
    }
}

/// Answers every query with the query itself, marked as a response.
private final class AnsweringForwarder: AsyncDNSForwarding, @unchecked Sendable {
    static func answer(to query: Data) -> Data {
        var response = query
        response[response.startIndex + 2] |= 0x80
        return response
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        eventLoop.makeSucceededFuture(Self.answer(to: query))
    }
}

/// Holds the first answer until the test releases it, then answers at once.
private final class HeldForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private let received = DispatchSemaphore(value: 0)
    private var held: (EventLoopPromise<Data>, Data)?
    private var immediate = false

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        lock.lock()
        defer { lock.unlock() }
        if immediate || held != nil {
            return eventLoop.makeSucceededFuture(AnsweringForwarder.answer(to: query))
        }
        let promise = eventLoop.makePromise(of: Data.self)
        held = (promise, query)
        received.signal()
        return promise.futureResult
    }

    func waitForQuery() -> Bool {
        received.wait(timeout: .now() + 2) == .success
    }

    func releaseAnswer() {
        lock.lock()
        let pending = held
        lock.unlock()
        if let (promise, query) = pending {
            promise.succeed(AnsweringForwarder.answer(to: query))
        }
    }

    func answerImmediately() {
        lock.lock()
        immediate = true
        lock.unlock()
    }
}

private final class CloseRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var recorded: [DNSBridgeTransport] = []

    var transports: [DNSBridgeTransport] {
        condition.lock()
        defer { condition.unlock() }
        return recorded
    }

    func record(_ transport: DNSBridgeTransport) {
        condition.lock()
        recorded.append(transport)
        condition.broadcast()
        condition.unlock()
    }

    func wait(for transport: DNSBridgeTransport, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !recorded.contains(transport) {
            guard condition.wait(until: deadline) else { return recorded.contains(transport) }
        }
        return true
    }
}

/// A plain UDP client that keeps its source port across sends.
private final class UDPClient {
    private let descriptor: Int32

    init(endpoint: Endpoint) throws {
        descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(endpoint.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(endpoint.host))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    func send(_ data: Data) throws {
        let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw POSIXError(.EIO) }
    }

    func receive(timeoutMilliseconds: Int) throws -> Data {
        var timeout = timeval(
            tv_sec: timeoutMilliseconds / 1_000,
            tv_usec: Int32((timeoutMilliseconds % 1_000) * 1_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { throw POSIXError(.ETIMEDOUT) }
        return Data(buffer.prefix(count))
    }

    func close() {
        Darwin.close(descriptor)
    }
}

final class DNSBridgeOwnershipPolicyTests: XCTestCase {
    /// Under MTTA the port-53 probe is intercepted and answered with SERVFAIL
    /// even when nothing listens behind it; the probe accepts any RCODE. The
    /// agent's own listener state must veto it.
    func testClosedBridgeListenerVetoesAnInterceptedProbeAnswer() {
        var bridgeProbes = 0
        let result = RuntimeDNSHealthProbePolicy.evaluate(
            mihomoDNS: { true },
            bridgeListening: false,
            systemDNSBridge: {
                bridgeProbes += 1
                return true
            }
        )
        XCTAssertEqual(result, RuntimeDNSHealthProbeResult(dnsBridgeReady: false, mihomoDNSReady: true))
        XCTAssertEqual(bridgeProbes, 0)

        let listening = RuntimeDNSHealthProbePolicy.evaluate(
            mihomoDNS: { true },
            bridgeListening: true,
            systemDNSBridge: { true }
        )
        XCTAssertTrue(listening.dnsBridgeReady)
    }

    func testAcquisitionNeverPointsSystemDNSAtABridgeWithoutListeners() throws {
        for reprobeBridge in [false, true] {
            var operations: [String] = []
            let result = try DNSAcquisitionAttempt.run(
                reprobeBridge: reprobeBridge,
                ensureAlias: { operations.append("ensure_alias") },
                ensureListeners: {
                    operations.append("ensure_listeners")
                    return false
                },
                bridgeReady: {
                    operations.append("probe_bridge")
                    return true
                },
                applyDNS: { operations.append("apply_dns") }
            )
            XCTAssertEqual(result, .bridgeUnavailable)
            XCTAssertEqual(operations, ["ensure_alias", "ensure_listeners"])
        }
    }

    func testAcquisitionBindsListenersAfterTheAliasAndBeforeTheProbe() throws {
        var operations: [String] = []
        let result = try DNSAcquisitionAttempt.run(
            reprobeBridge: true,
            ensureAlias: { operations.append("ensure_alias") },
            ensureListeners: {
                operations.append("ensure_listeners")
                return true
            },
            bridgeReady: {
                operations.append("probe_bridge")
                return true
            },
            applyDNS: { operations.append("apply_dns") }
        )
        XCTAssertEqual(result, .managed)
        XCTAssertEqual(operations, ["ensure_alias", "ensure_listeners", "probe_bridge", "apply_dns"])
    }

    func testRuntimeRollbackKeepsTheAliasUnderBoundBridgeListeners() {
        XCTAssertFalse(SafeNetworkRestoreScope.runtimeRollback.removesLoopbackAlias(ownsBridgeListeners: true))
        XCTAssertTrue(SafeNetworkRestoreScope.runtimeRollback.removesLoopbackAlias(ownsBridgeListeners: false))
        XCTAssertTrue(SafeNetworkRestoreScope.shutdown.removesLoopbackAlias(ownsBridgeListeners: true))
        XCTAssertTrue(SafeNetworkRestoreScope.shutdown.removesLoopbackAlias(ownsBridgeListeners: false))
    }
}
