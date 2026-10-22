import Foundation
import MihomoControl

/// Root-owned runtime overlay. Raw subscription/profile bytes are never changed.
public enum AppProxyProfile {
    public static func applying(_ settings: AppProxySettings, to source: String) throws -> String {
        try settings.validate()
        guard !settings.routes.isEmpty else { return source }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Custom Fake-IP ranges must never become direct network destinations.
        // Check before the daemon commits the profile/settings transaction.
        var inDNS = false
        for line in lines {
            if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") {
                inDNS = line.hasPrefix("dns:") || line.hasPrefix("'dns':") || line.hasPrefix("\"dns\":")
            }
            guard inDNS, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if ["fake-ip-range", "fake-ip-range6"].contains(key),
               settings.bypass.overlaps(MihomoConfigurator.parseScalar(String(line[line.index(after: colon)...]))) {
                throw AppProxySettingsError.overlappingFakeIP
            }
        }
        guard lines.filter({ $0 == "---" }).count <= 1, !lines.contains("..."),
              !lines.contains(where: { line in
                  guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                        let colon = line.firstIndex(of: ":") else { return false }
                  let key = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                  return key == "listeners" || key == "<<" || line.hasPrefix("{")
              }),
              // Deliberately conservative for custom ports/ranges. The core
              // validator remains authoritative for the complete YAML.
              !lines.contains(where: { line in
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    && line.contains("port") && settings.applications.contains { line.contains(String($0.port)) }
              }) else { throw AppProxySettingsError.unsupportedProfile }
        var result = source + "\n# MihomoBox App Proxy runtime overlay\nlisteners:\n"
        for app in settings.applications {
            let quoted = String(decoding: try JSONEncoder().encode(settings.routes[app.id]!), as: UTF8.self)
            result += "  - name: mihomobox-app-\(app.id)\n    type: mixed\n    listen: 127.0.0.1\n    port: \(app.port)\n    udp: true\n    proxy: \(quoted)\n"
        }
        return result
    }
}
