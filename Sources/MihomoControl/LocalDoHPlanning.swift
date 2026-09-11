import Darwin
import Foundation

public enum LocalDoHPlanningError: Error, LocalizedError, Equatable, Sendable {
  case requiresRuleMode(String)
  case invalidControllerRules
  case invalidGeoSiteSelector
  case geoSiteListMissing
  case invalidGeoSiteDatabase
  case unmanagedGeoSiteDatabase
  case geoSiteDatabaseTooLarge
  case profileWriteFailed
  case emptyPlan

  public var errorDescription: String? {
    switch self {
    case .requiresRuleMode(let mode):
      return "Local DoH split domains require Rule mode; the current mode is \(mode)."
    case .invalidControllerRules:
      return "the controller rule snapshot is invalid"
    case .invalidGeoSiteSelector:
      return "a proxied GEOSITE selector is invalid"
    case .geoSiteListMissing:
      return "a proxied GEOSITE list is missing from the managed database"
    case .invalidGeoSiteDatabase:
      return "the managed GeoSite database is invalid"
    case .unmanagedGeoSiteDatabase:
      return "the GeoSite database is not a protected root-owned regular file"
    case .geoSiteDatabaseTooLarge:
      return "the managed GeoSite database exceeds the safe parsing limit"
    case .profileWriteFailed:
      return "the root-owned Local DoH profile could not be written safely"
    case .emptyPlan:
      return "no enabled proxy-domain rules can be represented by macOS split DNS"
    }
  }
}

public struct LocalDoHRouteRule: Equatable, Sendable {
  public var type: String
  public var payload: String
  public var target: String
  public var isEnabled: Bool

  public init(type: String, payload: String, target: String, isEnabled: Bool = true) {
    self.type = type
    self.payload = payload
    self.target = target
    self.isEnabled = isEnabled
  }

  public static func decodeControllerCatalog(_ data: Data) throws -> [Self] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawRules = root["rules"]
    else { throw LocalDoHPlanningError.invalidControllerRules }

    let values: [Any]
    if let array = rawRules as? [Any] {
      values = array
    } else if let dictionary = rawRules as? [String: Any] {
      values = dictionary.keys.sorted {
        let left = Int($0) ?? .max
        let right = Int($1) ?? .max
        return left == right ? $0 < $1 : left < right
      }.compactMap { dictionary[$0] }
    } else {
      throw LocalDoHPlanningError.invalidControllerRules
    }

    return try values.map { raw in
      guard let value = raw as? [String: Any],
        let type = value["type"] as? String,
        let payload = value["payload"] as? String,
        let target = value["proxy"] as? String
      else { throw LocalDoHPlanningError.invalidControllerRules }
      let extra = value["extra"] as? [String: Any]
      return Self(
        type: type,
        payload: payload,
        target: target,
        isEnabled: extra?["disabled"] as? Bool != true
      )
    }
  }
}

public struct LocalDoHPlanSummary: Codable, Equatable, Sendable {
  public var domainCount: Int
  public var omittedRuleCount: Int
  public var exactDomainApproximationCount: Int
  public var expandedGeoSiteRuleCount: Int
  public var unrepresentableGeoSiteEntryCount: Int
  public var invertedGeoSiteRuleCount: Int

  public init(
    domainCount: Int,
    omittedRuleCount: Int = 0,
    exactDomainApproximationCount: Int = 0,
    expandedGeoSiteRuleCount: Int = 0,
    unrepresentableGeoSiteEntryCount: Int = 0,
    invertedGeoSiteRuleCount: Int = 0
  ) {
    self.domainCount = domainCount
    self.omittedRuleCount = omittedRuleCount
    self.exactDomainApproximationCount = exactDomainApproximationCount
    self.expandedGeoSiteRuleCount = expandedGeoSiteRuleCount
    self.unrepresentableGeoSiteEntryCount = unrepresentableGeoSiteEntryCount
    self.invertedGeoSiteRuleCount = invertedGeoSiteRuleCount
  }

  enum CodingKeys: String, CodingKey {
    case domainCount = "domain_count"
    case omittedRuleCount = "omitted_rule_count"
    case exactDomainApproximationCount = "exact_domain_approximation_count"
    case expandedGeoSiteRuleCount = "expanded_geosite_rule_count"
    case unrepresentableGeoSiteEntryCount = "unrepresentable_geosite_entry_count"
    case invertedGeoSiteRuleCount = "inverted_geosite_rule_count"
  }
}

