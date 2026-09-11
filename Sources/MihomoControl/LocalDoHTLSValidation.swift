import Foundation
import Security

/// Reads the system's SSL decision. Supplying the CA as a chain certificate
/// is NOT the same as installing it as a trusted anchor. Never override the
/// trust store, permit an exception, fetch AIA URLs, or write trust settings.
public enum LocalDoHTLSValidation {
    public static func systemTrusts(serverPEM: Data, rootDER: Data) -> Bool {
        guard let pem = String(data: serverPEM, encoding: .utf8),
              let start = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<pem.endIndex),
              let der = Data(base64Encoded: String(pem[start.upperBound..<end.lowerBound])
                .filter { !$0.isWhitespace }),
              let server = SecCertificateCreateWithData(nil, der as CFData),
              let root = SecCertificateCreateWithData(nil, rootDER as CFData) else { return false }
        let policy = SecPolicyCreateSSL(true, "127.0.0.1" as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([server, root] as CFArray, policy, &trust) == errSecSuccess,
              let trust,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let anchor = chain.last else { return false }
        return SecCertificateCopyData(anchor) as Data == rootDER
    }
}

/// A missing/unreadable profile is not evidence of a broken installed
/// resolver. Allow one minute for profile and trust installation to settle.
public struct LocalDoHReadinessRecovery: Sendable {
    private var firstFailure: TimeInterval?
    public init() {}

    public mutating func needsFallback(
        profilePresent: Bool?, ready: Bool, now: TimeInterval
    ) -> Bool {
        guard profilePresent == true, !ready else {
            firstFailure = nil
            return false
        }
        if firstFailure == nil { firstFailure = now }
        return now - (firstFailure ?? now) >= 60
    }
}
