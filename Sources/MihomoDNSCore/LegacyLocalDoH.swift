import Foundation

/// Fixed artifacts left by the removed LocalHttpDns feature.
///
/// Its split-DNS configuration profile kept sending matched domains to the
/// HTTPS listener on 127.0.0.1:443, which no longer exists, so the daemon
/// removes the profile, the trust anchor and the identity files once after an
/// upgrade. Uninstall removes the same fixed set.
public enum LegacyLocalDoH {
    public static let profileIdentifier = "dev.linsheng.mihomobox.local-doh"
    public static let identityDirectory = "local-doh"
    public static let preparedProfile = "MihomoBox-Local-DoH.mobileconfig"
    public static let ipcDirectory = "mihomo-data/.dns-ipc"

    /// Interprets `profiles show -type configuration -identifier <id>
    /// -output stdout-xml`. Returns true when the fixed profile is installed,
    /// false when a successful inspection proves it absent, and nil when the
    /// output cannot prove either. Nothing from the output is retained.
    public static func profilePresence(in output: Data) -> Bool? {
        if let root = try? PropertyListSerialization.propertyList(
            from: output, options: [], format: nil
        ) {
            return contains(root)
        }
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "there are no configuration profiles installed"
            || text == "there are no configuration profiles installed in the system domain" {
            return false
        }
        return nil
    }

    private static func contains(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[profileIdentifier] != nil { return true }
            for (key, child) in dictionary {
                if ["payloadidentifier", "profileidentifier", "identifier"]
                    .contains(key.lowercased()),
                   child as? String == profileIdentifier {
                    return true
                }
                if contains(child) { return true }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains(where: contains)
        }
        return false
    }

    /// The trust anchor's SHA-1, as written by the removed feature, when it is
    /// a well-formed 40-digit hexadecimal value.
    public static func storedFingerprint(_ data: Data) -> String? {
        let line = String(decoding: data.prefix(256), as: UTF8.self)
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.count == 40, line.allSatisfy(\.isHexDigit) else { return nil }
        return line.uppercased()
    }
}
