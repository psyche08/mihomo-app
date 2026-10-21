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
    let identities: [Identity]
    let deadline: TimeInterval?
    let perApplicationRouting: Bool
    func proxyPort(for category: String) -> UInt16? {
        guard perApplicationRouting else { return 7897 }
        return ["chatgpt": 17971, "codex_cli": 17972, "claude": 17973, "claude_cli": 17974][category]
    }
    enum Invalid: Error { case configuration }
    init(_ raw: [String: Any], now: TimeInterval) throws {
        let keys = Set(raw.keys)
        perApplicationRouting = raw["routing"] as? String == "per-application-v1"
        guard (keys == ["mode", "targets", "deadline"] || (keys == ["mode", "targets", "deadline", "routing"] && perApplicationRouting)), raw["mode"] as? String == "ai",
              let targets = raw["targets"] as? [[String: String]], !targets.isEmpty, targets.count <= 512,
              let number = raw["deadline"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw Invalid.configuration }
        #if MAIN_APP_PROXY
        guard perApplicationRouting else { throw Invalid.configuration }
        #endif
        let value = number.doubleValue
        guard value == 0 || (value > now && value <= now + 330) else { throw Invalid.configuration }
        deadline = value == 0 ? nil : value
        identities = try targets.map { record in
            guard Set(record.keys) == ["id", "path", "category", "requirement"],
                  let id = record["id"], !id.isEmpty, id.utf8.count <= 512,
                  let path = record["path"], path.hasPrefix("/"), path.utf8.count <= 4096,
                  URL(fileURLWithPath: path).standardizedFileURL.path == path,
                  let category = record["category"], ["chatgpt", "claude", "codex_cli", "claude_cli", "cli_host"].contains(category),
                  let text = record["requirement"], text.utf8.count <= 8192 else { throw Invalid.configuration }
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { throw Invalid.configuration }
            return Identity(id: id, path: path, category: category, requirement: requirement)
        }
    }

    func classify(_ metadata: NEFlowMetaData) -> String? {
        guard let token = metadata.sourceAppAuditToken, token.count == 32 else { return nil }
        let candidates = identities.filter { $0.id == metadata.sourceAppSigningIdentifier }
        guard !candidates.isEmpty else { return nil }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: token] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let executable = values[kSecCodeInfoMainExecutable as String] as? URL,
              values[kSecCodeInfoIdentifier as String] as? String == metadata.sourceAppSigningIdentifier else { return nil }
        let path = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return candidates.first {
            $0.path == path && SecCodeCheckValidity(code, [], $0.requirement) == errSecSuccess
        }?.category
    }
}
