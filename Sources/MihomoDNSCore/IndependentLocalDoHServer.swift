import Darwin
import Foundation
@preconcurrency import NIOCore
import NIOFoundationCompat
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

/// A loopback DoH endpoint whose lifetime is independent from Mihomo and TUN.
///
/// The root daemon owns this server. A healthy managed Mihomo DNS listener is
/// preferred so proxy domains retain Fake-IP semantics while the proxy is up;
/// the current physical/scoped resolver is an unconditional fallback so the
/// installed split-DNS profile never loses name resolution when Mihomo stops.
public final class IndependentLocalDoHServer: @unchecked Sendable {
    private static let identityDirectory = "/Library/Application Support/Mihomo App/local-doh"
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.local-doh")
    private let configurationPath: String
    private let primaryAvailable: @Sendable () -> Bool
    private var group: MultiThreadedEventLoopGroup?
    private var listener: Channel?
    private var networkState: NetworkDNSState?
    private var recoveryTimer: DispatchSourceTimer?
    private var recoveryFailureReported = false

    public init(
        configurationPath: String,
        primaryAvailable: @escaping @Sendable () -> Bool
    ) {
        self.configurationPath = configurationPath
        self.primaryAvailable = primaryAvailable
    }

    public var isRunning: Bool {
        queue.sync { listener?.isActive == true }
    }

    /// Keeps the endpoint bound for the daemon's lifetime. In particular, a
    /// short-lived port conflict during an in-place upgrade must not leave an
    /// installed DNS profile pointing at a dead endpoint until the next boot.
    @discardableResult
    public func startSupervising() -> Bool {
        queue.sync {
            if recoveryTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
                timer.setEventHandler { [weak self] in
                    self?.recoverIfNeededLocked()
                }
                recoveryTimer = timer
                timer.resume()
            }
            return startIfPreparedLocked()
        }
    }

    /// Starts the fixed endpoint whenever its root-owned identity is present.
    /// Absence means Local DoH has never been prepared and is not an error.
    @discardableResult
    public func startIfPrepared() throws -> Bool {
        try queue.sync {
            try startIfPreparedLockedThrowing()
        }
    }

    /// Stops the current listener without disabling supervision. Used only
    /// while the fixed TLS identity is atomically replaced or rolled back.
    public func stopServing() {
        queue.sync { stopLocked() }
    }

    public func shutdown() {
        queue.sync {
            recoveryTimer?.cancel()
            recoveryTimer = nil
            stopLocked()
        }
    }

    private func startIfPreparedLockedThrowing() throws -> Bool {
        if listener?.isActive == true { return true }
        guard Self.identityIsPrepared() else { return false }
        let configuration = try ProxyConfiguration.load(path: configurationPath)
        try startLocked(configuration: configuration)
        recoveryFailureReported = false
        return true
    }

    private func startIfPreparedLocked() -> Bool {
        do {
            return try startIfPreparedLockedThrowing()
        } catch {
            if !recoveryFailureReported {
                recoveryFailureReported = true
                ServiceLog.error("event=local_doh_server_recovery result=failed")
            }
            return false
        }
    }

    private func recoverIfNeededLocked() {
        guard listener?.isActive != true else { return }
        _ = startIfPreparedLocked()
    }

    private func startLocked(configuration: ProxyConfiguration) throws {
        stopLocked()
        let localDoH = LocalDoHConfiguration()
        let certificates = try NIOSSLCertificate.fromPEMFile(localDoH.certificatePath)
        let privateKey = try NIOSSLPrivateKey(file: localDoH.privateKeyPath, format: .pem)
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        tls.applicationProtocols = ["http/1.1"]
        let sslContext = try NIOSSLContext(configuration: tls)

        let networkState = NetworkDNSState(
            excludedServers: [
                configuration.systemDNSListen.host,
                configuration.mihomoDNS.host,
                configuration.upstreamListen.host,
                localDoH.endpoint.host,
            ],
            fallbackServers: configuration.fallbackDNSServers
        )
        try networkState.start()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: min(2, max(1, System.coreCount)))
        let primary = FixedAsyncDNSForwarder(
            endpoint: configuration.mihomoDNS,
            timeoutMilliseconds: min(configuration.queryTimeoutMilliseconds, 1_000)
        )
        let fallback = DynamicAsyncDNSForwarder(
            state: networkState,
            timeoutMilliseconds: configuration.queryTimeoutMilliseconds
        )
        let forwarder = FallbackAsyncDNSForwarder(
            primary: primary,
            fallback: fallback,
            primaryAllowed: { [primaryAvailable] _ in primaryAvailable() },
            fallbackAllowed: { _ in true }
        )

        do {
            let listener = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 128)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLServerHandler(context: sslContext)
                        )
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    return channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(LocalDoHHTTPHandler(forwarder: forwarder))
                    }
                }
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .bind(host: localDoH.endpoint.host, port: localDoH.endpoint.port)
                .wait()
            self.group = group
            self.listener = listener
            self.networkState = networkState
            ServiceLog.info("event=local_doh_server_started")
        } catch {
            networkState.stop()
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    private func stopLocked() {
        let wasRunning = listener?.isActive == true
        if let listener {
            try? listener.close().wait()
        }
        listener = nil
        networkState?.stop()
        networkState = nil
        if let group {
            try? group.syncShutdownGracefully()
        }
        group = nil
        if wasRunning {
            ServiceLog.info("event=local_doh_server_stopped")
        }
    }

    private static func identityIsPrepared() -> Bool {
        var directory = stat()
        guard lstat(identityDirectory, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == 0,
              directory.st_gid == 0,
              directory.st_mode & 0o777 == 0o700 else { return false }
        return isRootFile("\(identityDirectory)/server.crt", permissions: 0o644)
            && isRootFile("\(identityDirectory)/server.key", permissions: 0o600)
    }

    private static func isRootFile(_ path: String, permissions: mode_t) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == 0
            && metadata.st_gid == 0
            && metadata.st_mode & 0o777 == permissions
            && metadata.st_size > 0
            && metadata.st_size <= 128 * 1_024
    }
}

