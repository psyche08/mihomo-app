// Read-only feasibility probe. This is not a DNS provider and never installs,
// enables, saves, or changes a Network Extension or DNS configuration.
import Darwin
import Foundation
import NetworkExtension
import Security

struct VerifiedOrigin: Equatable {
    let signingIdentifier: String
    let teamIdentifier: String?
}

enum OriginError: Error { case missingToken, invalidToken, lookupFailed, invalidCode, identifierMismatch }

func verifyOrigin(token: Data?, claimedSigningIdentifier: String) throws -> VerifiedOrigin {
    guard let token else { throw OriginError.missingToken }
    guard token.count == MemoryLayout<audit_token_t>.size else { throw OriginError.invalidToken }
    var guest: SecCode?
    let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
          let guest else { throw OriginError.lookupFailed }
    guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { throw OriginError.invalidCode }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess,
          let staticCode else { throw OriginError.invalidCode }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let values = information as? [String: Any],
          let identifier = values[kSecCodeInfoIdentifier as String] as? String,
          !identifier.isEmpty, identifier == claimedSigningIdentifier else { throw OriginError.identifierMismatch }
    return VerifiedOrigin(signingIdentifier: identifier,
                          teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String)
}

// Compiling this adapter verifies the real DNS Proxy flow API surface. It does
// NOT prove which origin macOS supplies for browser, resolver, or helper flows.
func origin(of flow: NEAppProxyFlow) throws -> VerifiedOrigin {
    try verifyOrigin(token: flow.metaData.sourceAppAuditToken,
                     claimedSigningIdentifier: flow.metaData.sourceAppSigningIdentifier)
}

enum DNSRoute: String { case proxy, direct, rejectUnknown }
func route(origin: VerifiedOrigin?, selected: Set<String>, expectedTeam: String) -> DNSRoute {
    guard let origin else { return .rejectUnknown }
    if selected.contains(origin.signingIdentifier) {
        // A matching bundle/signing ID alone is not an authority.
        guard origin.teamIdentifier == expectedTeam else { return .rejectUnknown }
        return .proxy
    }
    return .direct
}

// Prototype partition model only; no DNS cache or query handling is implemented.
struct CachePartition: Hashable {
    let verifiedApplication: String
    let policy: String
    let policyGeneration: UInt64
}

var checks = 0
func check(_ result: Bool, _ label: String) {
    precondition(result, label)
    checks += 1
}
let selected: Set<String> = ["probe.selected"]
check(route(origin: nil, selected: selected, expectedTeam: "TEAM_A") == .rejectUnknown, "unknown identity must not become DIRECT")
check(route(origin: .init(signingIdentifier: "probe.selected", teamIdentifier: "TEAM_A"), selected: selected, expectedTeam: "TEAM_A") == .proxy, "selected identity")
check(route(origin: .init(signingIdentifier: "probe.selected", teamIdentifier: "TEAM_B"), selected: selected, expectedTeam: "TEAM_A") == .rejectUnknown, "same signing ID, wrong team")
check(route(origin: .init(signingIdentifier: "probe.other", teamIdentifier: "TEAM_A"), selected: selected, expectedTeam: "TEAM_A") == .direct, "verified nonselected identity")
let partition = CachePartition(verifiedApplication: "probe.selected", policy: "Proxy", policyGeneration: 1)
check(partition != .init(verifiedApplication: "probe.other", policy: "Proxy", policyGeneration: 1), "separate application caches")
check(partition != .init(verifiedApplication: "probe.selected", policy: "DIRECT", policyGeneration: 1), "separate policy caches")
check(partition != .init(verifiedApplication: "probe.selected", policy: "Proxy", policyGeneration: 2), "invalidate on policy change")
do { _ = try verifyOrigin(token: nil, claimedSigningIdentifier: "probe.selected"); fatalError("missing token accepted") }
catch { checks += 1 }
do { _ = try verifyOrigin(token: Data([0]), claimedSigningIdentifier: "probe.selected"); fatalError("short token accepted") }
catch { checks += 1 }

var token = audit_token_t()
var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
let status = withUnsafeMutablePointer(to: &token) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
    }
}
guard status == KERN_SUCCESS else { fatalError("cannot read own audit token") }
let bytes = withUnsafeBytes(of: token) { Data($0) }
var ownCode: SecCode?
precondition(SecCodeCopySelf([], &ownCode) == errSecSuccess)
var ownStatic: SecStaticCode?
precondition(SecCodeCopyStaticCode(ownCode!, [], &ownStatic) == errSecSuccess)
var ownInformation: CFDictionary?
precondition(SecCodeCopySigningInformation(ownStatic!, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInformation) == errSecSuccess)
let identifier = (ownInformation as! [String: Any])[kSecCodeInfoIdentifier as String] as! String
let verified = try verifyOrigin(token: bytes, claimedSigningIdentifier: identifier)
check(verified.signingIdentifier == identifier, "real current-process audit token lookup")
do { _ = try verifyOrigin(token: bytes, claimedSigningIdentifier: "deliberately.wrong"); fatalError("mismatched signing ID accepted") }
catch { checks += 1 }
let report: [String: Any] = [
    "sdk_flow_metadata_adapter_compiled": true,
    "policy_and_identity_checks_passed": checks,
    "real_self_audit_token_verified": true,
    "dns_provider_activated": false,
    "real_dns_flow_identity_tested": false,
    "system_dns_modified": false,
]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
