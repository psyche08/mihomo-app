import Foundation

public struct LocalDoHStatus: Codable, Equatable, Sendable {
    public static let profileIdentifier = "dev.linsheng.mihomobox.local-doh"

    public var serverPrepared: Bool
    public var profileInstalled: Bool
    public var profileInspectionSucceeded: Bool
    public var runtimeHealthy: Bool
    public var systemDNSManaged: Bool?
    public var installedDomainCount: Int
    public var preparedDomainCount: Int

    public init(
        serverPrepared: Bool,
        profileInstalled: Bool,
        profileInspectionSucceeded: Bool,
        runtimeHealthy: Bool,
        systemDNSManaged: Bool? = nil,
        installedDomainCount: Int = 0,
        preparedDomainCount: Int = 0
    ) {
        self.serverPrepared = serverPrepared
        self.profileInstalled = profileInstalled
        self.profileInspectionSucceeded = profileInspectionSucceeded
        self.runtimeHealthy = runtimeHealthy
        self.systemDNSManaged = systemDNSManaged
        self.installedDomainCount = installedDomainCount
        self.preparedDomainCount = preparedDomainCount
    }

    enum CodingKeys: String, CodingKey {
        case serverPrepared = "server_prepared"
        case profileInstalled = "profile_installed"
        case profileInspectionSucceeded = "profile_inspection_succeeded"
        case runtimeHealthy = "runtime_healthy"
        case systemDNSManaged = "system_dns_managed"
        case installedDomainCount = "installed_domain_count"
        case preparedDomainCount = "prepared_domain_count"
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
        systemDNSManaged = try container.decodeIfPresent(Bool.self, forKey: .systemDNSManaged)
        installedDomainCount = try container.decodeIfPresent(
            Int.self,
            forKey: .installedDomainCount
        ) ?? 0
        preparedDomainCount = try container.decodeIfPresent(
            Int.self,
            forKey: .preparedDomainCount
        ) ?? 0
    }
}

public struct LocalDoHProfileInspection: Equatable, Sendable {
    public var installed: Bool
    public var domainCount: Int

    public init(installed: Bool, domainCount: Int = 0) {
        self.installed = installed
        self.domainCount = domainCount
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
