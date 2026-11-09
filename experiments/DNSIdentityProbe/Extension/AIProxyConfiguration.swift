import Foundation
import CoreFoundation
import Security
import NetworkExtension

/// The provider's view of one saved policy generation. The OS rules divert the listed signing
/// identifiers; each flow is routed by the Team ID of its running code.
struct AIProxyConfiguration {
    static let routing = "per-application-v5"
    struct Route {
        let route: AppProxyPolicy.Route
        let requirement: SecRequirement
    }
    let policy: AppProxyPolicy
    let routes: [Route]
    let ports: [String: UInt16]
    let bypass: AppProxyBypassPolicy
    func proxyPort(for category: String) -> UInt16? { ports[category] }
    enum Invalid: Error { case configuration }

    static let builtinPorts: [String: UInt16] = ["jetbrains": 17970, "chatgpt": 17971, "codex_cli": 17972,
                                                 "claude": 17973, "claude_cli": 17974]

    init(_ raw: [String: Any]) throws {
        guard Set(raw.keys) == ["mode", "routing", "policy", "rulesDigest", "bypassCIDRs", "ports"],
              raw["mode"] as? String == "ai", raw["routing"] as? String == Self.routing,
              let cidrs = raw["bypassCIDRs"] as? [String],
              let digest = raw["rulesDigest"] as? String, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let data = raw["policy"] as? Data,
              let values = raw["ports"] as? [String: NSNumber], !values.isEmpty, values.count <= 32 else { throw Invalid.configuration }
        bypass = AppProxyBypassPolicy(cidrs: cidrs)
        try bypass.validate()
        var decoded: [String: UInt16] = [:]
        for (id, number) in values {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let port = UInt16(exactly: number.doubleValue) else { throw Invalid.configuration }
            if let fixed = Self.builtinPorts[id] {
                guard port == fixed else { throw Invalid.configuration }
            } else {
                guard id.hasPrefix("app_"), UUID(uuidString: String(id.dropFirst(4))) != nil,
                      (17975...18002).contains(port) else { throw Invalid.configuration }
            }
            decoded[id] = port
        }
        guard Set(decoded.values).count == decoded.count else { throw Invalid.configuration }
        ports = decoded
        policy = try AppProxyPolicy.decode(data)
        guard policy.routes.allSatisfy({ decoded[$0.category] != nil }) else { throw Invalid.configuration }
        routes = try policy.routes.map { route in
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(route.requirement as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { throw Invalid.configuration }
            return Route(route: route, requirement: requirement)
        }
    }

    func identify(_ metadata: NEFlowMetaData) -> (category: String, path: String)? { try? identifyValidated(metadata) }
    /// The route and the executable path of the process behind a flow: its running code must
    /// carry a listed signing identifier and be signed by that route's Team ID.
    func identifyValidated(_ metadata: NEFlowMetaData) throws -> (category: String, path: String) {
        guard let token = metadata.sourceAppAuditToken, token.count == 32 else { throw AppProxyIdentityFailure.runtimeIdentity }
        guard AppProxyFlowEvidence.word(token, 1) == policy.ownerUID else { throw AppProxyIdentityFailure.wrongUser }
        let identifier = metadata.sourceAppSigningIdentifier
        guard routes.contains(where: { $0.route.identifiers.contains(identifier) }) else { throw AppProxyIdentityFailure.undiscoveredTarget }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &code) == errSecSuccess,
              let code else { throw AppProxyIdentityFailure.runtimeIdentity }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let executable = values[kSecCodeInfoMainExecutable as String] as? URL,
              values[kSecCodeInfoIdentifier as String] as? String == identifier else { throw AppProxyIdentityFailure.runtimeIdentity }
        guard let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let match = routes.first(where: { $0.route.teams.contains(team) && $0.route.identifiers.contains(identifier) }) else {
            throw AppProxyIdentityFailure.undiscoveredTarget
        }
        // The kernel's view of the running process, not the file: anchor, Team ID and validity.
        guard SecCodeCheckValidity(code, [], match.requirement) == errSecSuccess else { throw AppProxyIdentityFailure.signature }
        return (match.route.category, executable.standardizedFileURL.resolvingSymlinksInPath().path)
    }
}