enum LocalDoHHTTPError: Error, Equatable {
    case malformedRequest
    case methodNotAllowed
    case notFound
    case unsupportedMediaType
    case payloadTooLarge
}

enum LocalDoHHTTPRequest {
    static func query(head: HTTPRequestHead, body: ByteBuffer) throws -> Data {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path == "/dns-query" else { throw LocalDoHHTTPError.notFound }
        let query: Data
        switch head.method {
        case .POST:
            guard let type = head.headers.first(name: "content-type")?
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else {
                throw LocalDoHHTTPError.unsupportedMediaType
            }
            guard type == "application/dns-message" else {
                throw LocalDoHHTTPError.unsupportedMediaType
            }
            query = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()
        case .GET:
            guard let components = URLComponents(string: "https://localhost\(head.uri)"),
                  let encoded = components.queryItems?.first(where: { $0.name == "dns" })?.value,
                  let decoded = decodeBase64URL(encoded) else {
                throw LocalDoHHTTPError.malformedRequest
            }
            query = decoded
        default:
            throw LocalDoHHTTPError.methodNotAllowed
        }
        guard query.count <= DNSMessage.maximumWireLength else {
            throw LocalDoHHTTPError.payloadTooLarge
        }
        try DNSMessage.validate(query)
        return query
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.utf8.count <= 4 * ((DNSMessage.maximumWireLength + 2) / 3) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

final class LocalDoHHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let forwarder: AsyncDNSForwarding
    private var head: HTTPRequestHead?
    private var body = ByteBufferAllocator().buffer(capacity: 512)
    private var rejected: HTTPResponseStatus?

    init(forwarder: AsyncDNSForwarding) {
        self.forwarder = forwarder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            guard self.head == nil else {
                respond(status: .badRequest, context: context, close: true)
                return
            }
            self.head = head
            body.clear()
            rejected = nil
            if let length = head.headers.first(name: "content-length").flatMap(Int.init),
               length > DNSMessage.maximumWireLength {
                rejected = .payloadTooLarge
            }
        case var .body(chunk):
            guard rejected == nil else { return }
            guard body.readableBytes + chunk.readableBytes <= DNSMessage.maximumWireLength else {
                rejected = .payloadTooLarge
                return
            }
            body.writeBuffer(&chunk)
        case .end:
            guard let head else {
                respond(status: .badRequest, context: context, close: true)
                return
            }
            if let rejected {
                reset()
                respond(status: rejected, context: context, close: !head.isKeepAlive)
                return
            }
            do {
                let query = try LocalDoHHTTPRequest.query(head: head, body: body)
                let keepAlive = head.isKeepAlive
                let loopBoundContext = context.loopBound
                reset()
                forwarder.forward(query, on: context.eventLoop).whenComplete { [weak self] result in
                    guard let self else { return }
                    let context = loopBoundContext.value
                    switch result {
                    case let .success(response):
                        self.respond(
                            status: .ok,
                            body: response,
                            context: context,
                            close: !keepAlive
                        )
                    case .failure:
                        self.respond(status: .badGateway, context: context, close: !keepAlive)
                    }
                }
            } catch let error as LocalDoHHTTPError {
                reset()
                let status: HTTPResponseStatus = switch error {
                case .methodNotAllowed: .methodNotAllowed
                case .notFound: .notFound
                case .unsupportedMediaType: .unsupportedMediaType
                case .payloadTooLarge: .payloadTooLarge
                case .malformedRequest: .badRequest
                }
                respond(status: status, context: context, close: !head.isKeepAlive)
            } catch {
                reset()
                respond(status: .badRequest, context: context, close: !head.isKeepAlive)
            }
        }
    }

    private func reset() {
        head = nil
        body.clear()
        rejected = nil
    }

    private func respond(
        status: HTTPResponseStatus,
        body: Data? = nil,
        context: ChannelHandlerContext,
        close: Bool
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "content-length", value: String(body?.count ?? 0))
        headers.add(name: "cache-control", value: "no-store")
        if body != nil {
            headers.add(name: "content-type", value: "application/dns-message")
        }
        if close { headers.add(name: "connection", value: "close") }
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
            promise: nil
        )
        if let body {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let loopBoundContext = context.loopBound
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if close { loopBoundContext.value.close(promise: nil) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
