import Foundation

public struct LocalDoHStatus: Codable, Equatable, Sendable {
    public static let profileIdentifier = "dev.linsheng.mihomobox.local-doh"

    public var serverPrepared: Bool
    public var profileInstalled: Bool
    public var profileInspectionSucceeded: Bool
    public var runtimeHealthy: Bool
    public var certificateTrusted: Bool?
    public var resumeEnhancedTUN: Bool?
    public var systemDNSManaged: Bool?
    public var installedDomainCount: Int
    public var preparedDomainCount: Int
    public var globalDNSFallback: Bool
    public var fallbackProfileRemovalRequired: Bool

    public init(
        serverPrepared: Bool,
        profileInstalled: Bool,
        profileInspectionSucceeded: Bool,
        runtimeHealthy: Bool,
        systemDNSManaged: Bool? = nil,
        installedDomainCount: Int = 0,
        preparedDomainCount: Int = 0,
        globalDNSFallback: Bool = false,
        fallbackProfileRemovalRequired: Bool = false,
        certificateTrusted: Bool? = nil,
        resumeEnhancedTUN: Bool? = nil
    ) {
        self.serverPrepared = serverPrepared
        self.profileInstalled = profileInstalled
        self.profileInspectionSucceeded = profileInspectionSucceeded
        self.runtimeHealthy = runtimeHealthy
        self.certificateTrusted = certificateTrusted
        self.resumeEnhancedTUN = resumeEnhancedTUN
        self.systemDNSManaged = systemDNSManaged
        self.installedDomainCount = installedDomainCount
        self.preparedDomainCount = preparedDomainCount
        self.globalDNSFallback = globalDNSFallback
        self.fallbackProfileRemovalRequired = fallbackProfileRemovalRequired
    }

    enum CodingKeys: String, CodingKey {
        case serverPrepared = "server_prepared"
        case profileInstalled = "profile_installed"
        case profileInspectionSucceeded = "profile_inspection_succeeded"
        case runtimeHealthy = "runtime_healthy"
        case certificateTrusted = "certificate_trusted"
        case resumeEnhancedTUN = "resume_enhanced_tun"
        case systemDNSManaged = "system_dns_managed"
        case installedDomainCount = "installed_domain_count"
        case preparedDomainCount = "prepared_domain_count"
        case globalDNSFallback = "global_dns_fallback"
        case fallbackProfileRemovalRequired = "fallback_profile_removal_required"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverPrepared = try container.decode(Bool.self, forKey: .serverPrepared)
        profileInstalled = try container.decode(Bool.self, forKey: .profileInstalled)
        profileInspectionSucceeded = try container.decode(
            Bool.self,
            forKey: .profileInspectionSucceeded
        )
        runtimeHealthy = try container.decode(Bool.self, forKey: .runtimeHealthy)
        certificateTrusted = try container.decodeIfPresent(Bool.self, forKey: .certificateTrusted)
        resumeEnhancedTUN = try container.decodeIfPresent(Bool.self, forKey: .resumeEnhancedTUN)
        systemDNSManaged = try container.decodeIfPresent(Bool.self, forKey: .systemDNSManaged)
        installedDomainCount = try container.decodeIfPresent(
            Int.self,
            forKey: .installedDomainCount
        ) ?? 0
        preparedDomainCount = try container.decodeIfPresent(
            Int.self,
            forKey: .preparedDomainCount
        ) ?? 0
        globalDNSFallback = try container.decodeIfPresent(Bool.self, forKey: .globalDNSFallback) ?? false
        fallbackProfileRemovalRequired = try container.decodeIfPresent(
            Bool.self, forKey: .fallbackProfileRemovalRequired
        ) ?? false
    }
}

public struct LocalDoHProfileInspection: Equatable, Sendable {
    public var installed: Bool
    public var domainCount: Int

    public init(installed: Bool, domainCount: Int = 0) {
        self.installed = installed
        self.domainCount = domainCount
    }

    /// Presence is independent of certificate/URL validity: an old or stale
    /// profile still owns matching DNS queries and must not look absent.
    public static func presence(in data: Data) -> Bool? {
        if let inspection = inspect(propertyList: data) { return inspection.installed }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "there are no configuration profiles installed"
            || text == "there are no configuration profiles installed in the system domain" {
            return false
        }
        return nil
    }

    /// Reduces `profiles show` output to two non-sensitive values. No profile
    /// payload, domain, organization, or other installed profile metadata
    /// crosses the XPC boundary or reaches a log.
    public static func inspect(propertyList data: Data) -> Self? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else { return nil }

