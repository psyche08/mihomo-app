import Darwin
import Foundation
@preconcurrency import NIOCore
import NIOFoundationCompat
@preconcurrency import NIOPosix

protocol AsyncDNSForwarding: AnyObject, Sendable {
    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data>
}

final class FixedAsyncDNSForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let endpoint: Endpoint
    private let timeoutMilliseconds: Int

    init(endpoint: Endpoint, timeoutMilliseconds: Int) {
        self.endpoint = endpoint
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        AsyncSocketDNSClient.query(
            query,
            endpoint: endpoint,
            timeoutMilliseconds: timeoutMilliseconds,
            interfaceName: nil,
            on: eventLoop
        )
    }
}

final class DynamicAsyncDNSForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let state: NetworkDNSState
    private let timeoutMilliseconds: Int

    init(state: NetworkDNSState, timeoutMilliseconds: Int) {
        self.state = state
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        do {
            try DNSMessage.validate(query)
            let upstream = state.snapshot().upstream(for: try? DNSMessage.questionName(query))
            guard !upstream.servers.isEmpty else {
                return eventLoop.makeFailedFuture(DNSForwardingError.noUpstream)
            }
            return attempt(
                query,
                upstream: upstream,
                serverIndex: 0,
                on: eventLoop
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
    }

    private func attempt(
        _ query: Data,
        upstream: DNSUpstreamSelection,
        serverIndex: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Data> {
        guard serverIndex < upstream.servers.count else {
            return eventLoop.makeFailedFuture(DNSForwardingError.allUpstreamsFailed)
        }
        return AsyncSocketDNSClient.query(
            query,
            endpoint: Endpoint(host: upstream.servers[serverIndex], port: 53),
            timeoutMilliseconds: timeoutMilliseconds,
            interfaceName: upstream.interfaceName,
            on: eventLoop
        ).flatMapError { [self] _ in
            attempt(
                query,
                upstream: upstream,
                serverIndex: serverIndex + 1,
                on: eventLoop
            )
        }
    }
}

final class FallbackAsyncDNSForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let primary: AsyncDNSForwarding
    private let fallback: AsyncDNSForwarding
    private let primaryAllowed: @Sendable (Data) -> Bool
    private let fallbackAllowed: @Sendable (Data) -> Bool
    private let metrics = AsyncDNSMetrics()

    init(
        primary: AsyncDNSForwarding,
        fallback: AsyncDNSForwarding,
        primaryAllowed: @escaping @Sendable (Data) -> Bool = { _ in true },
        fallbackAllowed: @escaping @Sendable (Data) -> Bool = { _ in true }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.primaryAllowed = primaryAllowed
        self.fallbackAllowed = fallbackAllowed
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        metrics.requestStarted()
        guard primaryAllowed(query) else {
            metrics.primaryBypassed()
            return runFallback(query, on: eventLoop)
        }
        return primary.forward(query, on: eventLoop).map { [metrics] response in
            metrics.primarySucceeded()
            metrics.requestFinished()
            return response
        }.flatMapError { [self] _ in
            metrics.primaryFailed()
            return runFallback(query, on: eventLoop)
        }
    }

    private func runFallback(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        guard fallbackAllowed(query) else {
            metrics.fallbackBlocked()
            metrics.requestFinished()
            return eventLoop.makeFailedFuture(DNSForwardingError.originalDNSForbidden)
        }
        return fallback.forward(query, on: eventLoop).map { [metrics] response in
            metrics.fallbackSucceeded()
            metrics.requestFinished()
            return response
        }.flatMapErrorThrowing { [metrics] error in
            metrics.fallbackFailed()
            metrics.requestFinished()
            throw error
        }
    }
}

private final class AsyncDNSMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.dns-metrics")
    private var timer: DispatchSourceTimer?
    private var requests = 0
    private var inFlight = 0
    private var peakInFlight = 0
    private var primarySuccesses = 0
    private var primaryFailures = 0
    private var primaryBypasses = 0
    private var fallbackSuccesses = 0
    private var fallbackFailures = 0
    private var fallbackBlockedCount = 0

    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }

    func requestStarted() {
        lock.lock()
        requests += 1
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        lock.unlock()
    }

    func requestFinished() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }

    func primarySucceeded() {
        increment(\.primarySuccesses)
    }

    func primaryFailed() {
        increment(\.primaryFailures)
    }

    func primaryBypassed() {
        increment(\.primaryBypasses)
    }

    func fallbackSucceeded() {
        increment(\.fallbackSuccesses)
    }

    func fallbackFailed() {
        increment(\.fallbackFailures)
    }

    func fallbackBlocked() {
        increment(\.fallbackBlockedCount)
    }

    private func increment(_ keyPath: ReferenceWritableKeyPath<AsyncDNSMetrics, Int>) {
        lock.lock()
        self[keyPath: keyPath] += 1
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        guard requests > 0 else {
            lock.unlock()
            return
        }
        let snapshot = (
            requests,
            peakInFlight,
            primarySuccesses,
            primaryFailures,
            primaryBypasses,
            fallbackSuccesses,
            fallbackFailures,
            fallbackBlockedCount
        )
        requests = 0
        peakInFlight = inFlight
        primarySuccesses = 0
        primaryFailures = 0
        primaryBypasses = 0
        fallbackSuccesses = 0
        fallbackFailures = 0
        fallbackBlockedCount = 0
        lock.unlock()
        ServiceLog.info(
            "event=dns_forwarding_summary requests=\(snapshot.0) " +
            "peak_inflight=\(snapshot.1) primary_success=\(snapshot.2) " +
            "primary_failure=\(snapshot.3) primary_bypassed=\(snapshot.4) " +
            "fallback_success=\(snapshot.5) fallback_failure=\(snapshot.6) " +
            "fallback_blocked=\(snapshot.7)"
        )
    }
}

