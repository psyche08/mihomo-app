import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// One transport of the Global DNS bridge.
enum DNSBridgeTransport: String, CaseIterable, Sendable {
    case udp
    case tcp
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
    func setUnexpectedCloseHandler(_ handler: (@Sendable (DNSBridgeTransport) -> Void)?)
}

/// Owns the UDP and TCP listeners of the `127.0.0.53:53` Global DNS bridge.
///
/// SwiftNIO closes a datagram channel after any send error other than EMSGSIZE
/// or EHOSTUNREACH, and it does so without calling `errorCaught`. The kernel
/// keeps an idle socket bound to the loopback alias while the alias is removed
/// and delivers to it again once the alias returns, but a reply sent from the
/// alias while it is absent fails with EADDRNOTAVAIL. A rollback that removed
/// the alias under an in-flight query therefore silently closed the UDP
/// listener, the TCP listener survived, and nothing rebound UDP until the agent
/// restarted. This owner reports an unexpected close and rebinds on demand, so
/// the bridge serves both transports whenever system DNS may point at it.
final class DNSBridgeListeners: DNSBridgeListenerControl, @unchecked Sendable {
    typealias Binder = (DNSBridgeTransport) throws -> Channel

    private let binder: Binder
    private let lock = NSLock()
    private var channels: [DNSBridgeTransport: Channel] = [:]
    /// Channels this owner closes itself; their close is not reported.
    private var intentionallyClosed = Set<ObjectIdentifier>()
    private var unexpectedCloseHandler: (@Sendable (DNSBridgeTransport) -> Void)?
    /// Last rebind failure per transport, so a persistent failure is logged
    /// once instead of on every observer tick.
    private var lastRebindFailure: [DNSBridgeTransport: String] = [:]
    private var closed = false

    init(binder: @escaping Binder) {
        self.binder = binder
    }

    convenience init(group: EventLoopGroup, endpoint: Endpoint, forwarder: AsyncDNSForwarding) {
        self.init { transport in
            switch transport {
            case .udp:
                return try DNSListenerBootstrap.bindUDP(group: group, endpoint: endpoint, forwarder: forwarder)
            case .tcp:
                return try DNSListenerBootstrap.bindTCP(group: group, endpoint: endpoint, forwarder: forwarder)
            }
        }
    }

    /// Binds both transports. An initial bind failure is the caller's to handle.
    func start() throws {
        for transport in DNSBridgeTransport.allCases {
            try bind(transport)
        }
    }

    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        return DNSBridgeTransport.allCases.allSatisfy { channels[$0]?.isActive == true }
    }

    func ensureListening() -> Bool {
        var listening = true
        for transport in DNSBridgeTransport.allCases {
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
                ServiceLog.info("event=dns_bridge_listener_rebound protocol=\(transport.rawValue)")
            } catch {
                listening = false
                let fields = DNSListenerErrorClassifier.fields(for: error)
                lock.lock()
                let repeated = lastRebindFailure[transport] == fields
                lastRebindFailure[transport] = fields
                lock.unlock()
                if !repeated {
                    ServiceLog.error(
                        "event=dns_bridge_listener_rebind_failed protocol=\(transport.rawValue) \(fields)"
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

    func setUnexpectedCloseHandler(_ handler: (@Sendable (DNSBridgeTransport) -> Void)?) {
        lock.lock()
        unexpectedCloseHandler = closed ? nil : handler
        lock.unlock()
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
    func channel(for transport: DNSBridgeTransport) -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return channels[transport]
    }

    private func bind(_ transport: DNSBridgeTransport) throws {
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

    private func channelClosed(_ channel: Channel, transport: DNSBridgeTransport) {
        lock.lock()
        let intentional = intentionallyClosed.remove(ObjectIdentifier(channel)) != nil || closed
        if channels[transport] === channel {
            channels[transport] = nil
        }
        let handler = intentional ? nil : unexpectedCloseHandler
        lock.unlock()
        guard !intentional else { return }
        ServiceLog.error("event=dns_bridge_listener_closed protocol=\(transport.rawValue)")
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
    static func bindUDP(group: EventLoopGroup, endpoint: Endpoint, forwarder: AsyncDNSForwarding) throws -> Channel {
        try DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DNSUDPHandler(forwarder: forwarder)
                    )
                }
            }
            .bind(host: endpoint.host, port: endpoint.port)
            .wait()
    }

    static func bindTCP(group: EventLoopGroup, endpoint: Endpoint, forwarder: AsyncDNSForwarding) throws -> Channel {
        try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        ByteToMessageHandler(DNSTCPFrameDecoder()),
                        DNSTCPHandler(forwarder: forwarder)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .bind(host: endpoint.host, port: endpoint.port)
            .wait()
    }
}