public struct LocalDoHDomainPlan: Equatable, Sendable {
  public var domains: [String]
  public var omittedRules: Int
  public var exactDomainApproximations: Int
  public var expandedGeoSiteRules: Int
  public var unrepresentableGeoSiteEntries: Int
  public var invertedGeoSiteRules: Int

  public init(
    domains: [String],
    omittedRules: Int = 0,
    exactDomainApproximations: Int = 0,
    expandedGeoSiteRules: Int = 0,
    unrepresentableGeoSiteEntries: Int = 0,
    invertedGeoSiteRules: Int = 0
  ) {
    self.domains = domains
    self.omittedRules = omittedRules
    self.exactDomainApproximations = exactDomainApproximations
    self.expandedGeoSiteRules = expandedGeoSiteRules
    self.unrepresentableGeoSiteEntries = unrepresentableGeoSiteEntries
    self.invertedGeoSiteRules = invertedGeoSiteRules
  }

  public var summary: LocalDoHPlanSummary {
    LocalDoHPlanSummary(
      domainCount: domains.count,
      omittedRuleCount: omittedRules,
      exactDomainApproximationCount: exactDomainApproximations,
      expandedGeoSiteRuleCount: expandedGeoSiteRules,
      unrepresentableGeoSiteEntryCount: unrepresentableGeoSiteEntries,
      invertedGeoSiteRuleCount: invertedGeoSiteRules
    )
  }

