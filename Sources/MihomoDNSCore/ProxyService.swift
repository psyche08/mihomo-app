import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

public final class ProxyService {
    private let configuration: ProxyConfiguration
    private let group: MultiThreadedEventLoopGroup
    private let threadPool: NIOThreadPool
    private let networkState: NetworkDNSState
    private let aliasManager: LoopbackAliasManager
    private let globalDNS: GlobalDNSPreferences
    private let safetyState = NetworkSafetyState()
    private let mihomoSupervisor: MihomoSupervisor?
    private let stopLock = NSLock()
    private var stopped = false
    private var consistencyController: NetworkConsistencyController?
    private var channels: [Channel] = []

    public init(configuration: ProxyConfiguration) {
        self.configuration = configuration
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount / 2))
        self.threadPool = NIOThreadPool(numberOfThreads: max(2, min(8, System.coreCount)))
        self.networkState = NetworkDNSState(
            excludedServers: [
                configuration.systemDNSListen.host,
                configuration.mihomoDNS.host,
                configuration.upstreamListen.host,
            ],
            fallbackServers: configuration.fallbackDNSServers
        )
        self.aliasManager = LoopbackAliasManager(
            interfaceName: configuration.loopbackInterface,
            address: configuration.loopbackAlias,
            netmask: configuration.loopbackNetmask,
            markerPath: configuration.aliasMarkerPath
        )
        self.globalDNS = GlobalDNSPreferences(
            servers: [configuration.systemDNSListen.host],
            backupPath: configuration.systemDNSBackupPath
        )
        self.mihomoSupervisor = configuration.mihomoProcess.map(MihomoSupervisor.init)
    }

    public func start() throws {
        try configuration.validate()
        safetyState.setRuntimeReady(!configuration.manageSystemDNS)
        if configuration.manageSystemDNS {
            try globalDNS.restore()
            try aliasManager.removeIfManaged()
            try aliasManager.ensure()
        }
        try networkState.start()
        threadPool.start()

        let mihomoForwarder = FixedDNSForwarder(
            endpoint: configuration.mihomoDNS,
            timeoutMilliseconds: configuration.queryTimeoutMilliseconds
        )
        let originalDNSForwarder = DynamicDNSForwarder(
            state: networkState,
            timeoutMilliseconds: configuration.queryTimeoutMilliseconds
        )
        let systemDNSForwarder = FallbackDNSForwarder(
            primary: mihomoForwarder,
            fallback: originalDNSForwarder,
            primaryAllowed: { [safetyState] in safetyState.isRuntimeReady() }
        )

        do {
            channels.append(try startUDP(endpoint: configuration.systemDNSListen, forwarder: systemDNSForwarder))
            channels.append(try startTCP(endpoint: configuration.systemDNSListen, forwarder: systemDNSForwarder))
            channels.append(try startUDP(endpoint: configuration.upstreamListen, forwarder: originalDNSForwarder))
            channels.append(try startTCP(endpoint: configuration.upstreamListen, forwarder: originalDNSForwarder))
            try mihomoSupervisor?.start()
            if configuration.manageSystemDNS {
                let controller = NetworkConsistencyController(
                    configuration: configuration,
                    globalDNS: globalDNS,
                    aliasManager: aliasManager,
                    safetyState: safetyState,
                    unsafeRuntimeHandler: { [mihomoSupervisor] in
                        mihomoSupervisor?.stop()
                    }
                )
                consistencyController = controller
                controller.start()
            }
        } catch {
            stop()
            throw error
        }

        let snapshot = networkState.snapshot()
        ServiceLog.info(
            "event=service_started system_dns=\(configuration.systemDNSListen.host):\(configuration.systemDNSListen.port) " +
            "mihomo=\(configuration.mihomoDNS.host):\(configuration.mihomoDNS.port) " +
            "upstream_listener=\(configuration.upstreamListen.host):\(configuration.upstreamListen.port) " +
            "original_dns_count=\(snapshot.servers.count)"
        )
    }

    public static func restoreSystemDNS(configuration: ProxyConfiguration) throws {
        MihomoRuntimeInspector.flushMihomoDNSCaches()
        let preferences = GlobalDNSPreferences(
            servers: [configuration.systemDNSListen.host],
            backupPath: configuration.systemDNSBackupPath
        )
        try preferences.restore()
        let alias = LoopbackAliasManager(
            interfaceName: configuration.loopbackInterface,
            address: configuration.loopbackAlias,
            netmask: configuration.loopbackNetmask,
            markerPath: configuration.aliasMarkerPath
        )
        try alias.removeIfManaged()
        DNSCacheMaintenance.flushSystemCaches()
    }

    public static func isSystemDNSApplied(configuration: ProxyConfiguration) throws -> Bool {
        let preferences = GlobalDNSPreferences(
            servers: [configuration.systemDNSListen.host],
            backupPath: configuration.systemDNSBackupPath
        )
        return try preferences.isApplied()
    }

    public static func networkHealth(configuration: ProxyConfiguration) -> NetworkConsistencyHealth {
        MihomoRuntimeInspector.inspect(configuration: configuration)
    }

    public func wait() throws {
        guard let first = channels.first else { return }
        try first.closeFuture.wait()
    }

    public func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()

        safetyState.setRuntimeReady(false)
        MihomoRuntimeInspector.flushMihomoDNSCaches()
        consistencyController?.stopAndRestore()
        consistencyController = nil
        if configuration.manageSystemDNS {
            try? globalDNS.restore()
            try? aliasManager.removeIfManaged()
        }
        DNSCacheMaintenance.flushSystemCaches()
        let active = channels
        channels.removeAll()
        for channel in active {
            try? channel.close().wait()
        }
        networkState.stop()
        mihomoSupervisor?.stop()
        try? threadPool.syncShutdownGracefully()
        try? group.syncShutdownGracefully()
    }

    private func startUDP(endpoint: Endpoint, forwarder: DNSForwarding) throws -> Channel {
        let threadPool = self.threadPool
        return try DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DNSUDPHandler(forwarder: forwarder, threadPool: threadPool)
                    )
                }
            }
            .bind(host: endpoint.host, port: endpoint.port)
            .wait()
    }

    private func startTCP(endpoint: Endpoint, forwarder: DNSForwarding) throws -> Channel {
        let threadPool = self.threadPool
        return try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(
                        ByteToMessageHandler(DNSTCPFrameDecoder()),
                        DNSTCPHandler(forwarder: forwarder, threadPool: threadPool)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .bind(host: endpoint.host, port: endpoint.port)
            .wait()
    }
}
