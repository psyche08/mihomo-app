import Foundation

/// DNS ownership, independent of Mihomo's rule/global/direct outbound mode.
public enum DNSIntegrationMode: String, Codable, CaseIterable, Sendable {
    case globalDNS = "global-dns"
    case localDoH = "local-doh"
}

/// Missing DoH prerequisites select the verified Global DNS transaction, never
/// block Enhanced TUN or silently initiate certificate/profile authorization.
public enum EnhancedDNSSelection {
    public static func useLocalDoH(profileVerified: Bool, identityPrepared: Bool,
                                  certificateTrusted: Bool, listenerRunning: Bool) -> Bool {
        profileVerified && identityPrepared && certificateTrusted && listenerRunning
    }
}
