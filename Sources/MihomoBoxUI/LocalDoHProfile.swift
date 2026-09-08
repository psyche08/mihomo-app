import Foundation

public struct LocalDoHDomainPlan: Equatable, Sendable {
  public static let maximumDomains = 4_096

  public var domains: [String]
  public var omittedRules: Int
  public var exactDomainApproximations: Int
  public var truncatedDomains: Int

  public init(
    domains: [String],
    omittedRules: Int = 0,
    exactDomainApproximations: Int = 0,
    truncatedDomains: Int = 0
  ) {
    self.domains = domains
    self.omittedRules = omittedRules
    self.exactDomainApproximations = exactDomainApproximations
    self.truncatedDomains = truncatedDomains
  }

  public static func build(from rules: [DashboardRule]) -> Self {
    var candidates: [String] = []
    var omitted = 0
    var exact = 0
    for rule in rules where rule.isEnabled && isProxyTarget(rule.target) {
      switch rule.type.uppercased() {
      case "DOMAIN-SUFFIX":
        guard let domain = normalizedDomain(rule.payload) else {
          omitted += 1
          continue
        }
        candidates.append(domain)
      case "DOMAIN":
        guard let domain = normalizedDomain(rule.payload) else {
          omitted += 1
          continue
        }
        // Apple's SupplementalMatchDomains uses suffix matching. Treating an
        // exact Mihomo DOMAIN as a suffix is explicit in the UI summary and is
        // safer than silently losing its subdomain lookups to cleartext DNS.
        candidates.append(domain)
        exact += 1
      default:
        omitted += 1
      }
    }

    let unique = Array(Set(candidates)).sorted {
      let leftLabels = $0.split(separator: ".").count
      let rightLabels = $1.split(separator: ".").count
      return leftLabels == rightLabels ? $0 < $1 : leftLabels < rightLabels
    }
    var collapsed: [String] = []
    for candidate in unique {
      guard !collapsed.contains(where: {
        candidate == $0 || candidate.hasSuffix(".\($0)")
      }) else { continue }
      collapsed.append(candidate)
    }
    let truncated = max(0, collapsed.count - maximumDomains)
    return Self(
      domains: Array(collapsed.prefix(maximumDomains)),
      omittedRules: omitted,
      exactDomainApproximations: exact,
      truncatedDomains: truncated
    )
  }

  private static func isProxyTarget(_ value: String) -> Bool {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "", "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE":
      return false
    default:
      return true
    }
  }

  private static func normalizedDomain(_ value: String) -> String? {
    var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while domain.hasSuffix(".") { domain.removeLast() }
    if domain.hasPrefix("+.") || domain.hasPrefix("*.") {
      domain.removeFirst(2)
    }
    guard !domain.isEmpty, domain.utf8.count <= 253,
      !domain.hasPrefix("."), !domain.hasSuffix("."), domain.contains("."),
      domain.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").contains($0)
      })
    else { return nil }
    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ label in
      !label.isEmpty && label.utf8.count <= 63
        && label.first != "-" && label.last != "-"
    }) else { return nil }
    return domain
  }
}

public enum LocalDoHProfileDocument {
  public static let identifier = "dev.linsheng.mihomobox.local-doh"
  public static let serverURL = "https://127.0.0.1:9443/dns-query"
  public static let deviceManagementURL = URL(
    string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
  )!

  public static func data(for plan: LocalDoHDomainPlan) throws -> Data {
    guard !plan.domains.isEmpty else {
      throw NSError(
        domain: "MihomoBoxLocalDoH",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "No enabled DOMAIN or DOMAIN-SUFFIX proxy rules can be represented by macOS split DNS."
        ]
      )
    }
    let dnsPayload: [String: Any] = [
      "PayloadType": "com.apple.dnsSettings.managed",
      "PayloadVersion": 1,
      "PayloadIdentifier": "\(identifier).dns",
      "PayloadUUID": "9D49DE6B-77E6-4D2A-93D2-685A8F9F8B12",
      "PayloadDisplayName": "MihomoBox Local DoH",
      "DNSSettings": [
        "DNSProtocol": "HTTPS",
        "ServerURL": serverURL,
        "ServerAddresses": ["127.0.0.1"],
        "SupplementalMatchDomains": plan.domains,
      ],
    ]
    let profile: [String: Any] = [
      "PayloadType": "Configuration",
      "PayloadVersion": 1,
      "PayloadIdentifier": identifier,
      "PayloadUUID": "EB76D427-128C-4F94-BD19-8937D352899B",
      "PayloadDisplayName": "MihomoBox Local DoH",
      "PayloadDescription":
        "Routes selected proxy-domain DNS queries to MihomoBox over local HTTPS. Other domains keep using the current macOS default DNS.",
      "PayloadOrganization": "MihomoBox",
      "PayloadScope": "System",
      "PayloadRemovalDisallowed": false,
      "PayloadContent": [dnsPayload],
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: profile,
      format: .xml,
      options: 0
    )
  }
}

public struct DashboardLocalDoHStatus: Equatable, Sendable {
  public var available: Bool
  public var prepared: Bool
  public var installedDomainCount: Int

  public init(available: Bool, prepared: Bool, installedDomainCount: Int = 0) {
    self.available = available
    self.prepared = prepared
    self.installedDomainCount = installedDomainCount
  }
}

@MainActor
public protocol DashboardLocalDoHService: AnyObject {
  func status() async -> DashboardLocalDoHStatus
  func prepare(plan: LocalDoHDomainPlan) async throws
  func openDeviceManagement() async throws
  func remove() async throws
}
