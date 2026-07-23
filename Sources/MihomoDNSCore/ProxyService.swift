import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

public final class ProxyService {
    private let configuration: ProxyConfiguration
    private let group: MultiThreadedEventLoopGroup
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
        ServiceLog.info("event=service_starting")
        try configuration.validate()
        safetyState.setRuntimeReady(!configuration.manageSystemDNS)
        if configuration.manageSystemDNS {
            try globalDNS.restore()
            try aliasManager.removeIfManaged()
            try aliasManager.ensure()
        }
        try networkState.start()

        let mihomoForwarder = FixedAsyncDNSForwarder(
            endpoint: configuration.mihomoDNS,
            timeoutMilliseconds: configuration.queryTimeoutMilliseconds
        )
        let originalDNSForwarder = DynamicAsyncDNSForwarder(
            state: networkState,
            timeoutMilliseconds: configuration.queryTimeoutMilliseconds
        )
        let fakeIPPolicy = FakeIPDNSPolicy(configPath: configuration.mihomoProcess?.configPath)
        let systemDNSForwarder = FallbackAsyncDNSForwarder(
            primary: mihomoForwarder,
            fallback: originalDNSForwarder,
            primaryAllowed: { [safetyState] query in
                safetyState.isRuntimeReady() || query == DNSMessage.runtimeHealthQuery
            },
            fallbackAllowed: { [fakeIPPolicy] query in
                fakeIPPolicy.allowsOriginalDNSFallback(for: query)
            }
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
                    runtimeRecoveryHandler: { [mihomoSupervisor] in
                        mihomoSupervisor?.requestRecovery()
                    },
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
            "event=service_started original_dns_count=\(snapshot.servers.count)"
        )
    }

    public static func restoreSystemDNS(configuration: ProxyConfiguration) throws {
        MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: configuration)
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
        ServiceLog.info("event=service_stop_started")

        safetyState.setRuntimeReady(false)
        MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: configuration)
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
        try? group.syncShutdownGracefully()
        ServiceLog.info("event=service_stopped")
    }

    private func startUDP(endpoint: Endpoint, forwarder: AsyncDNSForwarding) throws -> Channel {
        return try DatagramBootstrap(group: group)
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

    private func startTCP(endpoint: Endpoint, forwarder: AsyncDNSForwarding) throws -> Channel {
        return try ServerBootstrap(group: group)
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
