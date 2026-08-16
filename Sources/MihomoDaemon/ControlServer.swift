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
    private let components: ComponentUpdater
    private let mutationLock = NSLock()

    init(agent: AgentSupervisor, configPath: String) throws {
        self.agent = agent
        let controllerBroker = ControllerBroker(configPath: configPath)
        let validateStartedRuntime = {
            try Self.validateStartedRuntime(agent: agent, controller: controllerBroker)
        }
        controller = controllerBroker
        profiles = ProfileBroker(
            agent: agent,
            validateStartedRuntime: validateStartedRuntime
        )
        components = try ComponentUpdater(
            agent: agent,
            validateStartedRuntime: validateStartedRuntime
        )
    }

    /// Boot keeps the Mach service available even when the managed runtime
    /// cannot prove a safe route. This lets the signed App repair a profile or
    /// retry start without launchd crash-looping the root daemon.
    func startInitialRuntime() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        if components.recoveryRequired {
            let restored = agent.stopAndRestoreVerified()
            ServiceLog.error(
                "event=initial_runtime result=" +
                (restored ? "component_recovery_required" : "restore_unconfirmed")
            )
            return
        }
        if components.requiresDaemonRestart {
            ServiceLog.info("event=component_update result=restart_after_interrupted_recovery")
            scheduleDaemonRestart()
            return
        }
        if profiles.activationRequired {
            do {
                try components.commitPendingBootValidation()
                ServiceLog.info("event=initial_runtime result=awaiting_profile")
            } catch {
                let rolledBack = components.rollbackPendingBootValidation()
                ServiceLog.error(
                    "event=initial_runtime result=" +
                    (rolledBack ? "component_rolled_back" : "component_recovery_required")
                )
                if rolledBack { scheduleDaemonRestart() }
            }
            return
        }
        do {
            try agent.start()
            try ensureStartedRuntimeLocked()
            try components.commitPendingBootValidation()
            ServiceLog.info("event=initial_runtime result=ready")
        } catch {
            let restored = agent.stopAndRestoreVerified()
            let hadPendingUpdate = components.hasPendingBootValidation
            let componentRollback = components.rollbackPendingBootValidation()
            ServiceLog.error(
                "event=initial_runtime result=" +
                (restored && componentRollback ? "stopped" : "restore_unconfirmed")
            )
            if hadPendingUpdate, componentRollback {
                scheduleDaemonRestart()
            }
        }
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
        let auditEveryRequest = request.operation != .controllerStreamNext
        if auditEveryRequest {
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
                var status = (try? JSONSerialization.jsonObject(with: agent.health())) as? [String: Any] ?? [:]
                status["agent_running"] = agent.isRunning
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
                let health = (try? agent.health())
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
                try agent.start()
                try ensureStartedRuntimeLocked()
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
                payload = try controller.perform(request, owner: owner)
                try ensureStartedRuntimeLocked()
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
            if auditEveryRequest {
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

    private static func isMutating(_ operation: ControlOperation) -> Bool {
        switch operation {
        case .startAgent, .stopAgent, .restartAgent, .upgradeComponents,
             .importProfile, .switchProfile, .reloadProfile, .setTUN,
             .setOutboundMode, .selectProxy, .refreshProxyProvider,
             .closeAllConnections:
            return true
        case .controllerRequest:
            // ControllerRequestPolicy is still the authority for the exact
            // method/path/body. The dispatcher serializes every such request
            // because this operation represents both safe reads and bounded
            // mutations, and the typed envelope does not carry the method here.
            return true
        case .ping, .status, .trayState, .snapshot, .componentStatus,
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

    /// Activation is committed only after the complete managed-network truth
    /// is live. A controller socket alone is not enough: TUN, Fake-IP routing,
    /// both DNS bridges and system DNS ownership must all agree.
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
                try controller.ensureSafeGlobalRoute()
                let health = try agent.freshHealth()
                guard health.controllerReachable,
                      health.tunEnabled,
                      health.tunInterface?.isEmpty == false,
                      health.fakeIPMode,
                      health.fakeIPRouteReady,
                      health.dnsBridgeReady,
                      health.mihomoDNSReady,
                      health.systemDNSManaged,
                      health.networkConsistent else {
                    throw serverErrorStatic("the managed network is not ready")
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
