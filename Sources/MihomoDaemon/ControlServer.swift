import Darwin
import Foundation
import MihomoControl
import XPC

final class ControlDispatcher: @unchecked Sendable {
    private let agent: AgentSupervisor
    private let controller: ControllerBroker
    private let profiles: ProfileBroker
    private let components: ComponentUpdater

    init(agent: AgentSupervisor, configPath: String) throws {
        self.agent = agent
        controller = ControllerBroker(configPath: configPath)
        profiles = ProfileBroker(agent: agent)
        components = try ComponentUpdater(agent: agent)
    }

    func dispatch(_ request: ControlRequest) -> ControlResponse {
        guard request.version == mihomoControlProtocolVersion else {
            return ControlResponse(success: false, error: "unsupported control protocol version")
        }
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
            case .startAgent:
                try agent.start()
                payload = nil
            case .stopAgent:
                agent.stop()
                payload = nil
            case .restartAgent:
                try agent.restart()
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
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) {
                        exit(1)
                    }
                }
            case .listProfiles:
                payload = try profiles.list()
            case .importProfile, .switchProfile, .reloadProfile:
                payload = try profiles.perform(request)
            case .snapshot, .setTUN, .setOutboundMode, .selectProxy, .testDelay,
                 .controllerVersion, .listRules, .listProxyProviders, .listRuleProviders,
                 .listConnections, .closeAllConnections, .controllerRequest,
                 .controllerStreamMessage:
                guard agent.isRunning else {
                    throw serverError("Mihomo agent is not running")
                }
                payload = try controller.perform(request)
            }
            return ControlResponse(success: true, payload: payload)
        } catch {
            return ControlResponse(
                success: false,
                error: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private func serverError(_ message: String) -> Error {
        NSError(domain: "MihomoControlServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
    }

    func stop() {
        if let listener { xpc_connection_cancel(listener) }
        listener = nil
    }

    private func accept(_ peer: xpc_connection_t) {
        guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
            xpc_connection_cancel(peer)
            return
        }
        xpc_connection_set_event_handler(peer) { [weak self, weak peer] event in
            guard let self, let peer else { return }
            if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
                self.handle(event, peer: peer)
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
            response = dispatcher.dispatch(request)
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
