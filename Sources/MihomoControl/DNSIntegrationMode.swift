import Foundation

/// DNS ownership, independent of Mihomo's rule/global/direct outbound mode.
public enum DNSIntegrationMode: String, Codable, CaseIterable, Sendable {
    case globalDNS = "global-dns"
    case localDoH = "local-doh"
}

/// Fixed, user-initiated trust operation. No caller-supplied paths or policies.
/// The helper validates the protected identity before invoking this command.
public enum LocalDoHTrustCommand {
    public static let executable = "/usr/bin/security"
    public static let arguments = [
        "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl",
        "-k", "/Library/Keychains/System.keychain",
        "/Library/Application Support/Mihomo App/local-doh/ca.der",
    ]
    public static let timeout: TimeInterval = 120
}
