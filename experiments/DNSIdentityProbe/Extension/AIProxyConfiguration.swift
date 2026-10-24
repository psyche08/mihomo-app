import Foundation
import CoreFoundation
import Security
import NetworkExtension

struct AIProxyConfiguration {
    struct Identity {
        let id: String
        let path: String
        let category: String
        let requirement: SecRequirement
    }
    let snapshot: AppProxyIdentitySnapshot?
    let identities: [Identity]
    let deadline: TimeInterval?
    let perApplicationRouting: Bool
    let ports: [String: UInt16]
    let bypass: AppProxyBypassPolicy
    func proxyPort(for category: String) -> UInt16? {
        guard perApplicationRouting else { return 7897 }
        return ports[category]
    }
    enum Invalid: Error { case configuration }
    init(_ raw: [String: Any], now: TimeInterval) throws {
        let keys = Set(raw.keys)
        let routing = raw["routing"] as? String
        let withIdentity = routing == "per-application-v4"
        let withBypass = routing == "per-application-v3" || withIdentity
        perApplicationRouting = routing == "per-application-v1" || routing == "per-application-v2" || withBypass
        let dynamic = routing == "per-application-v2" || withBypass
        guard (keys == ["mode", "targets", "deadline"] || (keys == ["mode", "targets", "deadline", "routing"] && routing == "per-application-v1") ||
               (keys == ["mode", "targets", "deadline", "routing", "ports"] && routing == "per-application-v2") ||
               (keys == ["mode", "targets", "deadline", "routing", "ports", "bypassCIDRs"] && !withIdentity && withBypass) ||
               (keys == ["mode", "targets", "deadline", "routing", "ports", "bypassCIDRs", "identitySnapshot", "rulesDigest"] && withIdentity)), raw["mode"] as? String == "ai",
              let targets = raw["targets"] as? [[String: String]], !targets.isEmpty, targets.count <= 512,
              let number = raw["deadline"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw Invalid.configuration }
        #if MAIN_APP_PROXY
        guard perApplicationRouting else { throw Invalid.configuration }
        #endif
        if withBypass {
            guard let cidrs = raw["bypassCIDRs"] as? [String] else { throw Invalid.configuration }
            bypass = AppProxyBypassPolicy(cidrs: cidrs)
        } else {
            // Old VPN preferences have not installed an explicit bypass policy.
            // The app asks for reactivation instead of guessing an active list.
            bypass = AppProxyBypassPolicy(cidrs: [])
        }
        try bypass.validate()
        let value = number.doubleValue
        guard value == 0 || (value > now && value <= now + 330) else { throw Invalid.configuration }
        deadline = value == 0 ? nil : value
        let builtin: [String: UInt16] = ["chatgpt": 17971, "codex_cli": 17972, "claude": 17973, "claude_cli": 17974]
        if dynamic {
            guard let values = raw["ports"] as? [String: NSNumber], !values.isEmpty, values.count <= 32 else { throw Invalid.configuration }
            var decoded: [String: UInt16] = [:]
            for (id, number) in values {
                guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let port = UInt16(exactly: number.doubleValue) else { throw Invalid.configuration }
                if let fixed = builtin[id] {
                    guard port == fixed else { throw Invalid.configuration }
                } else {
                    guard id.hasPrefix("app_"), UUID(uuidString: String(id.dropFirst(4))) != nil,
                          (17975...18002).contains(port) else { throw Invalid.configuration }
                }
                decoded[id] = port
            }
            guard Set(decoded.values).count == decoded.count else { throw Invalid.configuration }
            ports = decoded
        } else { ports = builtin }
        if withIdentity {
            guard let data = raw["identitySnapshot"] as? Data,
                  let digest = raw["rulesDigest"] as? String, digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Invalid.configuration }
            snapshot = try AppProxyIdentitySnapshot.decode(data)
            guard snapshot?.records.count == targets.count,
                  zip(snapshot!.records, targets).allSatisfy({ identity, target in
                      identity.id == target["id"] && identity.path == target["path"] && identity.category == target["category"] && identity.requirement == target["requirement"]
                  }) else { throw Invalid.configuration }
        } else { snapshot = nil }
        let acceptedCategories = Set(ports.keys).union(["cli_host"])
        identities = try targets.map { record in
            guard Set(record.keys) == ["id", "path", "category", "requirement"],
                  let id = record["id"], !id.isEmpty, id.utf8.count <= 512,
                  let path = record["path"], path.hasPrefix("/"), path.utf8.count <= 4096,
                  AppProxyFileStamp.isCanonicalPath(path),
                  let category = record["category"], acceptedCategories.contains(category),
                  let text = record["requirement"], text.utf8.count <= 8192 else { throw Invalid.configuration }
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { throw Invalid.configuration }
            return Identity(id: id, path: path, category: category, requirement: requirement)
        }
        guard Set(identities.map(\.path)).count == identities.count else { throw Invalid.configuration }
    }

    func classify(_ metadata: NEFlowMetaData) -> String? { try? classifyValidated(metadata) }
    func classifyValidated(_ metadata: NEFlowMetaData) throws -> String {
        guard let token = metadata.sourceAppAuditToken, token.count == 32 else { throw AppProxyIdentityFailure.runtimeIdentity }
        if let snapshot, AppProxyFlowEvidence.word(token, 1) != snapshot.ownerUID { throw AppProxyIdentityFailure.wrongUser }
        let candidates = identities.filter { $0.id == metadata.sourceAppSigningIdentifier }
        guard !candidates.isEmpty else { throw AppProxyIdentityFailure.undiscoveredTarget }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &code) == errSecSuccess,
              let code else { throw AppProxyIdentityFailure.runtimeIdentity }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let executable = values[kSecCodeInfoMainExecutable as String] as? URL,
              values[kSecCodeInfoIdentifier as String] as? String == metadata.sourceAppSigningIdentifier else { throw AppProxyIdentityFailure.runtimeIdentity }
        let path = executable.standardizedFileURL.resolvingSymlinksInPath().path
        if let snapshot {
            guard let record = snapshot.records.first(where: { $0.path == path && $0.id == metadata.sourceAppSigningIdentifier }) else {
                throw AppProxyIdentityFailure.undiscoveredTarget
            }
            guard values[kSecCodeInfoUnique as String] as? Data == record.cdHash else { throw AppProxyIdentityFailure.signature }
            guard try AppProxyFileStamp.read(path) == record.stamp else { throw AppProxyIdentityFailure.changedFile }
        }
        guard let target = candidates.first(where: { $0.path == path }) else { throw AppProxyIdentityFailure.undiscoveredTarget }
        guard SecCodeCheckValidity(code, [], target.requirement) == errSecSuccess else { throw AppProxyIdentityFailure.signature }
        return target.category
    }
}
