import Darwin
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

public final class ProxyService {
    private var configuration: ProxyConfiguration
    private let group: MultiThreadedEventLoopGroup
    private let networkState: NetworkDNSState
    private let aliasManager: LoopbackAliasManager
    private var globalDNS: GlobalDNSPreferences
    private let safetyState = NetworkSafetyState()
    private let healthGeneration: RuntimeHealthGeneration
    private let mihomoSupervisor: MihomoSupervisor?
    private let ownedTUN: DaemonOwnedTUN?
    private let stopLock = NSLock()
    private var stopped = false
    private var consistencyController: NetworkConsistencyController?
    private var powerObserver: SystemPowerObserver?
    private var routeTableMonitor: RouteTableMonitor?
    private var channels: [Channel] = []
    private var bridgeChannels: [Channel] = []
    private var systemDNSForwarder: AsyncDNSForwarding?
    private var preexistingFakeIPRouteInterface: String?

    public init(
        configuration: ProxyConfiguration,
        runtimeGeneration: String = UUID().uuidString,
        ownedTUN: DaemonOwnedTUN? = nil
    ) {
        self.configuration = configuration
        self.ownedTUN = ownedTUN
        self.healthGeneration = RuntimeHealthGeneration(runtimeGeneration)
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
            servers: configuration.managedSystemDNSServers,
            backupPath: configuration.systemDNSBackupPath,
            includeLegacyTUNDNS: configuration.usesGlobalDNSFallback
        )
        self.mihomoSupervisor = configuration.mihomoProcess.map { MihomoSupervisor(configuration: $0, ownedTUN: ownedTUN) }
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
                safetyState.isRuntimeReady() || DNSMessage.isRuntimeHealthQuery(query)
            },
            fallbackAllowed: { [fakeIPPolicy] query in
                fakeIPPolicy.allowsOriginalDNSFallback(for: query)
            }
        )

        self.systemDNSForwarder = systemDNSForwarder
        do {
            // The port-53 bridge exists while macOS Global DNS points at it
            // (Enhanced TUN). Standby leaves the system resolver alone.
            if configuration.servesSystemDNSBridge {
                bridgeChannels.append(try startUDP(endpoint: configuration.systemDNSListen, forwarder: systemDNSForwarder))
                bridgeChannels.append(try startTCP(endpoint: configuration.systemDNSListen, forwarder: systemDNSForwarder))
            }
            channels.append(try startUDP(endpoint: configuration.upstreamListen, forwarder: originalDNSForwarder))
            channels.append(try startTCP(endpoint: configuration.upstreamListen, forwarder: originalDNSForwarder))
            // Capture a route owned by another TUN before starting Mihomo. A
            // later controller-ready state is not sufficient ownership proof
            // if the Fake-IP route never moved away from that interface.
            preexistingFakeIPRouteInterface = MihomoRuntimeInspector.fakeIPRouteInterface()
            try mihomoSupervisor?.start()
            startConsistencyObservation()
            // SCDynamicStore reports effective resolver/interface state,
            // while PF_ROUTE reports route/address/interface mutations at
            // the kernel boundary. Keep an independent routing socket so
            // lookup replies cannot race the broadcast consumer.
            let routeMonitor = RouteTableMonitor { [weak networkState] event in
                guard !event.isEmpty else { return }
                networkState?.handleRouteTableChange()
            }
            routeTableMonitor = routeMonitor
            do {
                try routeMonitor.start()
            } catch let RouteTableMonitorError.openFailed(code) {
                ServiceLog.error("event=route_monitor_unavailable code=\(code)")
            } catch {
                ServiceLog.error("event=route_monitor_unavailable code=unknown")
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

    private func startConsistencyObservation() {
        // Standby publishes health too: the daemon validates every runtime
        // from these snapshots, including one that leaves system DNS alone.
        // A plain forwarder has no runtime for the daemon to validate.
        if !configuration.isPlainForwarder {
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
                },
                preexistingFakeIPRouteInterface: preexistingFakeIPRouteInterface,
                healthGeneration: healthGeneration,
                ownedTUN: ownedTUN
            )
            consistencyController = controller
            controller.start()

            // Resolver and route changes also matter in standby: the
            // original-DNS escape still follows the physical network even
            // though MihomoBox does not write the system resolver itself.
            networkState.setRefreshHandler { [weak controller] signal in
                controller?.handleNetworkChange(reason: signal)
            }

            // A root LaunchDaemon gets no NSWorkspace wake notification, so
            // this is IOKit-based. Wake is when TUN, the default route and
            // the outbound interface binding are most likely to have moved
            // underneath a runtime that still looks healthy locally.
            let observer = SystemPowerObserver(
                onSleep: { [weak controller] in controller?.handleSystemSleep() },
                onWake: { [weak controller] in controller?.handleSystemWake() }
            )
            observer.start()
            powerObserver = observer
        }
    }

    /// Replaces DNS/TUN policy in the existing child, retaining the original-DNS
    /// escape, process supervisor, mixed proxy port and App Proxy extension.
    public func reconfigureResidentMihomo(configuration next: ProxyConfiguration, generation: String) throws {
        stopLock.lock()
        defer { stopLock.unlock() }
        let clock = MonotonicStartupClock()
        guard !stopped, UUID(uuidString: generation) != nil,
              configuration.permitsResidentTransition(to: next),
              let systemDNSForwarder else {
            throw NSError(domain: "MihomoResidentRuntime", code: 3)
        }
        try next.validate()
        // Quiesce the old observer before restoring its DNS. It must never
        // reacquire Global DNS while the new configuration disables TUN.
        networkState.setRefreshHandler(nil)
        powerObserver?.stop()
        powerObserver = nil
        consistencyController?.stopAndRestore()
        consistencyController = nil
        ServiceLog.info("event=resident_runtime_transition phase=quiesced elapsed_ms=\(clock.elapsedMilliseconds())")
        try ownedTUN?.suspend()
        ServiceLog.info("event=resident_runtime_transition phase=routes_withdrawn elapsed_ms=\(clock.elapsedMilliseconds())")
        guard try Self.isSystemDNSRestored(configuration: configuration) else {
            throw NSError(domain: "MihomoResidentRuntime", code: 4)
        }
        if !configuration.expectsEnhancedTUN {
            preexistingFakeIPRouteInterface = MihomoRuntimeInspector.fakeIPRouteInterface()
        }
        healthGeneration.replace(with: generation)
        HealthSnapshotStore.remove(at: configuration.healthSnapshotPath)
        safetyState.setRuntimeReady(false)
        // Close only the Global DNS bridge. Port 1054 never leaves the process.
        for channel in bridgeChannels { try channel.close().wait() }
        bridgeChannels.removeAll()
        configuration = next
        globalDNS = GlobalDNSPreferences(
            servers: next.managedSystemDNSServers,
            backupPath: next.systemDNSBackupPath,
            includeLegacyTUNDNS: next.usesGlobalDNSFallback
        )
        if next.manageSystemDNS { try aliasManager.ensure() }
        if next.servesSystemDNSBridge {
            bridgeChannels.append(try startUDP(endpoint: next.systemDNSListen, forwarder: systemDNSForwarder))
            bridgeChannels.append(try startTCP(endpoint: next.systemDNSListen, forwarder: systemDNSForwarder))
        }
        try MihomoRuntimeInspector.reloadResidentMihomo(configuration: next)
        ServiceLog.info("event=resident_runtime_transition phase=applied elapsed_ms=\(clock.elapsedMilliseconds())")
        MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: next)
        ServiceLog.info("event=resident_runtime_transition phase=core_cache_flushed elapsed_ms=\(clock.elapsedMilliseconds())")
        DNSCacheMaintenance.flushSystemCaches()
        ServiceLog.info("event=resident_runtime_transition phase=system_cache_flushed elapsed_ms=\(clock.elapsedMilliseconds())")
        startConsistencyObservation()
        ServiceLog.info("event=resident_runtime_transition phase=observed elapsed_ms=\(clock.elapsedMilliseconds())")
    }

    public static func restoreSystemDNS(configuration: ProxyConfiguration) throws {
        MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: configuration)
        let preferences = GlobalDNSPreferences(
            servers: configuration.managedSystemDNSServers,
            backupPath: configuration.systemDNSBackupPath,
            includeLegacyTUNDNS: configuration.usesGlobalDNSFallback
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
            servers: configuration.managedSystemDNSServers,
            backupPath: configuration.systemDNSBackupPath,
            includeLegacyTUNDNS: configuration.usesGlobalDNSFallback
        )
        return try preferences.isApplied()
    }

    public static func isSystemDNSRestored(configuration: ProxyConfiguration) throws -> Bool {
        let preferences = GlobalDNSPreferences(
            servers: configuration.managedSystemDNSServers,
            backupPath: configuration.systemDNSBackupPath,
            includeLegacyTUNDNS: configuration.usesGlobalDNSFallback
        )
        let persistentlyPresent = try preferences.containsManagedServerPersistently()
        let dynamicallyPresent = try preferences.containsManagedServerEffectively()
        return !persistentlyPresent && !dynamicallyPresent
    }

    public static func networkHealth(configuration: ProxyConfiguration) -> NetworkConsistencyHealth {
        MihomoRuntimeInspector.inspect(configuration: configuration)
    }

    public func wait() throws {
        guard let first = channels.first else { return }
        try first.closeFuture.wait()
    }

    /// Applies a profile reload without replacing the agent or either DNS
    /// listener. The consistency observer owns publication of the requested
    /// generation; until it sees the new child healthy, managed forwarding is
    /// held in its safe fallback state.
    public func reloadMihomo(generation: String) throws {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped, UUID(uuidString: generation) != nil, let mihomoSupervisor else {
            throw NSError(
                domain: "MihomoAgent",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "managed Mihomo reload is unavailable"]
            )
        }
        ServiceLog.info("event=runtime_reload phase=started generation=changed")
        if let consistencyController {
            consistencyController.beginRuntimeReload(generation: generation)
        } else {
            safetyState.setRuntimeReady(false)
            healthGeneration.replace(with: generation)
            HealthSnapshotStore.remove(at: configuration.healthSnapshotPath)
        }
        do {
            try mihomoSupervisor.restartForProfileReload()
            consistencyController?.finishRuntimeReload()
            ServiceLog.info("event=runtime_reload phase=child_started generation=changed")
        } catch {
            ServiceLog.error("event=runtime_reload result=failed reason=child_restart")
            throw error
        }
    }

    public func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        defer { stopLock.unlock() }
        ServiceLog.info("event=service_stop_started")

        safetyState.setRuntimeReady(false)
        MihomoRuntimeInspector.flushMihomoDNSCaches(configuration: configuration)
        // Drop the notification sources before tearing the controller down so a
        // late callback cannot resurrect evaluation during shutdown.
        networkState.setRefreshHandler(nil)
        routeTableMonitor?.stop()
        routeTableMonitor = nil
        powerObserver?.stop()
        powerObserver = nil
        consistencyController?.stopAndRestore()
        consistencyController = nil
        if configuration.manageSystemDNS {
            try? globalDNS.restore()
            try? aliasManager.removeIfManaged()
        }
        DNSCacheMaintenance.flushSystemCaches()
        let active = channels + bridgeChannels
        channels.removeAll()
        bridgeChannels.removeAll()
        for channel in active {
            try? channel.close().wait()
        }
        networkState.stop()
        mihomoSupervisor?.stop()
        do { try ownedTUN?.deactivate() }
        catch { ServiceLog.error("event=owned_tun_cleanup result=failed") }
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
