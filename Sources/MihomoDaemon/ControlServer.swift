import Darwin
import Foundation
import MihomoControl
import Security
import MihomoDNSCore
import XPC

final class ControlDispatcher: @unchecked Sendable {
    /// Lets the server release a dead peer's streams.
    var controllerBroker: ControllerBroker { controller }

    private let agent: AgentSupervisor
    private let controller: ControllerBroker
    private let systemProxy: SystemProxyController
    private let configurationPath: String
    private let profiles: ProfileBroker
    private let components: ComponentUpdater
    private let startupClock: MonotonicStartupClock
    private let mutationLock = NSLock()
    private let legacyLocalDoH = LegacyLocalDoHCleanup()
    private let dnsResolver: AppProxyDNSResolver
    private var systemProxyTimer: DispatchSourceTimer?

    init(
        agent: AgentSupervisor,
        configPath: String,
        startupClock: MonotonicStartupClock = MonotonicStartupClock()
    ) throws {
        self.agent = agent
        configurationPath = configPath
        systemProxy = SystemProxyController(configPath: configPath)
        self.startupClock = startupClock
        let controllerBroker = ControllerBroker(configPath: configPath)
        let validateStartedRuntime = {
            try Self.validateStartedRuntime(agent: agent, controller: controllerBroker)
        }
        let validateUpdatedRuntime = {
            try Self.validateStartedRuntime(agent: agent, controller: controllerBroker,
                                            timeout: Self.updatedComponentsStartTimeout)
        }
        controller = controllerBroker
        profiles = ProfileBroker(
            agent: agent,
            validateStartedRuntime: validateStartedRuntime
        )
        components = try ComponentUpdater(
            agent: agent,
            validateStartedRuntime: validateUpdatedRuntime
        )
        dnsResolver = AppProxyDNSResolver(
            endpoint: AppProxyDNSResolver.coreEndpoint(configurationPath: configPath)
        )
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.linsheng.mihomo.system-proxy-reconcile")
        )
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.reconcileSystemProxy() }
        systemProxyTimer = timer
        timer.resume()
    }

    deinit { systemProxyTimer?.cancel() }

    /// App Proxy DNS for policy-matched applications. Runs outside the
    /// lifecycle lock; the resolver bounds outstanding work.
    func resolveAppProxyDNS(
        _ query: Data,
        completion: @escaping @Sendable (Result<Data, AppProxyDNSResolver.Failure>) -> Void
    ) {
        dnsResolver.resolve(query, completion: completion)
    }

    /// Boot keeps the Mach service available even when the managed runtime
    /// cannot prove a safe route. This lets the signed App repair a profile or
    /// retry start without launchd crash-looping the root daemon.
    func startInitialRuntime() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        if components.recoveryRequired {
            try? systemProxy.setEnabled(false)
            let restored = agent.stopAndRestoreVerified()
            ServiceLog.error(
                "event=initial_runtime result=" +
                (restored ? "component_recovery_required" : "restore_unconfirmed")
            )
            logInitialRuntimeStartup(
                result: restored ? "component_recovery_required" : "restore_unconfirmed"
            )
            return
        }
        if components.requiresDaemonRestart {
            ServiceLog.info("event=component_update result=restart_after_interrupted_recovery")
            logInitialRuntimeStartup(result: "daemon_restart_required")
            scheduleDaemonRestart()
            return
        }
        // Restore with the persisted DNS owner before daemon.json is migrated.
        guard agent.stopAndRestoreVerified() else {
            ServiceLog.error("event=initial_runtime result=dns_restore_unconfirmed")
            logInitialRuntimeStartup(result: "dns_restore_unconfirmed")
            return
        }
        // The retired LocalHttpDns split-DNS profile would keep sending its
        // domains to a listener that no longer exists, in either TUN state.
        legacyLocalDoH.run()
        do {
            try profiles.migrateLegacyDNSConfiguration()
        } catch {
            ServiceLog.error("event=initial_runtime result=dns_configuration_migration_failed")
            logInitialRuntimeStartup(result: "dns_configuration_migration_failed")
            return
        }
        if profiles.activationRequired {
            do {
                try components.commitPendingBootValidation()
                ServiceLog.info("event=initial_runtime result=awaiting_profile")
                logInitialRuntimeStartup(result: "awaiting_profile")
            } catch {
                let rolledBack = components.rollbackPendingBootValidation()
                ServiceLog.error(
                    "event=initial_runtime result=" +
                    (rolledBack ? "component_rolled_back" : "component_recovery_required")
                )
                logInitialRuntimeStartup(
                    result: rolledBack ? "component_rolled_back" : "component_recovery_required"
                )
                if rolledBack { scheduleDaemonRestart() }
            }
            return
        }
        do {
            try ensureRuntimePrerequisiteLocked()
            try agent.start()
            try ensureStartedRuntimeLocked(timeout: components.hasPendingBootValidation
                ? Self.updatedComponentsStartTimeout : 20)
            try resumeEnhancedRuntimeLocked()
            try components.commitPendingBootValidation()
            do { try refreshSystemProxy(restoreSavedChoice: true) } catch { ServiceLog.error("event=system_proxy_restore result=failed") }
            ServiceLog.info("event=initial_runtime result=ready")
            logInitialRuntimeStartup(result: "ready")
        } catch {
            let restored = agent.stopAndRestoreVerified()
            let hadPendingUpdate = components.hasPendingBootValidation
            let componentRollback = components.rollbackPendingBootValidation()
            ServiceLog.error(
                "event=initial_runtime result=" +
                (restored && componentRollback ? "stopped" : "restore_unconfirmed")
            )
            logInitialRuntimeStartup(
                result: restored && componentRollback ? "stopped" : "restore_unconfirmed"
            )
            if hadPendingUpdate, componentRollback {
                scheduleDaemonRestart()
            }
        }
    }

    private func logInitialRuntimeStartup(result: String) {
        ServiceLog.info(
            "event=daemon_startup phase=initial_runtime_complete result=\(result) " +
            "elapsed_ms=\(startupClock.elapsedMilliseconds())"
        )
    }

    func dispatch(_ request: ControlRequest, owner: ObjectIdentifier? = nil) -> ControlResponse {
        let mutating = Self.isMutating(request.operation)
        if mutating {
            mutationLock.lock()
        }
        defer {
            if mutating { mutationLock.unlock() }
        }
        let operation = request.operation.rawValue
        let auditRoutineLifecycle = ControlRequestAuditPolicy.logsRoutineLifecycle(
            for: request.operation
        )
        if auditRoutineLifecycle {
            ServiceLog.info("event=control_request operation=\(operation) phase=started")
        }
        guard request.version == mihomoControlProtocolVersion else {
            ServiceLog.error("event=control_request operation=\(operation) result=unsupported_version")
            return ControlResponse(success: false, error: "unsupported control protocol version")
        }

        if (components.recoveryRequired || components.requiresDaemonRestart),
           mutating, request.operation != .stopAgent {
            let result = components.recoveryRequired ? "recovery_required" : "restart_required"
            ServiceLog.error("event=control_request operation=\(operation) result=\(result)")
            return ControlResponse(
                success: false,
                error: components.recoveryRequired
                    ? "component recovery is required before runtime mutations"
                    : "a daemon restart is required before runtime mutations"
            )
        }

        var externalMutationFileLock: ComponentMutationFileLock?
        if mutating, request.operation != .upgradeComponents {
            // BSD flock is process-scoped on macOS. Never open a second lock
            // object while this daemon retains the pending-update lock: an
            // unlock through either descriptor would release the long-lived
            // transaction boundary.
            if components.ownsPendingMutationFileLock {
                ServiceLog.error("event=control_request operation=\(operation) result=mutation_busy")
                return ControlResponse(
                    success: false,
                    error: "a component update is awaiting daemon validation"
                )
            }
            do {
                externalMutationFileLock = try ComponentMutationFileLock()
            } catch ComponentMutationLockError.busy {
                ServiceLog.error("event=control_request operation=\(operation) result=mutation_busy")
                return ControlResponse(
                    success: false,
                    error: "another privileged MihomoBox mutation is running"
                )
            } catch {
                ServiceLog.error("event=control_request operation=\(operation) result=lock_rejected")
                return ControlResponse(
                    success: false,
                    error: (error as? LocalizedError)?.errorDescription
                        ?? "privileged mutation lock is unavailable"
                )
            }
        }
        defer { withExtendedLifetime(externalMutationFileLock) {} }
        do {
            let payload: Data?
            switch request.operation {
            case .ping:
                payload = try JSONSerialization.data(withJSONObject: [
                    "protocol_version": mihomoControlProtocolVersion,
                    "agent_running": agent.isRunning,
                ], options: [.sortedKeys])
            case .status:
                var status = (try? JSONSerialization.jsonObject(
                    with: agent.diagnosticHealth()
                )) as? [String: Any] ?? [:]
                status["agent_running"] = agent.isRunning
                status["global_dns_fallback"] = agent.globalDNSFallbackConfigured
                status["legacy_local_doh_profile_removed"] = legacyLocalDoH.profileRemoved
                payload = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
            case .trayState:
                let agentRunning = agent.isRunning
                let snapshotData = agentRunning
                    ? try? controller.perform(ControlRequest(operation: .snapshot))
                    : nil
                let snapshot = snapshotData.flatMap {
                    try? JSONSerialization.jsonObject(with: $0)
                }
                let profileState = try JSONSerialization.jsonObject(with: profiles.list())
                let health = (try? agent.passiveHealth())
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                payload = try JSONSerialization.data(withJSONObject: [
                    "agent_running": agentRunning,
                    "system_proxy_enabled": (try? systemProxy.enabled()) as Any? ?? NSNull(),
                    "system_proxy_requested": agent.requestsSystemProxy,
                    "enhanced_tun_requested": agent.resumesEnhancedTUN,
                    "snapshot": snapshot ?? NSNull(),
                    "profiles": profileState,
                    "health": health ?? NSNull(),
                ], options: [.sortedKeys])
            case .startAgent:
                guard !profiles.activationRequired else {
                    throw serverError("activate a profile before starting the managed runtime")
                }
                try ensureRuntimePrerequisiteLocked()
                try agent.start()
                try ensureStartedRuntimeLocked()
                try resumeEnhancedRuntimeLocked()
                payload = nil
            case .setSystemProxy:
                guard request.arguments.count == 1, request.payload == nil,
                      let raw = request.arguments["enabled"], let enabled = ["true":true,"false":false][raw] else { throw serverError("System proxy enabled state is required") }
                try RuntimeSwitchPreferences.setSystemProxy(enabled, configurationPath: configurationPath)
                var port = 7897
                if enabled {
                    guard agent.isRunning else { throw serverError("Start the managed proxy before enabling system proxy") }
                    let data = try controller.perform(ControlRequest(operation:.snapshot))
                    guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                          let config = object["configs"] as? [String:Any], let mixed = config["mixed-port"] as? Int else { throw serverError("Start the managed proxy before enabling system proxy") }
                    port = mixed
                }
                try systemProxy.setEnabled(enabled, port:port)
                guard try systemProxy.enabled() == enabled else { throw serverError("System proxy readback did not match") }
                payload = nil
            case .stopAgent:
                try systemProxy.setEnabled(false)
                guard agent.stopAndRestoreVerified() else {
                    throw serverError("the network restore could not be confirmed")
                }
                payload = nil
            case .restartAgent:
                guard !profiles.activationRequired else {
                    throw serverError("activate a profile before starting the managed runtime")
                }
                try ensureRuntimePrerequisiteLocked()
                try agent.restart()
                try ensureStartedRuntimeLocked()
                payload = nil
            case .componentStatus:
                payload = try components.status()
            case .upgradeComponents:
                guard let package = request.payload else {
                    throw serverError("component update package is required")
                }
                let result = try components.perform(package)
                payload = try JSONSerialization.data(withJSONObject: [
                    "updated": result.updated,
                    "daemon_restart": result.restartDaemon,
                ], options: [.sortedKeys])
                if result.restartDaemon {
                    scheduleDaemonRestart()
                }
            case .appProxyStatus:
                payload = try profiles.appProxyStatus()
            case .setAppProxyRouting:
                guard let data = request.payload, data.count <= 16_384 else { throw serverError("invalid App Proxy update") }
                let update = try JSONDecoder().decode(AppProxyRoutingUpdate.self, from: data)
                if agent.isRunning { try controller.validateAppProxyRoutes(update.settings) }
                payload = try profiles.setAppProxyRouting(update)
            case .setAppProxyProcesses:
                guard let data = request.payload, data.count <= 262_144 else {
                    throw serverError("invalid App Proxy process routes")
                }
                let changed = try profiles.setAppProxyProcesses(try JSONDecoder().decode(AppProxyProcessRoutes.self, from: data))
                // Files are read at start; a running core reloads only the providers that changed.
                // A configuration rendered before this overlay has no such provider until the
                // profile is next applied, so a failed refresh is logged rather than fatal.
                if agent.isRunning {
                    for name in changed {
                        do { try controller.refreshRuleProvider(name) } catch {
                            ServiceLog.error("event=app_proxy_process_provider result=refresh_failed")
                        }
                    }
                }
                payload = nil
            case .listProfiles:
                payload = try profiles.list()
            case .importProfile, .switchProfile, .reloadProfile:
                payload = try profiles.perform(request)
            case .controllerStreamClose:
                // Deliberately outside the agent check below. Closing only drops
                // a table entry and cancels a socket — it needs no agent, and
                // gating it meant the one deterministic cleanup path failed
                // exactly when the agent stopped and every stream was dying.
                payload = try controller.perform(request, owner: owner)
            case .setTUN:
                guard request.arguments.count == 1, request.payload == nil,
                      let raw = request.arguments["enabled"],
                      let enabled = ["true": true, "false": false][raw] else {
                    throw serverError("Enhanced TUN enabled state is required")
                }
                try RuntimeSwitchPreferences.setTUN(enabled, configurationPath: configurationPath)
                guard !profiles.activationRequired else {
                    throw serverError("activate a profile before enabling Enhanced TUN")
                }
                guard agent.isRunning else {
                    throw serverError("Mihomo agent is not running")
                }
                if enabled, !legacyLocalDoH.profileRemoved {
                    // Boot could not prove the retired split-DNS profile gone.
                    legacyLocalDoH.run()
                }
                // Enabled is Global DNS + TUN; disabled is standby, where App
                // Proxy keeps the daemon-owned core and its DNS listener.
                try profiles.setEnhancedTUN(enabled)
                payload = nil
            case .snapshot, .setOutboundMode, .selectProxy,
                 .refreshProxyProvider, .testDelay,
                 .controllerVersion, .listRules, .listProxyProviders, .listRuleProviders,
                 .listConnections, .closeAllConnections, .controllerRequest,
                 .controllerStreamMessage, .controllerStreamOpen, .controllerStreamNext:
                guard agent.isRunning else {
                    throw serverError("Mihomo agent is not running")
                }
                payload = try controller.perform(request, owner: owner)
            case .resolveDNS:
                // Served asynchronously by ControlServer for the App Proxy
                // extension only; it never enters the lifecycle dispatcher.
                throw serverError("DNS resolution is not a lifecycle operation")
            }
            if [.importProfile, .switchProfile, .reloadProfile, .controllerRequest, .restartAgent, .startAgent].contains(request.operation) {
                do { try refreshSystemProxy(restoreSavedChoice: request.operation == .startAgent) } catch { ServiceLog.error("event=system_proxy_reconcile result=failed") }
            }
            if auditRoutineLifecycle {
                ServiceLog.info("event=control_request operation=\(operation) result=success")
            }
            return ControlResponse(success: true, payload: payload)
        } catch ControllerBrokerCriticalError.unsafeGlobalRuntime {
            // A controller mutation that cannot restore a proven-safe Global
            // route must fail closed. Stopping the daemon-owned agent also
            // restores system DNS through the normal shutdown path.
            let restored = agent.stopAndRestoreVerified()
            ServiceLog.error(
                "event=control_request operation=\(operation) result=" +
                (restored ? "failed_closed" : "restore_unconfirmed")
            )
            return ControlResponse(
                success: false,
                error: restored
                    ? "the unsafe Global runtime was stopped"
                    : "the unsafe Global runtime stop was attempted; network restore is unconfirmed"
            )
        } catch {
            ServiceLog.error("event=control_request operation=\(operation) result=failed")
            return ControlResponse(
                success: false,
                error: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private func serverError(_ message: String) -> Error {
        NSError(domain: "MihomoControlServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func scheduleDaemonRestart() {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) {
            exit(1)
        }
    }

    func stopIndependentServices() {
        do { try systemProxy.setEnabled(false) } catch { ServiceLog.error("event=system_proxy_restore result=failed") }
        dnsResolver.shutdown()
    }

    private static func isMutating(_ operation: ControlOperation) -> Bool {
        switch operation {
        case .startAgent, .stopAgent, .restartAgent, .upgradeComponents, .setSystemProxy,
             .importProfile, .switchProfile, .reloadProfile, .setTUN,
             .setOutboundMode, .selectProxy, .refreshProxyProvider,
             .closeAllConnections, .setAppProxyRouting, .setAppProxyProcesses:
            return true
        case .controllerRequest:
            // ControllerRequestPolicy is still the authority for the exact
            // method/path/body. The dispatcher serializes every such request
            // because this operation represents both safe reads and bounded
            // mutations, and the typed envelope does not carry the method here.
            return true
        case .ping, .status, .trayState, .snapshot, .componentStatus, .appProxyStatus, .resolveDNS,
             .controllerVersion, .listRules, .listProxyProviders,
             .listRuleProviders, .listConnections, .controllerStreamMessage,
             .controllerStreamOpen, .controllerStreamNext, .controllerStreamClose,
             .listProfiles, .testDelay:
            return false
        }
    }

    /// The first launch of replaced component binaries waits for macOS to assess them,
    /// which took over 20 seconds under load; a premature rollback interrupts the proxy twice.
    static let updatedComponentsStartTimeout: TimeInterval = 60

    private func ensureStartedRuntimeLocked(timeout: TimeInterval = 20) throws {
        do {
            try Self.validateStartedRuntime(agent: agent, controller: controller, timeout: timeout)
        } catch {
            throw ControllerBrokerCriticalError.unsafeGlobalRuntime
        }
    }

    /// Re-applies a remembered TUN choice whose transition did not finish
    /// (for example after a failed switch or a reboot during one).
    private func resumeEnhancedRuntimeLocked() throws {
        guard agent.resumesEnhancedTUN, !agent.expectsEnhancedTUN else { return }
        try profiles.setEnhancedTUN(true)
    }

    /// Completes an unfinished switch-off before the core starts, so it never
    /// comes up owning Global DNS and a TUN route the user turned off.
    private func ensureRuntimePrerequisiteLocked() throws {
        guard !agent.resumesEnhancedTUN, agent.expectsEnhancedTUN else { return }
        try profiles.setEnhancedTUN(false)
    }

    private func refreshSystemProxy(restoreSavedChoice: Bool = false) throws {
        guard agent.requestsSystemProxy, agent.isRunning else {
            if systemProxy.hasSavedState { try systemProxy.setEnabled(false) }
            return
        }
        let data = try controller.perform(ControlRequest(operation:.snapshot))
        if let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
           let config = object["configs"] as? [String:Any], let port = config["mixed-port"] as? Int {
            if systemProxy.hasSavedState && !restoreSavedChoice {
                try systemProxy.updatePortIfNeeded(port)
            } else {
                try systemProxy.setEnabled(true, port: port)
            }
        }
    }

    private func reconcileSystemProxy() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        do { try refreshSystemProxy() } catch { ServiceLog.error("event=system_proxy_reconcile result=failed") }
    }

    /// Validate standby (no system DNS, no TUN) or Global DNS + TUN, which
    /// requires the TUN route and the 127.0.0.53 bridge answering a standard
    /// query (the form DNS Proxy providers such as MTTA forward).
    private static func validateStartedRuntime(
        agent: AgentSupervisor,
        controller: ControllerBroker,
        timeout: TimeInterval = 20
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let clock = MonotonicStartupClock()
        let changes = try agent.healthSnapshotChanges()
        var lastError: Error?
        repeat {
            guard agent.isRunning else {
                throw ControllerBrokerCriticalError.unsafeGlobalRuntime
            }
            do {
                guard let health = try agent.expectedHealthSnapshot()?.health else {
                    throw serverErrorStatic("awaiting current agent health generation")
                }
                guard health.controllerReachable,
                      health.fakeIPMode,
                      health.mihomoDNSReady,
                      health.networkConsistent else {
                    throw serverErrorStatic("the managed network is not ready")
                }
                if agent.globalDNSFallbackConfigured {
                    guard health.systemDNSManaged, health.dnsBridgeReady else {
                        throw serverErrorStatic("the Global DNS bridge is not ready")
                    }
                } else {
                    guard !agent.managesSystemDNS, !health.systemDNSManaged else {
                        throw serverErrorStatic("the standby runtime still owns system DNS")
                    }
                }
                if agent.expectsEnhancedTUN {
                    guard health.tunEnabled,
                          health.tunInterface?.isEmpty == false,
                          health.fakeIPRouteReady else {
                        throw serverErrorStatic("the Enhanced TUN network is not ready")
                    }
                } else {
                    guard !health.tunEnabled,
                          health.tunInterface == nil,
                          !health.fakeIPRouteReady else {
                        throw serverErrorStatic("the standby runtime still owns a TUN route")
                    }
                }
                // Controller verification follows the matching agent snapshot;
                // polling pending generations must not create an active probe loop.
                ServiceLog.info("event=runtime_validation phase=health_ready elapsed_ms=\(clock.elapsedMilliseconds())")
                try controller.ensureRuntimeRoutes(requireSafeGlobal: agent.expectsEnhancedTUN)
                ServiceLog.info("event=runtime_validation phase=routes_verified elapsed_ms=\(clock.elapsedMilliseconds())")
                return
            } catch ControllerBrokerCriticalError.unsafeGlobalRuntime {
                throw ControllerBrokerCriticalError.unsafeGlobalRuntime
            } catch {
                lastError = error
                if Date() < deadline {
                    // An atomic snapshot replacement wakes us immediately.
                    // Keep bounded polling as a fallback for lost/coalesced
                    // hints, and always validate the generation after waking.
                    let elapsed = clock.elapsedMilliseconds()
                    let delay = min(deadline.timeIntervalSinceNow,
                                    elapsed < 250 ? 0.01 : (elapsed < 1_000 ? 0.05 : 0.25))
                    if let changes { changes.wait(timeout: delay) }
                    else if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                }
            }
        } while Date() < deadline
        throw lastError ?? serverErrorStatic("the managed network did not become ready")
    }

    private static func serverErrorStatic(_ message: String) -> Error {
        NSError(
            domain: "MihomoControlServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

final class ControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo.daemon.xpc", attributes: .concurrent)
    private let dispatcher: ControlDispatcher
    private let requirement: String
    private let extensionRequirement: SecRequirement
    private let rolesLock = NSLock()
    private var roles: [ObjectIdentifier: ControlPeerRole] = [:]
    private var listener: xpc_connection_t?

    init(dispatcher: ControlDispatcher) throws {
        self.dispatcher = dispatcher
        requirement = try SigningCertificateRequirement.currentProcess()
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(
            AppProxyDNSPolicy.extensionRequirement(certificateFamily: requirement) as CFString,
            [],
            &compiled
        ) == errSecSuccess, let compiled else {
            throw NSError(domain: "MihomoControlServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to compile the App Proxy extension requirement",
            ])
        }
        extensionRequirement = compiled
    }

    func start() throws {
        let listener = xpc_connection_create_mach_service(
            mihomoControlServiceName,
            queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        guard xpc_connection_set_peer_code_signing_requirement(listener, requirement) == 0 else {
            throw serverError("failed to install the XPC client certificate requirement")
        }
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self, xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            self.accept(event)
        }
        self.listener = listener
        xpc_connection_resume(listener)
        ServiceLog.info("event=control_server_started")
    }

    func stop() {
        if let listener { xpc_connection_cancel(listener) }
        listener = nil
        ServiceLog.info("event=control_server_stopped")
    }

    private func accept(_ peer: xpc_connection_t) {
        guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
            ServiceLog.error("event=control_peer_rejected reason=signing_requirement")
            xpc_connection_cancel(peer)
            return
        }
        ServiceLog.info("event=control_peer_accepted")
        let owner = ObjectIdentifier(peer)
        xpc_connection_set_event_handler(peer) { [weak self, weak peer] event in
            guard let self else { return }
            let type = xpc_get_type(event)
            if type == XPC_TYPE_DICTIONARY {
                guard let peer else { return }
                self.handle(event, peer: peer)
                return
            }
            // A websocket is normally torn down by SIGKILLing the CLI holding
            // it, so no close request ever arrives and the peer simply vanishes.
            // Without this the streams it opened sat in the table occupying the
            // stream budget until their idle expiry.
            if type == XPC_TYPE_ERROR {
                ServiceLog.info("event=control_peer_disconnected")
                self.forgetRole(owner)
                self.dispatcher.controllerBroker.releaseStreams(owner: owner)
            }
        }
        xpc_connection_resume(peer)
    }

    private func handle(_ message: xpc_object_t, peer: xpc_connection_t) {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, "request", &length), length > 0,
              var request = try? JSONDecoder().decode(
                  ControlRequest.self,
                  from: Data(bytes: bytes, count: length)
              ) else {
            ServiceLog.error("event=control_request operation=unknown result=invalid_request")
            send(ControlResponse(success: false, error: "invalid XPC request"), replyingTo: message, peer: peer)
            return
        }
        var payloadLength = 0
        if let payload = xpc_dictionary_get_data(message, "payload", &payloadLength),
           payloadLength > 0 {
            guard payloadLength <= mihomoControlMaximumPayloadBytes else {
                ServiceLog.error(
                    "event=control_request operation=\(request.operation.rawValue) " +
                    "result=payload_too_large"
                )
                send(
                    ControlResponse(success: false, error: "XPC payload exceeds the size limit"),
                    replyingTo: message,
                    peer: peer
                )
                return
            }
            request.payload = Data(bytes: payload, count: payloadLength)
        }
        // Every peer passed the certificate-family requirement. The App Proxy
        // extension is further confined to DNS answers, and DNS answers are
        // served only to it.
        let role = role(of: peer, message: message)
        guard AppProxyDNSPolicy.permits(request.operation, role: role) else {
            ServiceLog.error(
                "event=control_request operation=\(request.operation.rawValue) " +
                "result=peer_not_permitted role=\(role.rawValue)"
            )
            send(
                ControlResponse(success: false, error: "this operation is not permitted for the caller"),
                replyingTo: message,
                peer: peer
            )
            return
        }
        if request.operation == .resolveDNS {
            resolveDNS(request, replyingTo: message, peer: peer)
            return
        }
        send(
            dispatcher.dispatch(request, owner: ObjectIdentifier(peer)),
            replyingTo: message,
            peer: peer
        )
    }

    /// Replies asynchronously so one connection's queries do not wait on each
    /// other. Individual queries and answers are never logged.
    private func resolveDNS(
        _ request: ControlRequest,
        replyingTo message: xpc_object_t,
        peer: xpc_connection_t
    ) {
        guard request.version == mihomoControlProtocolVersion,
              request.arguments.isEmpty,
              let query = request.payload else {
            send(ControlResponse(success: false, error: "invalid DNS request"), replyingTo: message, peer: peer)
            return
        }
        dispatcher.resolveAppProxyDNS(query) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let answer):
                self.send(ControlResponse(success: true, payload: answer), replyingTo: message, peer: peer)
            case .failure(let failure):
                self.send(
                    ControlResponse(success: false, error: "dns_\(failure)"),
                    replyingTo: message,
                    peer: peer
                )
            }
        }
    }

    /// Classifies a connection once, from the audit token of its first
    /// message. A connection cannot change its process, and the entry is
    /// dropped when the connection is invalidated.
    private func role(of peer: xpc_connection_t, message: xpc_object_t) -> ControlPeerRole {
        let key = ObjectIdentifier(peer)
        rolesLock.lock()
        if let cached = roles[key] {
            rolesLock.unlock()
            return cached
        }
        rolesLock.unlock()
        var code: SecCode?
        let isExtension = SecCodeCreateWithXPCMessage(message, [], &code) == errSecSuccess
            && code.map { SecCodeCheckValidity($0, [], extensionRequirement) == errSecSuccess } == true
        let role: ControlPeerRole = isExtension ? .appProxyExtension : .controller
        rolesLock.lock()
        roles[key] = role
        rolesLock.unlock()
        if isExtension { ServiceLog.info("event=control_peer_classified role=\(role.rawValue)") }
        return role
    }

    private func forgetRole(_ key: ObjectIdentifier) {
        rolesLock.lock()
        roles[key] = nil
        rolesLock.unlock()
    }

    private func send(
        _ response: ControlResponse,
        replyingTo message: xpc_object_t,
        peer: xpc_connection_t
    ) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        var envelope = response
        envelope.payload = nil
        guard
              xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              let encoded = try? JSONEncoder().encode(envelope) else { return }
        encoded.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(reply, "response", bytes.baseAddress, encoded.count)
        }
        response.payload?.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(reply, "payload", bytes.baseAddress, bytes.count)
        }
        xpc_connection_send_message(peer, reply)
    }

    private func serverError(_ message: String) -> Error {
        NSError(domain: "MihomoControlServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
