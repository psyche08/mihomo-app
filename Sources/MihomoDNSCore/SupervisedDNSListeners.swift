import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// One transport of an agent DNS listener.
enum DNSListenerTransport: String, CaseIterable, Sendable {
    case udp
    case tcp
}

/// Which agent DNS listener a pair of channels serves. Only the role reaches
/// the service log, never the listening address.
enum DNSListenerRole: String, Sendable {
    /// The `127.0.0.53:53` Global DNS bridge, rebound by the consistency
    /// observer because its loopback alias may be absent.
    case bridge
    /// The `127.0.0.1:1054` original-DNS escape, which rebinds itself.
    case escape

    var eventPrefix: String { "dns_\(rawValue)_listener" }
}

/// What the consistency observer needs from the agent-owned bridge listeners.
///
/// Every method may block on a SwiftNIO future and must never be called on an
/// event loop. The unexpected-close handler runs on an event loop and must only
/// hand the work to another queue.
protocol DNSBridgeListenerControl: AnyObject, Sendable {
    /// Whether both transports are currently open.
    var isListening: Bool { get }
    /// Rebinds every transport that is no longer open. Returns whether both
    /// transports are open afterwards.
    func ensureListening() -> Bool
    /// Closes and rebinds both transports.
    @discardableResult func rebuild() -> Bool
    func setUnexpectedCloseHandler(_ handler: (@Sendable (DNSListenerTransport) -> Void)?)
}

/// Owns the UDP and TCP listeners of one agent DNS endpoint: the
/// `127.0.0.53:53` Global DNS bridge or the `127.0.0.1:1054` original-DNS
/// escape.
///
/// SwiftNIO closes a datagram channel after any send error other than EMSGSIZE
/// or EHOSTUNREACH, and it does so without calling `errorCaught`. The kernel
/// keeps an idle socket bound to the loopback alias while the alias is removed
/// and delivers to it again once the alias returns, but a reply sent from the
/// alias while it is absent fails with EADDRNOTAVAIL. A rollback that removed
/// the alias under an in-flight query therefore silently closed the bridge's
/// UDP listener, the TCP listener survived, and nothing rebound UDP until the
/// agent restarted. Any other unrecoverable send error, such as ENOBUFS, does
/// the same to the escape. This owner reports an unexpected close and rebinds
/// on demand or, with `enableAutomaticRebind`, by itself.
final class SupervisedDNSListeners: DNSBridgeListenerControl, @unchecked Sendable {
    typealias Binder = (DNSListenerTransport) throws -> Channel

    /// Delays before each automatic rebind attempt; the last one repeats.
    static let defaultRebindDelays: [DispatchTimeInterval] = [
        .milliseconds(100), .seconds(1), .seconds(5), .seconds(30),
    ]

    let role: DNSListenerRole
    private let binder: Binder
    private let lock = NSLock()
    private var channels: [DNSListenerTransport: Channel] = [:]
    /// Channels this owner closes itself; their close is not reported.
    private var intentionallyClosed = Set<ObjectIdentifier>()
    private var unexpectedCloseHandler: (@Sendable (DNSListenerTransport) -> Void)?
    /// Last rebind failure per transport, so a persistent failure is logged
    /// once instead of on every attempt.
    private var lastRebindFailure: [DNSListenerTransport: String] = [:]
    private var automaticRebindQueue: DispatchQueue?
    private var automaticRebindDelays = SupervisedDNSListeners.defaultRebindDelays
    private var automaticRebindPending = false
    private var closed = false

    init(role: DNSListenerRole, binder: @escaping Binder) {
        self.role = role
        self.binder = binder
    }

    convenience init(
        role: DNSListenerRole,
        group: EventLoopGroup,
        endpoint: Endpoint,
        forwarder: AsyncDNSForwarding
    ) {
        self.init(role: role) { transport in
            switch transport {
            case .udp:
                return try DNSListenerBootstrap.bindUDP(
                    group: group, endpoint: endpoint, forwarder: forwarder, role: role
                )
            case .tcp:
                return try DNSListenerBootstrap.bindTCP(
                    group: group, endpoint: endpoint, forwarder: forwarder, role: role
                )
            }
        }
    }

