import Foundation
import Security

/// Runs inside the signed GUI process so macOS can present administrator
/// authorization. The helper imports only its validated fixed CA; the GUI
/// receives public DER over authenticated XPC, never a key or caller path.
enum LocalDoHCertificateTrust {
  static func settings() -> [String: Any] {
    [
      kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
      kSecTrustSettingsPolicyString as String: "127.0.0.1",
      kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue,
    ]
  }

  static func authorize(_ der: Data) async throws {
    // Keep the App's main run loop available throughout the system prompt.
    try await Task.detached(priority: .userInitiated) {
      guard !der.isEmpty, der.count <= 16_384,
            let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
        throw NSError(domain: "MihomoBoxLocalDoH", code: 6,
          userInfo: [NSLocalizedDescriptionKey: "The helper returned an invalid CA certificate."])
      }
      let result = SecTrustSettingsSetTrustSettings(certificate, .admin, settings() as CFDictionary)
      guard result == errSecSuccess else {
        if result == errSecUserCanceled { throw CancellationError() }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: [
          NSLocalizedDescriptionKey: "macOS did not approve Local DoH SSL trust (OSStatus \(result)). "
            + "Approve the system authorization dialog, or review the certificate in Keychain Access."
        ])
      }
    }.value
  }
}