        var found = false
        var domains = Set<String>()
        walk(root) { dictionary in
            if let keyedProfile = dictionary[LocalDoHStatus.profileIdentifier] {
                found = true
                collectDomains(from: keyedProfile, into: &domains)
            }
            let identifier = dictionary.first { key, _ in
                ["payloadidentifier", "profileidentifier", "identifier"]
                    .contains(key.lowercased())
            }?.value as? String
            if identifier == LocalDoHStatus.profileIdentifier {
                found = true
                collectDomains(from: dictionary, into: &domains)
            }
        }
        return Self(installed: found, domainCount: found ? domains.count : 0)
    }

    /// Validates configuration, not TLS trust. `profiles show` redacts the CA
    /// bytes, so that form requires the independently validated prepared
    /// document. The caller must separately evaluate system SSL trust.
    public static func validatedInstalled(
        propertyList data: Data,
        expectedRootCertificate: Data,
        expectedPreparedProfile: Data? = nil
    ) -> Self? {
        guard !expectedRootCertificate.isEmpty,
              let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else { return nil }
        if let profiles = (root as? [String: Any])?["_computerlevel"] as? [[String: Any]] {
            let matches = profiles.filter {
                $0["ProfileIdentifier"] as? String == LocalDoHStatus.profileIdentifier
            }
            if !matches.isEmpty {
                guard matches.count == 1, let prepared = expectedPreparedProfile,
                      let count = LocalDoHProfileDocument.validatedDomainCount(
                        in: prepared, expectedRootCertificate: expectedRootCertificate
                      ),
                      let expected = try? PropertyListSerialization.propertyList(
                        from: prepared, options: [], format: nil
                      ) as? [String: Any],
                      installedReport(matches[0], matches: expected,
                                      certificate: expectedRootCertificate) else { return nil }
                return Self(installed: true, domainCount: count)
            }
        }
        var count: Int?
        walk(root) { dictionary in
            guard count == nil,
                  dictionary["PayloadIdentifier"] as? String
                    == LocalDoHStatus.profileIdentifier,
                  PropertyListSerialization.propertyList(
                    dictionary,
                    isValidFor: .xml
                  ),
                  let candidate = try? PropertyListSerialization.data(
                    fromPropertyList: dictionary,
                    format: .xml,
                    options: 0
                  ) else { return }
            count = LocalDoHProfileDocument.validatedDomainCount(
                in: candidate,
                expectedRootCertificate: expectedRootCertificate
            )
        }
        return count.map { Self(installed: true, domainCount: $0) }
    }

    private static func installedReport(
        _ report: [String: Any], matches expected: [String: Any], certificate: Data
    ) -> Bool {
        guard report["ProfileType"] as? String == expected["PayloadType"] as? String,
              report["ProfileUUID"] as? String == expected["PayloadUUID"] as? String,
              report["ProfileVersion"] as? Int == 1,
              let items = report["ProfileItems"] as? [[String: Any]], items.count == 2,
              let expectedItems = expected["PayloadContent"] as? [[String: Any]] else { return false }
        for item in expectedItems {
            let candidates = items.filter {
                $0["PayloadIdentifier"] as? String == item["PayloadIdentifier"] as? String
            }
            guard candidates.count == 1, let actual = candidates.first,
                  actual["PayloadType"] as? String == item["PayloadType"] as? String,
                  actual["PayloadUUID"] as? String == item["PayloadUUID"] as? String,
                  actual["PayloadVersion"] as? Int == 1 else { return false }
            if item["PayloadType"] as? String == "com.apple.security.root" {
                // macOS reports {} instead of disclosing the certificate.
                if let data = actual["PayloadContent"] as? Data {
                    guard data == certificate else { return false }
                } else {
                    guard let redacted = actual["PayloadContent"] as? [String: Any],
                          redacted.isEmpty else { return false }
                }
            } else {
                guard let content = actual["PayloadContent"] as? [String: Any],
                      Set(content.keys) == ["DNSSettings"],
                      let settings = content["DNSSettings"] as? NSDictionary,
                      let expectedSettings = item["DNSSettings"] as? NSDictionary,
                      settings.isEqual(expectedSettings) else { return false }
            }
        }
        return true
    }

    private static func walk(
        _ value: Any,
        visit: ([String: Any]) -> Void
    ) {
        if let dictionary = value as? [String: Any] {
            visit(dictionary)
            for child in dictionary.values {
                walk(child, visit: visit)
            }
        } else if let array = value as? [Any] {
            for child in array {
                walk(child, visit: visit)
            }
        }
    }

    private static func collectDomains(
        from value: Any,
        into domains: inout Set<String>
    ) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key.caseInsensitiveCompare("SupplementalMatchDomains") == .orderedSame,
                   let values = child as? [String]
                {
                    domains.formUnion(values)
                }
                collectDomains(from: child, into: &domains)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectDomains(from: child, into: &domains)
            }
        }
    }
}
