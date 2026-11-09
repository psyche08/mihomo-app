import Foundation

/// Which side of the control boundary an authenticated XPC peer is on.
///
/// Every peer already satisfies the Developer ID certificate-family
/// requirement. The App Proxy system extension parses untrusted application
/// traffic, so it is further confined to DNS answers; every other control
/// operation stays with the App and CLI.
public enum ControlPeerRole: String, Equatable, Sendable {
    case controller
    case appProxyExtension = "app_proxy_extension"
}

/// Per-app DNS for App Proxy routes is resolved by the root daemon over XPC,
/// so the extension never opens a socket to the core's DNS listener and is not
/// subject to another product's port-53 interception (for example a DNS Proxy
/// provider that rewrites or drops loopback DNS flows).
public enum AppProxyDNSPolicy {
    public static let extensionIdentifier = "dev.linsheng.mihomo-app.app-proxy"
    /// Bounded in both processes; extra queries fail closed instead of queueing.
    public static let maximumInFlight = 128
    /// The daemon's resolver deadline. The extension waits slightly longer so
    /// the daemon's own failure normally arrives first.
    public static let resolveTimeoutMilliseconds = 4_000
    public static let clientTimeoutMilliseconds = 6_000

    /// Code requirement for the extension: the same certificate family as the
    /// daemon plus the fixed signing identifier.
    public static func extensionRequirement(certificateFamily: String) -> String {
        "(\(certificateFamily)) and identifier \"\(extensionIdentifier)\""
    }

    public static func permits(_ operation: ControlOperation, role: ControlPeerRole) -> Bool {
        switch role {
        case .appProxyExtension:
            return operation == .resolveDNS
        case .controller:
            return operation != .resolveDNS
        }
    }

    /// A standard query (QR=0, OPCODE=QUERY) carrying exactly one question.
    public static func isAcceptableQuery(_ query: Data) -> Bool {
        guard query.count >= 12, query.count <= 65_535 else { return false }
        let header = [UInt8](query.prefix(6))
        return header[2] & 0x80 == 0
            && (header[2] >> 3) & 0x0f == 0
            && header[4] == 0 && header[5] == 1
    }

    /// The answer must carry the query's ID and opcode with QR set. Negative
    /// answers stay valid: they are what the core decided for that name.
    public static func isMatchingResponse(_ response: Data, for query: Data) -> Bool {
        guard response.count >= 12, response.count <= 65_535, query.count >= 12 else {
            return false
        }
        let answer = [UInt8](response.prefix(3))
        let question = [UInt8](query.prefix(3))
        return answer[0] == question[0] && answer[1] == question[1]
            && answer[2] & 0x80 != 0
            && answer[2] & 0x78 == question[2] & 0x78
    }
}
