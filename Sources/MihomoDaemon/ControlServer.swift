import Darwin
import Foundation
import MihomoControl
import MihomoDNSCore
import XPC

final class ControlDispatcher: @unchecked Sendable {
    /// Lets the server release a dead peer's streams.
    var controllerBroker: ControllerBroker { controller }

    private let agent: AgentSupervisor
    private let controller: ControllerBroker
    private let profiles: ProfileBroker
    private let localDoH: LocalDoHManager
    private let localDoHServer: IndependentLocalDoHServer
    private let components: ComponentUpdater
    private let startupClock: MonotonicStartupClock
    private let mutationLock = NSLock()
    private var localDoHReadinessTimer: DispatchSourceTimer?
    private var localDoHReadinessRecovery = LocalDoHReadinessRecovery()

    init(
        agent: AgentSupervisor,
        configPath: String,
        startupClock: MonotonicStartupClock = MonotonicStartupClock()
    ) throws {
        self.agent = agent
        self.startupClock = startupClock
        let controllerBroker = ControllerBroker(configPath: configPath)
        let validateStartedRuntime = {
            try Self.validateStartedRuntime(agent: agent, controller: controllerBroker)
        }
        let localDoHServer = IndependentLocalDoHServer(
            configurationPath: configPath
        )
        controller = controllerBroker
        self.localDoHServer = localDoHServer
        profiles = ProfileBroker(
            agent: agent,
            validateStartedRuntime: validateStartedRuntime
        )
        localDoH = LocalDoHManager(
            agent: agent,
            controller: controllerBroker,
            server: localDoHServer
        )
        components = try ComponentUpdater(
            agent: agent,
            validateStartedRuntime: validateStartedRuntime
        )
        localDoHServer.setFailureHandler { [weak self] in
            // The callback originates on the listener queue. Enter lifecycle
            // serialization elsewhere so stopping the server cannot deadlock.
            DispatchQueue.global().async { [weak self] in
                self?.handleLocalDoHFailure()
            }
        }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "dev.linsheng.mihomo.local-doh-readiness")
        )
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkLocalDoHReadiness() }
        localDoHReadinessTimer = timer
        timer.resume()
    }

    deinit { localDoHReadinessTimer?.cancel() }

    /// Boot keeps the Mach service available even when the managed runtime
    /// cannot prove a safe route. This lets the signed App repair a profile or
    /// retry start without launchd crash-looping the root daemon.
    func startInitialRuntime() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        // Prepared Local DoH is a daemon base service, even if the agent's
        // recovery/startup subsequently fails or remains intentionally stopped.
        localDoHServer.startSupervising()
        if components.recoveryRequired {
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
        let preserveFallback = agent.globalDNSFallbackConfigured
        let resumeEnhancedTUN = agent.resumesEnhancedTUN
        // Restore using the OLD DNS owner before changing daemon.json, or a
        // persisted 198.18.0.1 backup would be compared against 127.0.0.53.
        guard agent.stopAndRestoreVerified() else {
            ServiceLog.error("event=initial_runtime result=dns_restore_unconfirmed")
            logInitialRuntimeStartup(result: "dns_restore_unconfirmed")
            return
        }
        let installedProfile = LocalDoHStatusProvider.inspectInstalledProfile()
        let enhancedPrerequisitePrepared = installedProfile.succeeded
            && installedProfile.inspection.installed
            && installedProfile.inspection.domainCount > 0
            && agent.localDoHIdentityPrepared
            && LocalDoHStatusProvider.certificateTrusted()
        do {
            if !preserveFallback {
                try profiles.ensureLocalHttpDNSBaseConfiguration(
                    allowEnhancedTUN: enhancedPrerequisitePrepared
                )
            }
        } catch {
            let restored = agent.stopAndRestoreVerified()
            ServiceLog.error(
                "event=initial_runtime result=" +
                (restored ? "local_http_dns_migration_failed" : "restore_unconfirmed")
            )
            logInitialRuntimeStartup(
                result: restored ? "local_http_dns_migration_failed" : "restore_unconfirmed"
            )
            return
        }
        let localStarted = localDoHServer.startSupervising()
        if localStarted {
            ServiceLog.info("event=initial_local_doh result=ready")
        }
        do {
            if !preserveFallback {
                try profiles.ensureLocalHttpDNSBaseConfiguration(
                    allowEnhancedTUN: enhancedPrerequisitePrepared && localStarted
                )
            }
        } catch {
            ServiceLog.error("event=initial_runtime result=local_http_dns_start_failed")
            logInitialRuntimeStartup(result: "local_http_dns_start_failed")
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
            if !preserveFallback && !localStarted
                && (agent.localDoHIdentityPrepared || installedProfile.present == true) {
                try activateGlobalDNSFallbackLocked()
            } else {
                try agent.start()
                try ensureStartedRuntimeLocked()
                if preserveFallback { finishGlobalDNSFallbackLocked() }
            }
            if resumeEnhancedTUN { try resumeEnhancedRuntimeLocked() }
            try components.commitPendingBootValidation()
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
                if agent.resumesEnhancedTUN { try resumeEnhancedRuntimeLocked() }
                payload = nil
            case .stopAgent:
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
            case .localDoHStatus:
                let health = (try? agent.passiveHealth()).flatMap {
                    try? JSONDecoder().decode(NetworkConsistencyHealth.self, from: $0)
                }
                let profile = LocalDoHStatusProvider.inspectInstalledProfile()
                let preparedProfile = LocalDoHStatusProvider.inspectPreparedProfile()
                let prepared = agent.localDoHIdentityPrepared
                let trusted = prepared && LocalDoHStatusProvider.certificateTrusted()
                let status = LocalDoHStatus(
                    serverPrepared: prepared,
                    profileInstalled: profile.inspection.installed,
                    profileInspectionSucceeded: profile.succeeded,
                    runtimeHealthy: prepared && localDoHServer.isRunning && trusted
                        && (agent.localDoHBackendReady || localDoHServer.originalDNSAvailable),
                    systemDNSManaged: health?.systemDNSManaged,
                    installedDomainCount: profile.inspection.domainCount,
                    preparedDomainCount: preparedProfile.domainCount,
                    globalDNSFallback: agent.globalDNSFallbackConfigured,
                    fallbackProfileRemovalRequired: agent.globalDNSFallbackConfigured
                        && profile.present != false,
                    certificateTrusted: trusted,
                    resumeEnhancedTUN: agent.resumesEnhancedTUN
                )
                payload = try JSONEncoder().encode(status)
            case .installLocalDoH:
                guard !profiles.activationRequired else {
                    throw serverError("activate a profile before preparing LocalHttpDns")
                }
                do {
                    localDoHReadinessRecovery = LocalDoHReadinessRecovery()
                    if agent.globalDNSFallbackConfigured {
                        if !agent.isRunning {
                            try agent.start()
                            try ensureStartedRuntimeLocked()
                        }
                        // setEnhancedTUN is a root-file transaction which
                        // restores the old Global DNS owner before switching.
                        try profiles.setEnhancedTUN(false)
                    }
                    payload = try JSONEncoder().encode(localDoH.install())
                } catch {
                    try activateGlobalDNSFallbackLocked()
                    throw serverError(
                        "LocalHttpDns preparation failed; Global DNS fallback was configured. " +
                        "Check LocalHttpDns status for any required profile removal."
                    )
                }
            case .trustLocalDoHCertificate:
                guard request.arguments.isEmpty, request.payload == nil else {
                    throw serverError("certificate trust accepts no arguments or certificate bytes")
                }
                try localDoH.trustCertificate()
                localDoHReadinessRecovery = LocalDoHReadinessRecovery()
                payload = nil
            case .setDNSMode:
                guard request.payload == nil, request.arguments.count == 1,
                      let raw = request.arguments["mode"],
                      let mode = DNSIntegrationMode(rawValue: raw),
                      !profiles.activationRequired else {
                    throw serverError("a valid DNS integration mode and an activated profile are required")
                }
                switch mode {
                case .globalDNS:
                    try activateGlobalDNSFallbackLocked()
                    let profile = LocalDoHStatusProvider.inspectInstalledProfile()
                    guard profile.succeeded, profile.present == false else {
                        throw serverError(
                            "Global DNS is configured, but the Local DoH profile still overrides it. " +
                            "Remove only the MihomoBox Local DoH profile in Device Management."
                        )
                    }
                case .localDoH:
                    let profile = LocalDoHStatusProvider.inspectInstalledProfile()
                    guard profile.succeeded, profile.inspection.installed,
                          agent.localDoHIdentityPrepared,
                          LocalDoHStatusProvider.certificateTrusted() else {
                        throw serverError(
                            "prepare and trust the Local DoH certificate, then install its current profile before selecting Local DoH"
                        )
                    }
                    do {
                        if agent.globalDNSFallbackConfigured {
                            if !agent.isRunning { try agent.start() }
                            try profiles.setEnhancedTUN(agent.expectsEnhancedTUN)
                        }
                        guard localDoHServer.startSupervising() else {
                            throw serverError("the Local DoH HTTPS listener is unavailable")
                        }
                        guard agent.localDoHBackendReady || localDoHServer.originalDNSAvailable else {
                            throw serverError("the Local DoH DNS backend is unavailable")
                        }
                        localDoHReadinessRecovery = LocalDoHReadinessRecovery()
                    } catch {
                        try activateGlobalDNSFallbackLocked()
                        throw serverError("Local DoH activation failed; Global DNS fallback was configured")
                    }
                }
                DNSCacheMaintenance.flushSystemCaches()
                payload = nil
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
                guard !profiles.activationRequired else {
                    throw serverError("activate a profile before enabling Enhanced TUN")
                }
                guard agent.isRunning else {
                    throw serverError("Mihomo agent is not running")
                }
                guard let raw = request.arguments["enabled"],
                      let enabled = ["true": true, "false": false][raw] else {
                    throw serverError("Enhanced TUN enabled state is required")
                }
                if agent.globalDNSFallbackConfigured {
                    if enabled {
                        try ensureStartedRuntimeLocked()
                    } else {
                        // There is no independent DNS service in fallback.
                        // Turning TUN off therefore stops the worker and
                        // restores physical DNS through verified shutdown.
                        guard agent.stopAndRestoreVerified() else {
                            throw ControllerBrokerCriticalError.unsafeGlobalRuntime
                        }
                    }
                    payload = nil
                    break
                }
                if enabled {
                    let profile = LocalDoHStatusProvider.inspectInstalledProfile()
                    guard profile.succeeded,
                          profile.inspection.installed,
                          profile.inspection.domainCount > 0,
                          agent.localDoHIdentityPrepared,
                          LocalDoHStatusProvider.certificateTrusted(),
                          localDoHServer.isRunning else {
                        throw serverError(
                            "install the LocalHttpDns profile and approve its SSL certificate trust before enabling Enhanced TUN"
                        )
                    }
                }
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
        localDoHServer.shutdown()
    }

    private static func isMutating(_ operation: ControlOperation) -> Bool {
        switch operation {
        case .startAgent, .stopAgent, .restartAgent, .upgradeComponents,
             .importProfile, .switchProfile, .reloadProfile, .setTUN,
             .setOutboundMode, .selectProxy, .refreshProxyProvider,
             .closeAllConnections, .installLocalDoH, .trustLocalDoHCertificate, .setDNSMode:
            return true
        case .controllerRequest:
            // ControllerRequestPolicy is still the authority for the exact
            // method/path/body. The dispatcher serializes every such request
            // because this operation represents both safe reads and bounded
            // mutations, and the typed envelope does not carry the method here.
            return true
        case .ping, .status, .trayState, .snapshot, .componentStatus, .localDoHStatus,
             .controllerVersion, .listRules, .listProxyProviders,
             .listRuleProviders, .listConnections, .controllerStreamMessage,
             .controllerStreamOpen, .controllerStreamNext, .controllerStreamClose,
             .listProfiles, .testDelay:
            return false
        }
    }

    private func ensureStartedRuntimeLocked() throws {
        do {
            try Self.validateStartedRuntime(agent: agent, controller: controller)
        } catch {
            throw ControllerBrokerCriticalError.unsafeGlobalRuntime
        }
    }

    private func resumeEnhancedRuntimeLocked() throws {
        guard !agent.expectsEnhancedTUN else { return }
        let profile = LocalDoHStatusProvider.inspectInstalledProfile()
        if profile.inspection.installed && LocalDoHStatusProvider.certificateTrusted()
            && localDoHServer.isRunning {
            try profiles.setEnhancedTUN(true)
        } else {
            // Remembering Enhanced mode must not depend on a fresh profile
            // approval at every boot. The existing verified fallback is safe.
            try activateGlobalDNSFallbackLocked()
        }
    }

    private func ensureRuntimePrerequisiteLocked() throws {
        if agent.globalDNSFallbackConfigured { return }
        guard agent.localHttpDNSBaseConfigured else {
            throw serverError("repair the LocalHttpDns base service before starting Mihomo")
        }
        if agent.localDoHIdentityPrepared, !localDoHServer.isRunning,
           (try? localDoHServer.startIfPrepared()) != true {
            try activateGlobalDNSFallbackLocked()
            return
        }
        guard agent.expectsEnhancedTUN else { return }
        let profile = LocalDoHStatusProvider.inspectInstalledProfile()
        guard profile.succeeded,
              profile.inspection.installed,
              profile.inspection.domainCount > 0,
              agent.localDoHIdentityPrepared,
              LocalDoHStatusProvider.certificateTrusted(),
              localDoHServer.isRunning else {
            throw serverError(
                "LocalHttpDns must be installed and healthy before starting Enhanced TUN"
            )
        }
    }

    private func checkLocalDoHReadiness() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard agent.isRunning, agent.localHttpDNSBaseConfigured,
              !agent.globalDNSFallbackConfigured, !profiles.activationRequired,
              !components.recoveryRequired, !components.requiresDaemonRestart,
              !components.ownsPendingMutationFileLock else {
            localDoHReadinessRecovery = LocalDoHReadinessRecovery()
            return
        }
        let profile = LocalDoHStatusProvider.inspectInstalledProfile()
        let trusted = LocalDoHStatusProvider.certificateTrusted()
        let ready = profile.inspection.installed && trusted && localDoHServer.isRunning
        guard localDoHReadinessRecovery.needsFallback(
            profilePresent: profile.present, ready: ready,
            now: ProcessInfo.processInfo.systemUptime
        ) else { return }
        do {
            let externalLock = try ComponentMutationFileLock()
            defer { withExtendedLifetime(externalLock) {} }
            ServiceLog.error("event=local_doh_readiness result=" +
                (trusted ? "profile_or_listener_invalid" : "ssl_trust_failed"))
            try activateGlobalDNSFallbackLocked()
            localDoHReadinessRecovery = LocalDoHReadinessRecovery()
        } catch {
            ServiceLog.error("event=local_doh_readiness result=fallback_failed")
        }
    }

    private func activateGlobalDNSFallbackLocked() throws {
        // Cancel recovery before the stop/configure transaction: otherwise a
        // timer could rebind 443 while daemon.json still says LocalHttpDns.
        localDoHServer.shutdown()
        do {
            try GlobalDNSFallbackTransition.run(
                stopAndRestore: { agent.stopAndRestoreVerified() },
                configure: { try profiles.configureGlobalDNSFallback() },
                startAndValidate: {
                    try agent.start()
                    try ensureStartedRuntimeLocked()
                },
                finish: { finishGlobalDNSFallbackLocked() }
            )
        } catch GlobalDNSFallbackTransition.Failure.restoreUnconfirmed {
            throw ControllerBrokerCriticalError.unsafeGlobalRuntime
        } catch {
            throw error
        }
    }

    private func finishGlobalDNSFallbackLocked() {
        let removed = localDoH.removeProfileForGlobalDNSFallback()
        DNSCacheMaintenance.flushSystemCaches()
        ServiceLog.info(
            "event=global_dns_fallback result=" +
            (removed ? "ready" : "profile_removal_required")
        )
    }

    private func handleLocalDoHFailure() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard agent.isRunning, agent.localHttpDNSBaseConfigured,
              !localDoHServer.isRunning, !profiles.activationRequired,
              !components.recoveryRequired, !components.requiresDaemonRestart,
              !components.ownsPendingMutationFileLock else { return }
        do {
            let externalLock = try ComponentMutationFileLock()
            defer { withExtendedLifetime(externalLock) {} }
            try activateGlobalDNSFallbackLocked()
        } catch {
            ServiceLog.error("event=global_dns_fallback result=failed")
        }
    }

    /// Validate standby, LocalHttpDns Enhanced mode, or the explicit Global
    /// DNS fallback. Fallback requires both TUN and its port-53 data path.
    private static func validateStartedRuntime(
        agent: AgentSupervisor,
        controller: ControllerBroker,
        timeout: TimeInterval = 20
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
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
                        throw serverErrorStatic("the Global DNS fallback is not ready")
                    }
                } else {
                    guard agent.usesLocalDoH, !agent.managesSystemDNS,
                          !health.systemDNSManaged else {
                        throw serverErrorStatic("the DNS ownership is not ready")
                    }
                }
                if agent.expectsEnhancedTUN {
                    guard health.tunEnabled,
                          health.tunInterface?.isEmpty == false,
                          health.fakeIPRouteReady else {
                        throw serverErrorStatic("the Enhanced TUN network is not ready")
                    }
                    // Controller verification is deliberately after the
                    // matching agent snapshot. Polling while the generation is
                    // pending must not create another active probe loop.
                    try controller.ensureSafeGlobalRoute()
                } else {
                    guard !health.tunEnabled,
                          health.tunInterface == nil,
                          !health.fakeIPRouteReady else {
                        throw serverErrorStatic("the standby runtime still owns a TUN route")
                    }
                }
                return
            } catch ControllerBrokerCriticalError.unsafeGlobalRuntime {
                throw ControllerBrokerCriticalError.unsafeGlobalRuntime
            } catch {
                lastError = error
                if Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.25)
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
    private var listener: xpc_connection_t?

    init(dispatcher: ControlDispatcher) throws {
        self.dispatcher = dispatcher
        requirement = try SigningCertificateRequirement.currentProcess()
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
                self.dispatcher.controllerBroker.releaseStreams(owner: owner)
            }
        }
        xpc_connection_resume(peer)
    }

    private func handle(_ message: xpc_object_t, peer: xpc_connection_t) {
        let response: ControlResponse
        var length = 0
        if let bytes = xpc_dictionary_get_data(message, "request", &length), length > 0,
           var request = try? JSONDecoder().decode(
               ControlRequest.self,
               from: Data(bytes: bytes, count: length)
           ) {
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
            response = dispatcher.dispatch(request, owner: ObjectIdentifier(peer))
        } else {
            ServiceLog.error("event=control_request operation=unknown result=invalid_request")
            response = ControlResponse(success: false, error: "invalid XPC request")
        }

        send(response, replyingTo: message, peer: peer)
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
