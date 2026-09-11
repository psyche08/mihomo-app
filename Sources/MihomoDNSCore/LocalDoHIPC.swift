import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

public enum LocalDoHIPC {
    public static let directory = "/Library/Application Support/Mihomo App/mihomo-data/.dns-ipc"
    public static let socketPath = directory + "/mihomo.sock"
    public static let requestPath = "/dns-query"

    public static func socketIsProtected() -> Bool {
        socketIsProtected(path: socketPath, owner: 0)
    }

    static func socketIsProtected(path: String, owner: uid_t) -> Bool {
        do {
            try validateSocket(path: path, owner: owner)
            return true
        } catch { return false }
    }

    static func validateSocket(path: String, owner: uid_t) throws {
        var directory = stat(), socket = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &directory) == 0 else {
            throw errno == ENOENT ? IPCError.unavailable : IPCError.unsafeSocket
        }
        guard directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == owner, directory.st_mode & 0o777 == 0o700 else {
            throw IPCError.unsafeSocket
        }
        guard lstat(path, &socket) == 0 else {
            throw errno == ENOENT ? IPCError.unavailable : IPCError.unsafeSocket
        }
        guard socket.st_mode & S_IFMT == S_IFSOCK, socket.st_uid == owner else {
            throw IPCError.unsafeSocket
        }
    }

    /// Mihomo makes its Unix control socket 0666 and disables HTTP auth on
    /// it. The non-traversable root directory is therefore mandatory.
    public static func prepareDirectory() throws {
        guard geteuid() == 0 else { throw IPCError.unsafeSocket }
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT, mkdir(directory, 0o700) == 0 else {
                throw IPCError.unsafeSocket
            }
        }
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == 0, info.st_gid == 0, info.st_mode & 0o777 == 0o700 else {
            throw IPCError.unsafeSocket
        }
    }

    enum IPCError: Error { case unsafeSocket, invalidResponse, unavailable, timeout, overloaded }
}

/// Byte-preserving RFC 8484 over AF_UNIX. Never uses /dns/query's JSON
/// diagnostics endpoint, which is not the Fake-IP DNS packet resolver.
final class UnixDoHForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let path: String
    private let owner: uid_t
    private let timeout: Int
    private let lock = NSLock()
    private var inFlight = 0

    init(path: String = LocalDoHIPC.socketPath, owner: uid_t = 0,
         timeoutMilliseconds: Int) {
        self.path = path
        self.owner = owner
        timeout = timeoutMilliseconds
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        guard query.count >= 12, query.count <= DNSMessage.maximumWireLength else {
            return eventLoop.makeFailedFuture(LocalDoHIPC.IPCError.invalidResponse)
        }
        do { try LocalDoHIPC.validateSocket(path: path, owner: owner) }
        catch { return eventLoop.makeFailedFuture(error) }
        lock.lock()
        guard inFlight < 128 else {
            lock.unlock()
            return eventLoop.makeFailedFuture(LocalDoHIPC.IPCError.overloaded)
        }
        inFlight += 1
        lock.unlock()
        let promise = eventLoop.makePromise(of: Data.self)
        let handler = UnixDoHResponse(query: query, promise: promise)
        let deadline = eventLoop.scheduleTask(in: .milliseconds(Int64(timeout))) {
            handler.fail(LocalDoHIPC.IPCError.timeout)
        }
        promise.futureResult.whenComplete { [self] _ in
            deadline.cancel()
            lock.lock(); inFlight -= 1; lock.unlock()
        }
        ClientBootstrap(group: eventLoop)
            .connectTimeout(.milliseconds(Int64(timeout)))
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.pipeline.addHandler(handler)
                }
            }
            .connect(unixDomainSocketPath: path).whenFailure { error in
                if let io = error as? IOError, io.errnoCode == ENOENT || io.errnoCode == ECONNREFUSED {
                    handler.fail(LocalDoHIPC.IPCError.unavailable)
                } else {
                    handler.fail(error)
                }
            }
        return promise.futureResult
    }
}

/// The daemon owns both branches, so stopping the agent never stops DNS.
/// Only transport absence/timeouts enable original DNS, not a DNS RCODE,
/// unsafe socket, malformed response, or overloaded IPC queue.
final class LocalDoHForwarder: AsyncDNSForwarding, @unchecked Sendable {
    private let ipc: AsyncDNSForwarding
    private let originalDNS: AsyncDNSForwarding

    init(ipc: AsyncDNSForwarding, originalDNS: AsyncDNSForwarding) {
        self.ipc = ipc
        self.originalDNS = originalDNS
    }

    func forward(_ query: Data, on eventLoop: EventLoop) -> EventLoopFuture<Data> {
        ipc.forward(query, on: eventLoop).flatMapError { [self] error in
            switch error {
            case LocalDoHIPC.IPCError.unavailable, LocalDoHIPC.IPCError.timeout:
                return originalDNS.forward(query, on: eventLoop)
            default:
                return eventLoop.makeFailedFuture(error)
            }
        }
    }
}

private final class UnixDoHResponse: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let query: Data
    let promise: EventLoopPromise<Data>
    private var channel: Channel?
    private var done = false
    private var accepted = false
    private var body = Data()

    init(query: Data, promise: EventLoopPromise<Data>) {
        self.query = query; self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        channel = context.channel
        guard !done else { context.close(promise: nil); return }
        let headers = HTTPHeaders([
            ("Host", "localhost"), ("Content-Type", "application/dns-message"),
            ("Accept", "application/dns-message"), ("Content-Length", String(query.count)),
            ("Connection", "close"),
        ])
        context.write(wrapOutboundOut(.head(.init(
            version: .http1_1, method: .POST, uri: LocalDoHIPC.requestPath, headers: headers
        ))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: query.count)
        buffer.writeBytes(query)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            accepted = head.status == .ok
                && head.headers.first(name: "content-type") == "application/dns-message"
            if !accepted { fail(LocalDoHIPC.IPCError.invalidResponse) }
        case .body(var bytes):
            guard body.count + bytes.readableBytes <= DNSMessage.maximumWireLength else {
                fail(LocalDoHIPC.IPCError.invalidResponse); return
            }
            body.append(contentsOf: bytes.readBytes(length: bytes.readableBytes) ?? [])
        case .end:
            guard accepted, body.count >= 12, query.count >= 12,
                  body.prefix(2) == query.prefix(2), body[2] & 0x80 != 0 else {
                fail(LocalDoHIPC.IPCError.invalidResponse); return
            }
            done = true
            promise.succeed(body)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) { fail(LocalDoHIPC.IPCError.unavailable) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error) }
    func fail(_ error: Error) {
        guard !done else { return }
        done = true
        promise.fail(error)
        channel?.close(promise: nil)
    }
}