    /// Binds both transports. An initial bind failure is the caller's to handle.
    func start() throws {
        for transport in DNSListenerTransport.allCases {
            try bind(transport)
        }
    }

    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        return DNSListenerTransport.allCases.allSatisfy { channels[$0]?.isActive == true }
    }

    func ensureListening() -> Bool {
        var listening = true
        for transport in DNSListenerTransport.allCases {
            lock.lock()
            let isClosed = closed
            let current = channels[transport]
            lock.unlock()
            guard !isClosed else { return false }
            if let current {
                if current.isActive { continue }
                // Release the old descriptor before binding the same address.
                // Its close callback still reports the unexpected close.
                closeQuietly([current])
            }
            do {
                try bind(transport)
                lock.lock()
                lastRebindFailure[transport] = nil
                lock.unlock()
                ServiceLog.info("event=\(role.eventPrefix)_rebound protocol=\(transport.rawValue)")
            } catch {
                listening = false
                let fields = DNSListenerErrorClassifier.fields(for: error)
                lock.lock()
                let repeated = lastRebindFailure[transport] == fields
                lastRebindFailure[transport] = fields
                lock.unlock()
                if !repeated {
                    ServiceLog.error(
                        "event=\(role.eventPrefix)_rebind_failed protocol=\(transport.rawValue) \(fields)"
                    )
                }
            }
        }
        return listening
    }

    @discardableResult
    func rebuild() -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        let current = Array(channels.values)
        channels.removeAll()
        // A channel still in the map has not run its close callback yet, so
        // each mark below is consumed exactly once by that callback.
        for channel in current {
            intentionallyClosed.insert(ObjectIdentifier(channel))
        }
        lock.unlock()
        closeQuietly(current)
        return ensureListening()
    }

    func setUnexpectedCloseHandler(_ handler: (@Sendable (DNSListenerTransport) -> Void)?) {
        lock.lock()
        unexpectedCloseHandler = closed ? nil : handler
        lock.unlock()
    }

    /// Rebinds on `queue` after every unexpected close, retrying with
    /// `delays` until both transports are open again or the owner is closed.
    ///
    /// Only for an address that never goes away, such as the original-DNS
    /// escape on `127.0.0.1`. The bridge's alias can be absent, so the
    /// consistency observer decides when to rebind it instead. This replaces
    /// any unexpected-close handler. The owner of `queue` must drain it after
    /// `close()` and before shutting down the event loops.
    func enableAutomaticRebind(
        on queue: DispatchQueue,
        delays: [DispatchTimeInterval] = SupervisedDNSListeners.defaultRebindDelays
    ) {
        precondition(!delays.isEmpty)
        lock.lock()
        automaticRebindQueue = queue
        automaticRebindDelays = delays
        lock.unlock()
        setUnexpectedCloseHandler { [weak self] _ in
            self?.scheduleAutomaticRebind(attempt: 0)
        }
    }

    /// Closes both transports for good. A transport SwiftNIO already closed is
    /// not an error here: a resident transition must not fail on it.
    func close() {
        lock.lock()
        closed = true
        unexpectedCloseHandler = nil
        let current = Array(channels.values)
        channels.removeAll()
        lock.unlock()
        closeQuietly(current)
    }

    /// The open channel for one transport. Tests use it to inject socket faults.
    func channel(for transport: DNSListenerTransport) -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return channels[transport]
    }

    private func scheduleAutomaticRebind(attempt: Int) {
        lock.lock()
        // One pending attempt rebinds every closed transport, so a close that
        // arrives while one is pending needs no attempt of its own.
        guard !closed, !automaticRebindPending, let queue = automaticRebindQueue else {
            lock.unlock()
            return
        }
        automaticRebindPending = true
        let delay = automaticRebindDelays[min(attempt, automaticRebindDelays.count - 1)]
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Clear the mark first: a close during this attempt must schedule
            // another one rather than be absorbed by an attempt that already
            // checked its transport.
            self.lock.lock()
            self.automaticRebindPending = false
            self.lock.unlock()
            if !self.ensureListening() {
                self.scheduleAutomaticRebind(attempt: attempt + 1)
            }
        }
    }

    private func bind(_ transport: DNSListenerTransport) throws {
        let channel = try binder(transport)
        lock.lock()
        let isClosed = closed
        if !isClosed {
            channels[transport] = channel
        }
        lock.unlock()
        if isClosed {
            closeQuietly([channel])
            throw ChannelError.ioOnClosedChannel
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.channelClosed(channel, transport: transport)
        }
    }

    private func channelClosed(_ channel: Channel, transport: DNSListenerTransport) {
        lock.lock()
        let intentional = intentionallyClosed.remove(ObjectIdentifier(channel)) != nil || closed
        if channels[transport] === channel {
            channels[transport] = nil
        }
        let handler = intentional ? nil : unexpectedCloseHandler
        lock.unlock()
        guard !intentional else { return }
        ServiceLog.error("event=\(role.eventPrefix)_closed protocol=\(transport.rawValue)")
        handler?(transport)
    }

    private func closeQuietly(_ channels: [Channel]) {
        for channel in channels {
            // An already closed channel fails with `alreadyClosed`; either way
            // the descriptor is released once `closeFuture` completes.
            channel.close(promise: nil)
            try? channel.closeFuture.wait()
        }
    }
}

/// Binds the agent's DNS listeners: the Global DNS bridge and the original-DNS
/// escape share the same pipeline.
enum DNSListenerBootstrap {
    static func bindUDP(
        group: EventLoopGroup,
        endpoint: Endpoint,
        forwarder: AsyncDNSForwarding,
        role: DNSListenerRole
    ) throws -> Channel {
        try DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DNSUDPHandler(forwarder: forwarder, role: role)
                    )
                }
            }
            .bind(host: endpoint.host, port: endpoint.port)
            .wait()
    }

    static func bindTCP(
        group: EventLoopGroup,
        endpoint: Endpoint,
        forwarder: AsyncDNSForwarding,
        role: DNSListenerRole
    ) throws -> Channel {
        try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        ByteToMessageHandler(DNSTCPFrameDecoder()),
                        DNSTCPHandler(forwarder: forwarder, role: role)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .bind(host: endpoint.host, port: endpoint.port)
            .wait()
    }
}
