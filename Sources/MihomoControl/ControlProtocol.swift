import CryptoKit
import Foundation
import Security
import XPC

public let mihomoControlServiceName = "dev.linsheng.mihomo.daemon.control"
public let mihomoControlProtocolVersion = 1

public enum ControlOperation: String, Codable, Sendable {
    case ping = "protocol.ping"
    case status = "service.status"
    case snapshot = "runtime.snapshot"
    case startAgent = "agent.start"
    case stopAgent = "agent.stop"
    case restartAgent = "agent.restart"
    case setTUN = "runtime.set-tun"
    case setOutboundMode = "runtime.set-outbound-mode"
    case selectProxy = "runtime.select-proxy"
    case testDelay = "proxy.test-delay"
    case controllerVersion = "dashboard.version"
    case listRules = "dashboard.rules"
    case listProxyProviders = "dashboard.proxy-providers"
    case listRuleProviders = "dashboard.rule-providers"
    case listConnections = "dashboard.connections"
    case closeAllConnections = "dashboard.connections.close-all"
    case controllerRequest = "dashboard.controller-request"
    case controllerStreamMessage = "dashboard.controller-stream-message"
    case listProfiles = "profile.list"
    case importProfile = "profile.import"
    case switchProfile = "profile.switch"
    case reloadProfile = "profile.reload"
}

public struct ControlRequest: Codable, Sendable {
    public var version: Int
    public var operation: ControlOperation
    public var arguments: [String: String]
    public var payload: Data?

    public init(
        operation: ControlOperation,
        arguments: [String: String] = [:],
        payload: Data? = nil
    ) {
        version = mihomoControlProtocolVersion
        self.operation = operation
        self.arguments = arguments
        self.payload = payload
    }
}

public struct ControlResponse: Codable, Sendable {
    public var version: Int
    public var success: Bool
    public var payload: Data?
    public var error: String?

    public init(success: Bool, payload: Data? = nil, error: String? = nil) {
        version = mihomoControlProtocolVersion
        self.success = success
        self.payload = payload
        self.error = error
    }
}

public enum ControlError: Error, LocalizedError {
    case unsignedProcess
    case invalidSigningInformation
    case invalidRequirement
    case connectionFailed
    case invalidReply
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .unsignedProcess:
            return "the process is not signed by an Apple-issued certificate"
        case .invalidSigningInformation:
            return "code-signing information is unavailable"
        case .invalidRequirement:
            return "the signing-certificate requirement is invalid"
        case .connectionFailed:
            return "the MihomoBox XPC service is unavailable or rejected the client certificate"
        case .invalidReply:
            return "the MihomoBox XPC service returned an invalid response"
        case let .rejected(message):
            return message
        }
    }
}

public enum SigningCertificateRequirement {
    public static func currentProcess() throws -> String {
        var currentCode: SecCode?
        guard SecCodeCopySelf([], &currentCode) == errSecSuccess, let currentCode else {
            throw ControlError.invalidSigningInformation
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(currentCode, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw ControlError.invalidSigningInformation
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any],
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first else {
            throw ControlError.unsignedProcess
        }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
        let requirement = "anchor apple generic and certificate leaf = H\"\(hexadecimal)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw ControlError.invalidRequirement
        }
        return requirement
    }
}

public final class MihomoControlClient: @unchecked Sendable {
    public init() {}

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let requirement = try SigningCertificateRequirement.currentProcess()
        let connection = xpc_connection_create_mach_service(
            mihomoControlServiceName,
            nil,
            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else {
            xpc_connection_cancel(connection)
            throw ControlError.invalidRequirement
        }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        defer { xpc_connection_cancel(connection) }

        var envelope = request
        envelope.payload = nil
        let encoded = try JSONEncoder().encode(envelope)
        let message = xpc_dictionary_create(nil, nil, 0)
        encoded.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, "request", bytes.baseAddress, encoded.count)
        }
        request.payload?.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, "payload", bytes.baseAddress, bytes.count)
        }
        let reply = xpc_connection_send_message_with_reply_sync(connection, message)
        guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
            throw ControlError.connectionFailed
        }
        var length = 0
        guard let pointer = xpc_dictionary_get_data(reply, "response", &length), length > 0 else {
            throw ControlError.invalidReply
        }
        var response = try JSONDecoder().decode(
            ControlResponse.self,
            from: Data(bytes: pointer, count: length)
        )
        var payloadLength = 0
        if let payload = xpc_dictionary_get_data(reply, "payload", &payloadLength), payloadLength > 0 {
            response.payload = Data(bytes: payload, count: payloadLength)
        }
        guard response.version == mihomoControlProtocolVersion else {
            throw ControlError.invalidReply
        }
        if !response.success {
            throw ControlError.rejected(response.error ?? "the XPC request was rejected")
        }
        return response
    }
}
