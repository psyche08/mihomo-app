import CryptoKit
import Foundation
import Security
import XPC

public let mihomoControlServiceName = "dev.linsheng.mihomo.daemon.control"
/// The native 0.8 control plane intentionally does not downgrade requests to
/// the pre-native protocol. A version-1 daemon is identified from its signed
/// response and must be replaced through the verified installer rather than
/// through its older, non-transactional self-update path.
public let mihomoControlProtocolVersion = 2
public let mihomoControlMaximumPayloadBytes = 256 * 1_024 * 1_024

public enum ControlOperation: String, Codable, Sendable {
    case ping = "protocol.ping"
    case status = "service.status"
    case trayState = "runtime.tray-state"
    case snapshot = "runtime.snapshot"
    case startAgent = "agent.start"
    case stopAgent = "agent.stop"
    case restartAgent = "agent.restart"
    case componentStatus = "component.status"
    case upgradeComponents = "component.upgrade"
    case setTUN = "runtime.set-tun"
    case setOutboundMode = "runtime.set-outbound-mode"
    case selectProxy = "runtime.select-proxy"
    case refreshProxyProvider = "runtime.refresh-proxy-provider"
    case testDelay = "proxy.test-delay"
    case controllerVersion = "dashboard.version"
    case listRules = "dashboard.rules"
    case listProxyProviders = "dashboard.proxy-providers"
    case listRuleProviders = "dashboard.rule-providers"
    case listConnections = "dashboard.connections"
    case closeAllConnections = "dashboard.connections.close-all"
    case controllerRequest = "dashboard.controller-request"
    case controllerStreamMessage = "dashboard.controller-stream-message"
    case controllerStreamOpen = "dashboard.controller-stream-open"
    case controllerStreamNext = "dashboard.controller-stream-next"
    case controllerStreamClose = "dashboard.controller-stream-close"
    case listProfiles = "profile.list"
    case importProfile = "profile.import"
    case switchProfile = "profile.switch"
    case reloadProfile = "profile.reload"
}

/// Controls only routine successful request lifecycle logging. Every refused,
/// malformed, or failed request is still audited by the daemon.
///
/// Tray state and stream-next are high-frequency read-only operations. Logging
/// a started/success pair for every call adds no diagnostic state transition
/// and can dominate the root daemon log during otherwise healthy operation.
public enum ControlRequestAuditPolicy {
    public static func logsRoutineLifecycle(for operation: ControlOperation) -> Bool {
        switch operation {
        case .trayState, .controllerStreamNext:
            return false
        default:
            return true
        }
    }
}

public enum ManagedComponent: String, Codable, CaseIterable, Sendable {
    case daemon = "mihomo-daemon"
    case agent = "mihomo-agent"
    case mihomo
}