  public static func build(
    from rules: [LocalDoHRouteRule],
    routeSnapshot: ControllerRouteSnapshot,
    geoSiteDatabase: GeoSiteDatabase? = nil
  ) throws -> Self {
    var candidates: [String] = []
    var omitted = 0
    var exact = 0
    var expandedGeoSite = 0
    var unrepresentableGeoSite = 0
    var invertedGeoSite = 0

    for rule in rules where rule.isEnabled
      && routeSnapshot.routesThroughRemoteProxy(rule.target)
    {
      switch normalizedRuleType(rule.type) {
      case "DOMAINSUFFIX":
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
        candidates.append(domain)
        exact += 1
      case "GEOSITE":
        guard let geoSiteDatabase else {
          omitted += 1
          continue
        }
        let selector = try GeoSiteSelector(rule.payload)
        if selector.inverted {
          // A finite SupplementalMatchDomains list cannot express the
          // complement of a GeoSite set. Omit it without widening DNS scope.
          omitted += 1
          invertedGeoSite += 1
          continue
        }
        let entries = try geoSiteDatabase.entries(for: selector)
        expandedGeoSite += 1
        for entry in entries {
          switch entry.type {
          case .rootDomain:
            if let domain = normalizedDomain(entry.value) {
              candidates.append(domain)
            } else {
              unrepresentableGeoSite += 1
            }
          case .full:
            if let domain = normalizedDomain(entry.value) {
              // Apple's split-DNS payload is suffix based. This deliberately
              // widens an exact host to its subdomains, matching the existing
              // treatment of controller DOMAIN rules.
              candidates.append(domain)
              exact += 1
            } else {
              unrepresentableGeoSite += 1
            }
          case .plain, .regex, .unknown:
            unrepresentableGeoSite += 1
          }
        }
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
    var accepted = Set<String>()
    collapsed.reserveCapacity(unique.count)
    for candidate in unique {
      var suffix = candidate
      var shadowed = false
      while let dot = suffix.firstIndex(of: ".") {
        suffix = String(suffix[suffix.index(after: dot)...])
        if accepted.contains(suffix) {
          shadowed = true
          break
        }
      }
      guard !shadowed else { continue }
      collapsed.append(candidate)
      accepted.insert(candidate)
    }
    guard !collapsed.isEmpty else { throw LocalDoHPlanningError.emptyPlan }
    return Self(
      domains: collapsed,
      omittedRules: omitted,
      exactDomainApproximations: exact,
      expandedGeoSiteRules: expandedGeoSite,
      unrepresentableGeoSiteEntries: unrepresentableGeoSite,
      invertedGeoSiteRules: invertedGeoSite
    )
  }

  private static func normalizedRuleType(_ value: String) -> String {
    value.uppercased().filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }
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
  public static let identifier = LocalDoHStatus.profileIdentifier
  public static let serverURL = "https://127.0.0.1/dns-query"
  public static let rootCertificatePayloadIdentifier = "\(identifier).root-ca"
  public static let managedProfilePath =
    "/Library/Application Support/Mihomo App/MihomoBox-Local-DoH.mobileconfig"

  public static func data(
    for plan: LocalDoHDomainPlan,
    rootCertificate: Data
  ) throws -> Data {
    guard !plan.domains.isEmpty else { throw LocalDoHPlanningError.emptyPlan }
    guard !rootCertificate.isEmpty, rootCertificate.count <= 128 * 1_024 else {
      throw LocalDoHPlanningError.profileWriteFailed
    }
    let certificatePayload: [String: Any] = [
      "PayloadType": "com.apple.security.root",
      "PayloadVersion": 1,
      "PayloadIdentifier": rootCertificatePayloadIdentifier,
      "PayloadUUID": "B9192423-380F-49AD-AF98-545B076985CB",
      "PayloadDisplayName": "MihomoBox Local DoH Root CA",
      "PayloadCertificateFileName": "MihomoBox-Local-DoH-Root-CA.cer",
      "PayloadContent": rootCertificate,
    ]
    var dnsPayload: [String: Any] = [
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
    if plan.domains == [""] {
      var settings = dnsPayload["DNSSettings"] as! [String: Any]
      settings.removeValue(forKey: "SupplementalMatchDomains")
      dnsPayload["DNSSettings"] = settings
    }
    let profile: [String: Any] = [
      "PayloadType": "Configuration",
      "PayloadVersion": 1,
      "PayloadIdentifier": identifier,
      "PayloadUUID": "EB76D427-128C-4F94-BD19-8937D352899B",
      "PayloadDisplayName": "MihomoBox Local DoH",
      "PayloadDescription":
        "Routes DNS queries to MihomoBox over local HTTPS. Mihomo determines the DNS response using the active profile.",
      "PayloadOrganization": "MihomoBox",
      "PayloadScope": "System",
      "PayloadRemovalDisallowed": false,
      // The manually installed profile is the macOS authorization boundary:
      // it installs both the root CA and the DNS settings together.
      // Manual installation may leave SSL trust unspecified; the daemon must
      // evaluate native system SSL trust separately before enabling TUN.
      // The root LaunchDaemon never edits Admin Trust Settings directly.
      "PayloadContent": [certificatePayload, dnsPayload],
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: profile,
      format: .xml,
      options: 0
    )
  }

  /// Validates the exact root-prepared artifact before any privileged runtime
  /// mutation. Returning only a count keeps the expanded domain list inside
  /// the root boundary.
  public static func validatedDomainCount(
    in data: Data,
    expectedRootCertificate: Data? = nil
  ) -> Int? {
    guard let profile = try? PropertyListSerialization.propertyList(
      from: data,
      options: [],
      format: nil
    ) as? [String: Any],
      profile["PayloadIdentifier"] as? String == identifier,
      profile["PayloadType"] as? String == "Configuration",
      profile["PayloadScope"] as? String == "System",
      let content = profile["PayloadContent"] as? [[String: Any]],
      content.count == 2,
      let certificatePayload = content.first(where: {
        $0["PayloadIdentifier"] as? String == rootCertificatePayloadIdentifier
      }),
      certificatePayload["PayloadType"] as? String == "com.apple.security.root",
      certificatePayload["PayloadCertificateFileName"] as? String
        == "MihomoBox-Local-DoH-Root-CA.cer",
      let rootCertificate = certificatePayload["PayloadContent"] as? Data,
      !rootCertificate.isEmpty,
      rootCertificate.count <= 128 * 1_024,
      expectedRootCertificate.map({ $0 == rootCertificate }) ?? true,
      let dnsPayload = content.first(where: {
        $0["PayloadIdentifier"] as? String == "\(identifier).dns"
      }),
      dnsPayload["PayloadType"] as? String == "com.apple.dnsSettings.managed",
      let settings = dnsPayload["DNSSettings"] as? [String: Any],
      settings["DNSProtocol"] as? String == "HTTPS",
      settings["ServerURL"] as? String == serverURL,
      settings["ServerAddresses"] as? [String] == ["127.0.0.1"]
    else { return nil }
    if settings["SupplementalMatchDomains"] == nil { return 1 }
    guard let domains = settings["SupplementalMatchDomains"] as? [String],
      !domains.isEmpty,
      domains.allSatisfy({ !$0.isEmpty && $0 != "." })
    else { return nil }
    return Set(domains).count
  }
}

public struct GeoSiteDatabase: Sendable {
  public enum DomainType: Equatable, Sendable {
    case plain
    case regex
    case rootDomain
    case full
    case unknown
  }

  public struct Entry: Equatable, Sendable {
    public var type: DomainType
    public var value: String
    public var attributes: Set<String>

    public init(type: DomainType, value: String, attributes: Set<String> = []) {
      self.type = type
      self.value = value
      self.attributes = attributes
    }
  }

  private static let maximumBytes = 64 * 1_024 * 1_024
  private static let maximumEntries = 2_000_000
  private var sites: [String: [Entry]]

  public init(sites: [String: [Entry]]) {
    self.sites = sites.reduce(into: [:]) { result, pair in
      let key = pair.key.lowercased()
      if result[key] == nil { result[key] = pair.value }
    }
  }

  public static func loadManaged(path: String) throws -> Self {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw LocalDoHPlanningError.unmanagedGeoSiteDatabase }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == 0,
      metadata.st_gid == 0,
      metadata.st_mode & 0o022 == 0,
      metadata.st_size > 0
    else { throw LocalDoHPlanningError.unmanagedGeoSiteDatabase }
    guard metadata.st_size <= maximumBytes else {
      throw LocalDoHPlanningError.geoSiteDatabaseTooLarge
    }

    var data = Data(count: Int(metadata.st_size))
    let readCount = data.withUnsafeMutableBytes { rawBuffer -> Int in
      guard let base = rawBuffer.baseAddress else { return 0 }
      var offset = 0
      while offset < rawBuffer.count {
        let count = Darwin.read(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          return -1
        }
        if count == 0 { break }
        offset += count
      }
      return offset
    }
    guard readCount == data.count else { throw LocalDoHPlanningError.invalidGeoSiteDatabase }
    return try decode(data)
  }

  public static func decode(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= maximumBytes else {
      throw data.count > maximumBytes
        ? LocalDoHPlanningError.geoSiteDatabaseTooLarge
        : LocalDoHPlanningError.invalidGeoSiteDatabase
    }
    var reader = ProtobufReader(data)
    var sites: [String: [Entry]] = [:]
    var totalEntries = 0
    while !reader.isAtEnd {
      let field = try reader.readField()
      if field.number == 1, field.wireType == 2 {
        let siteData = try reader.readLengthDelimited()
        let site = try decodeSite(siteData)
        totalEntries += site.entries.count
        guard totalEntries <= maximumEntries else {
          throw LocalDoHPlanningError.invalidGeoSiteDatabase
        }
        let key = site.code.lowercased()
        if sites[key] == nil { sites[key] = site.entries }
      } else {
        try reader.skip(wireType: field.wireType)
      }
    }
    guard !sites.isEmpty else { throw LocalDoHPlanningError.invalidGeoSiteDatabase }
    return Self(sites: sites)
  }

  fileprivate func entries(for selector: GeoSiteSelector) throws -> [Entry] {
    guard let entries = sites[selector.list] else {
      throw LocalDoHPlanningError.geoSiteListMissing
    }
    guard !selector.attributes.isEmpty else { return entries }
    return entries.filter { selector.attributes.isSubset(of: $0.attributes) }
  }

  private static func decodeSite(_ data: Data) throws -> (code: String, entries: [Entry]) {
    var reader = ProtobufReader(data)
    var code: String?
    var entries: [Entry] = []
    while !reader.isAtEnd {
      let field = try reader.readField()
      switch (field.number, field.wireType) {
      case (1, 2): code = try reader.readString()
      case (2, 2): entries.append(try decodeDomain(reader.readLengthDelimited()))
      default: try reader.skip(wireType: field.wireType)
      }
    }
    guard let code, !code.isEmpty else { throw LocalDoHPlanningError.invalidGeoSiteDatabase }
    return (code, entries)
  }

  private static func decodeDomain(_ data: Data) throws -> Entry {
    var reader = ProtobufReader(data)
    var rawType: UInt64 = 0
    var value = ""
    var attributes = Set<String>()
    while !reader.isAtEnd {
      let field = try reader.readField()
      switch (field.number, field.wireType) {
      case (1, 0): rawType = try reader.readVarint()
      case (2, 2): value = try reader.readString()
      case (3, 2):
        if let attribute = try decodeAttribute(reader.readLengthDelimited()) {
          attributes.insert(attribute.lowercased())
        }
      default: try reader.skip(wireType: field.wireType)
      }
    }
    let type: DomainType
    switch rawType {
    case 0: type = .plain
    case 1: type = .regex
    case 2: type = .rootDomain
    case 3: type = .full
    default: type = .unknown
    }
    return Entry(type: type, value: value, attributes: attributes)
  }

  private static func decodeAttribute(_ data: Data) throws -> String? {
    var reader = ProtobufReader(data)
    var key: String?
    while !reader.isAtEnd {
      let field = try reader.readField()
      if field.number == 1, field.wireType == 2 {
        key = try reader.readString()
      } else {
        try reader.skip(wireType: field.wireType)
      }
    }
    return key
  }
}

private struct GeoSiteSelector {
  var list: String
  var attributes: Set<String>
  var inverted: Bool

  init(_ rawValue: String) throws {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix("geosite:") { value.removeFirst("geosite:".count) }
    inverted = value.hasPrefix("!")
    if inverted { value.removeFirst() }
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let first = parts.first, !first.isEmpty,
      parts.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
    else { throw LocalDoHPlanningError.invalidGeoSiteSelector }
    list = first
    attributes = Set(parts.dropFirst())
  }
}

private struct ProtobufReader {
  struct Field {
    var number: Int
    var wireType: Int
  }

  private let data: Data
  private var index = 0

  init(_ data: Data) { self.data = data }
  var isAtEnd: Bool { index == data.count }

  mutating func readField() throws -> Field {
    let key = try readVarint()
    let number = Int(key >> 3)
    let wireType = Int(key & 0x07)
    guard number > 0, [0, 1, 2, 5].contains(wireType) else {
      throw LocalDoHPlanningError.invalidGeoSiteDatabase
    }
    return Field(number: number, wireType: wireType)
  }

  mutating func readVarint() throws -> UInt64 {
    var value: UInt64 = 0
    for shift in stride(from: 0, through: 63, by: 7) {
      guard index < data.count else { throw LocalDoHPlanningError.invalidGeoSiteDatabase }
      let byte = data[index]
      index += 1
      if shift == 63, byte > 1 { throw LocalDoHPlanningError.invalidGeoSiteDatabase }
      value |= UInt64(byte & 0x7f) << UInt64(shift)
      if byte & 0x80 == 0 { return value }
    }
    throw LocalDoHPlanningError.invalidGeoSiteDatabase
  }

  mutating func readLengthDelimited() throws -> Data {
    let rawLength = try readVarint()
    guard rawLength <= UInt64(Int.max) else {
      throw LocalDoHPlanningError.invalidGeoSiteDatabase
    }
    let length = Int(rawLength)
    guard length <= data.count - index else {
      throw LocalDoHPlanningError.invalidGeoSiteDatabase
    }
    defer { index += length }
    return data.subdata(in: index..<(index + length))
  }

  mutating func readString() throws -> String {
    guard let value = String(data: try readLengthDelimited(), encoding: .utf8) else {
      throw LocalDoHPlanningError.invalidGeoSiteDatabase
    }
    return value
  }

  mutating func skip(wireType: Int) throws {
    switch wireType {
    case 0: _ = try readVarint()
    case 1: try advance(8)
    case 2: _ = try readLengthDelimited()
    case 5: try advance(4)
    default: throw LocalDoHPlanningError.invalidGeoSiteDatabase
    }
  }

  private mutating func advance(_ count: Int) throws {
    guard count <= data.count - index else {
      throw LocalDoHPlanningError.invalidGeoSiteDatabase
    }
    index += count
  }
}