enum AsyncSocketDNSClient {
    static func query(
        _ query: Data,
        endpoint: Endpoint,
        timeoutMilliseconds: Int,
        interfaceName: String?,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Data> {
        do {
            try DNSMessage.validate(query)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        return queryUDP(
            query,
            endpoint: endpoint,
            timeoutMilliseconds: timeoutMilliseconds,
            interfaceName: interfaceName,
            on: eventLoop
        ).flatMapThrowing { response in
            try validateResponse(response, query: query)
            return response
        }.flatMap { response in
            guard DNSMessage.isTruncated(response) else {
                return eventLoop.makeSucceededFuture(response)
            }
            return queryTCP(
                query,
                endpoint: endpoint,
                timeoutMilliseconds: timeoutMilliseconds,
                interfaceName: interfaceName,
                on: eventLoop
            ).flatMapThrowing { response in
                try validateResponse(response, query: query)
                return response
            }
        }
    }

    private static func queryUDP(
        _ query: Data,
        endpoint: Endpoint,
        timeoutMilliseconds: Int,
        interfaceName: String?,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Data> {
        let remote: SocketAddress
        let local: SocketAddress
        do {
            remote = try SocketAddress(ipAddress: endpoint.host, port: endpoint.port)
            local = try SocketAddress(
                ipAddress: endpoint.host.contains(":") ? "::" : "0.0.0.0",
                port: 0
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        let promise = eventLoop.makePromise(of: Data.self)
        let handler = SingleDatagramDNSHandler(
            query: query,
            remote: remote,
            timeoutMilliseconds: timeoutMilliseconds,
            promise: promise
        )
        var bootstrap = DatagramBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }
        do {
            bootstrap = try applyInterfaceOption(
                bootstrap,
                interfaceName: interfaceName,
                ipv6: endpoint.host.contains(":")
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        bootstrap.bind(to: local).whenFailure { error in
            handler.failIfPending(error)
        }
        return promise.futureResult
    }

    private static func queryTCP(
        _ query: Data,
        endpoint: Endpoint,
        timeoutMilliseconds: Int,
        interfaceName: String?,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Data> {
        let remote: SocketAddress
        do {
            remote = try SocketAddress(ipAddress: endpoint.host, port: endpoint.port)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        let promise = eventLoop.makePromise(of: Data.self)
        let handler = SingleTCPDNSHandler(
            query: query,
            timeoutMilliseconds: timeoutMilliseconds,
            promise: promise
        )
        var bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(.milliseconds(Int64(timeoutMilliseconds)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        ByteToMessageHandler(DNSTCPFrameDecoder()),
                        handler
                    )
                }
            }
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        do {
            bootstrap = try applyInterfaceOption(
                bootstrap,
                interfaceName: interfaceName,
                ipv6: endpoint.host.contains(":")
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        bootstrap.connect(to: remote).whenFailure { error in
            handler.failIfPending(error)
        }
        return promise.futureResult
    }

    private static func applyInterfaceOption(
        _ bootstrap: DatagramBootstrap,
        interfaceName: String?,
        ipv6: Bool
    ) throws -> DatagramBootstrap {
        guard let interfaceName, !interfaceName.isEmpty else { return bootstrap }
        let index = if_nametoindex(interfaceName)
        guard index != 0 else {
            throw DNSForwardingError.socketFailed(ENXIO)
        }
        return bootstrap.channelOption(
            ChannelOptions.socket(ipv6 ? IPPROTO_IPV6 : IPPROTO_IP, ipv6 ? IPV6_BOUND_IF : IP_BOUND_IF),
            value: CInt(index)
        )
    }

    private static func applyInterfaceOption(
        _ bootstrap: ClientBootstrap,
        interfaceName: String?,
        ipv6: Bool
    ) throws -> ClientBootstrap {
        guard let interfaceName, !interfaceName.isEmpty else { return bootstrap }
        let index = if_nametoindex(interfaceName)
        guard index != 0 else {
            throw DNSForwardingError.socketFailed(ENXIO)
        }
        return bootstrap.channelOption(
            ChannelOptions.socket(ipv6 ? IPPROTO_IPV6 : IPPROTO_IP, ipv6 ? IPV6_BOUND_IF : IP_BOUND_IF),
            value: CInt(index)
        )
    }

    private static func validateResponse(_ response: Data, query: Data) throws {
        try DNSMessage.validate(response)
        guard response.prefix(2) == query.prefix(2) else {
            throw DNSForwardingError.responseMismatch
        }
    }
}

private final class SingleDatagramDNSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let query: Data
    private let remote: SocketAddress
    private let timeoutMilliseconds: Int
    private let promise: EventLoopPromise<Data>
    private var timeoutTask: Scheduled<Void>?
    private var finished = false

    init(
        query: Data,
        remote: SocketAddress,
        timeoutMilliseconds: Int,
        promise: EventLoopPromise<Data>
    ) {
        self.query = query
        self.remote = remote
        self.timeoutMilliseconds = timeoutMilliseconds
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: query.count)
        buffer.writeBytes(query)
        let envelope = AddressedEnvelope(remoteAddress: remote, data: buffer)
        context.writeAndFlush(wrapOutboundOut(envelope), promise: nil)
        timeoutTask = context.eventLoop.scheduleTask(
            in: .milliseconds(Int64(timeoutMilliseconds))
        ) { [weak self, weak context] in
            self?.finish(
                .failure(DNSForwardingError.receiveFailed(ETIMEDOUT)),
                context: context
            )
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data).data
        guard let response = buffer.readData(length: buffer.readableBytes) else {
            finish(.failure(DNSForwardingError.invalidTCPResponse), context: context)
            return
        }
        finish(.success(response), context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error), context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failIfPending(DNSForwardingError.receiveFailed(ECONNRESET))
    }

    func failIfPending(_ error: Error) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        promise.fail(error)
    }

    private func finish(_ result: Result<Data, Error>, context: ChannelHandlerContext?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        promise.completeWith(result)
        context?.close(promise: nil)
    }
}

private final class SingleTCPDNSHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let query: Data
    private let timeoutMilliseconds: Int
    private let promise: EventLoopPromise<Data>
    private var timeoutTask: Scheduled<Void>?
    private var finished = false

    init(
        query: Data,
        timeoutMilliseconds: Int,
        promise: EventLoopPromise<Data>
    ) {
        self.query = query
        self.timeoutMilliseconds = timeoutMilliseconds
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: query.count + 2)
        buffer.writeInteger(UInt16(query.count))
        buffer.writeBytes(query)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        timeoutTask = context.eventLoop.scheduleTask(
            in: .milliseconds(Int64(timeoutMilliseconds))
        ) { [weak self, weak context] in
            self?.finish(
                .failure(DNSForwardingError.receiveFailed(ETIMEDOUT)),
                context: context
            )
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let response = buffer.readData(length: buffer.readableBytes) else {
            finish(.failure(DNSForwardingError.invalidTCPResponse), context: context)
            return
        }
        finish(.success(response), context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error), context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failIfPending(DNSForwardingError.receiveFailed(ECONNRESET))
    }

    func failIfPending(_ error: Error) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        promise.fail(error)
    }

    private func finish(_ result: Result<Data, Error>, context: ChannelHandlerContext?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        promise.completeWith(result)
        context?.close(promise: nil)
    }
}