public struct ComponentUpdatePackage: Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var appVersion: String
    public var components: [String: Data]

    public init(appVersion: String, components: [String: Data]) {
        formatVersion = Self.currentFormatVersion
        self.appVersion = appVersion
        self.components = components
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ComponentStatus: Codable, Sendable {
    public var components: [String: String]
    public var installedVersion: String?
    public var updatePending: Bool

    public init(
        components: [String: String],
        installedVersion: String? = nil,
        updatePending: Bool = false
    ) {
        self.components = components
        self.installedVersion = installedVersion
        self.updatePending = updatePending
    }

    enum CodingKeys: String, CodingKey {
        case components
        case installedVersion = "installed_version"
        case updatePending = "update_pending"
    }
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

    public func validated() throws -> Self {
        guard version > 0 else {
            throw ControlError.invalidReply
        }
        guard version == mihomoControlProtocolVersion else {
            throw ControlError.protocolVersionMismatch(
                expected: mihomoControlProtocolVersion,
                received: version
            )
        }
        guard success else {
            throw ControlError.rejected(error ?? "the XPC request was rejected")
        }
        return self
    }
}

public enum ControlError: Error, LocalizedError {
    case unsignedProcess
    case invalidSigningInformation
    case invalidRequirement
    case invalidComponentSignature
    case connectionFailed
    case invalidReply
    case protocolVersionMismatch(expected: Int, received: Int)
    case rejected(String)

    /// Whether this reports the daemon going away rather than refusing.
    ///
    /// A caller that expects the daemon to exit — replacing its own executable,
    /// for instance — needs to tell "it vanished as intended" apart from "it
    /// said no".
    public var isDisconnection: Bool {
        switch self {
        case .connectionFailed, .invalidReply:
            return true
        default:
            return false
        }
    }

    /// Identifies the one incompatible daemon generation that 0.8 must replace
    /// through its verified installer instead of XPC component synchronization.
    public var isLegacyDaemonProtocol: Bool {
        guard case .protocolVersionMismatch(let expected, let received) = self else {
            return false
        }
        return expected == mihomoControlProtocolVersion && received == 1
    }

    public var errorDescription: String? {
        switch self {
        case .unsignedProcess:
            return "the process is not signed by an Apple-issued certificate"
        case .invalidSigningInformation:
            return "code-signing information is unavailable"
        case .invalidRequirement:
            return "the signing-certificate requirement is invalid"
        case .invalidComponentSignature:
            return "the managed component is not signed by the required certificate"
        case .connectionFailed:
            return "the MihomoBox XPC service is unavailable or rejected the client certificate"
        case .invalidReply:
            return "the MihomoBox XPC service returned an invalid response"
        case .protocolVersionMismatch(let expected, let received):
            if expected == mihomoControlProtocolVersion, received == 1 {
                return "the installed MihomoBox daemon must be upgraded with Install / Repair Daemon"
            }
            if received > expected {
                return "the installed MihomoBox daemon is newer than this App; update MihomoBox"
            }
            return "the MihomoBox XPC service uses control protocol version \(received), " +
                "but version \(expected) is required"
        case let .rejected(message):
            return message
        }
    }
}

public enum SigningCertificateRequirement {
    /// The published Developer ID leaf retained during the Xcode Cloud
    /// migration. The first Cloud archive derives its own leaf at runtime and
    /// therefore trusts both that Cloud leaf and this published leaf. Before
    /// the old-signed 0.9.1 bridge is released, the observed Cloud leaf must be
    /// added here as a second explicit pin.
    private static let migrationLeafSHA1s = [
        "2E1EF531C972A15F5B5C58855001FA6FA1186383",
    ]

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
        let hexadecimal = digest.map { String(format: "%02X", $0) }.joined()
        return try certificateFamilyRequirement(currentLeafSHA1: hexadecimal)
    }

    /// Produces a fail-closed Developer ID family requirement for the current
    /// process plus the small, source-pinned migration allowlist. Team ID alone
    /// is deliberately insufficient: every accepted leaf remains explicit.
    public static func certificateFamilyRequirement(currentLeafSHA1: String) throws -> String {
        let normalizedCurrent = try normalizedLeafSHA1(currentLeafSHA1)
        let normalizedMigration = try migrationLeafSHA1s.map(normalizedLeafSHA1)
        let leaves = Array(Set([normalizedCurrent] + normalizedMigration)).sorted()
        let clauses = leaves.map { "certificate leaf = H\"\($0)\"" }
        let leafExpression = clauses.count == 1
            ? clauses[0]
            : "(\(clauses.joined(separator: " or ")))"
        let requirement = "anchor apple generic and \(leafExpression)"
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
              parsed != nil else {
            throw ControlError.invalidRequirement
        }
        return requirement
    }

    private static func normalizedLeafSHA1(_ value: String) throws -> String {
        let normalized = value.uppercased()
        guard normalized.count == 40,
              normalized.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0)
              }) else {
            throw ControlError.invalidRequirement
        }
        return normalized
    }

    public static func validateStaticCode(at url: URL, requirement: String) throws {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
              let parsed else {
            throw ControlError.invalidRequirement
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw ControlError.invalidComponentSignature
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, flags, parsed) == errSecSuccess else {
            throw ControlError.invalidComponentSignature
        }
    }

    /// Freezes one exact signed artifact, not merely its certificate family.
    ///
    /// The CDHash binds the sealed App resources (including the privileged
    /// installer) and prevents a source-path race from substituting another
    /// valid old build signed by the same certificate and identifier.
    public static func exactStaticCodeRequirement(
        at url: URL,
        leafRequirement: String
    ) throws -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw ControlError.invalidComponentSignature
        }
        var designated: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &designated) == errSecSuccess,
              let designated else {
            throw ControlError.invalidRequirement
        }
        var designatedText: CFString?
        guard SecRequirementCopyString(designated, [], &designatedText) == errSecSuccess,
              let designatedText else {
            throw ControlError.invalidRequirement
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any],
            let unique = values[kSecCodeInfoUnique as String] as? Data,
            !unique.isEmpty else {
            throw ControlError.invalidSigningInformation
        }
        let cdhash = unique.map { String(format: "%02x", $0) }.joined()
        let exact = "(\(designatedText as String)) and (\(leafRequirement)) " +
            "and cdhash H\"\(cdhash)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(exact as CFString, [], &parsed) == errSecSuccess,
              parsed != nil else {
            throw ControlError.invalidRequirement
        }
        try validateStaticCode(at: url, requirement: exact)
        return exact
    }
}

public final class MihomoControlSession: @unchecked Sendable {
    private let connection: xpc_connection_t

    public init() throws {
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
        self.connection = connection
    }

    deinit {
        xpc_connection_cancel(connection)
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
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
        return try response.validated()
    }
}

public final class MihomoControlClient: @unchecked Sendable {
    public init() {}

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        try MihomoControlSession().send(request)
    }
}
