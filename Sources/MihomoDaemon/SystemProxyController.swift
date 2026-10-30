import Foundation
import Darwin
import SystemConfiguration

/// Only fixed loopback HTTP/HTTPS/SOCKS settings cross the privileged boundary.
/// Original settings are root-owned; never log their contents (PAC URLs may be private).
final class SystemProxyController {
    private let backupURL: URL
    private let lock = NSLock()
    init(configPath: String) {
        backupURL = URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("system-proxy-backup.plist")
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "MihomoBox.SystemProxy", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
    private func preferences() throws -> SCPreferences {
        guard let p = SCPreferencesCreate(nil, "MihomoBox System Proxy" as CFString, nil) else { throw failure("System proxy preferences are unavailable") }
        return p
    }
    private func services(_ p: SCPreferences, includeDisabled: Bool = false) throws -> [(String, SCNetworkProtocol)] {
        guard let set = SCNetworkSetCopyCurrent(p), let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { throw failure("No current network services") }
        return services.compactMap { service in
            guard (includeDisabled || SCNetworkServiceGetEnabled(service)), let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface),
                  [kSCNetworkInterfaceTypeEthernet as String, kSCNetworkInterfaceTypeIEEE80211 as String].contains(type as String),
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  let id = SCNetworkServiceGetServiceID(service) else { return nil }
            return (id as String, proto)
        }
    }
    static func patch(port: Int) -> [String: Any] {
        ["HTTPEnable":1, "HTTPProxy":"127.0.0.1", "HTTPPort":port,
         "HTTPSEnable":1, "HTTPSProxy":"127.0.0.1", "HTTPSPort":port,
         "SOCKSEnable":1, "SOCKSProxy":"127.0.0.1", "SOCKSPort":port,
         "ProxyAutoConfigEnable":0, "ProxyAutoDiscoveryEnable":0]
    }
    static func matches(_ current: [String: Any], _ patch: [String: Any]) -> Bool {
        patch.allSatisfy { key,value in
            guard let actual = current[key] else { return false }
            return NSDictionary(dictionary:[key:actual]).isEqual(to:[key:value])
        }
    }
    /// Restore only fields still equal to what we wrote; never overwrite a later user's change.
    static func restored(current: [String: Any], before: [String: Any], applied: [String: Any]) -> [String: Any] {
        guard matches(current, applied) else { return current }
        var value = current
        for key in applied.keys { value[key] = before[key] }
        return value
    }
    private func backup() throws -> [String: [String: [String: Any]]] {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return [:] }
        let values = try backupURL.resourceValues(forKeys:[.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw failure("Unsafe system proxy backup") }
        guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: backupURL), format:nil) as? [String: [String: [String: Any]]] else { throw failure("Invalid system proxy backup") }
        return value
    }
    func enabled() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let saved = try backup(), p = try preferences()
        return try services(p).contains { id,proto in
            guard let applied = saved[id]?["applied"] else { return false }
            return Self.matches(SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:], applied)
        }
    }
    var hasSavedState: Bool { FileManager.default.fileExists(atPath:backupURL.path) }
    func updatePortIfNeeded(_ port: Int) throws {
        lock.lock()
        let saved: [String: [String: [String: Any]]]
        do { saved = try backup() } catch { lock.unlock(); throw error }
        lock.unlock()
        if saved.values.contains(where: { ($0["applied"]?["HTTPPort"] as? Int) != port }) {
            try setEnabled(true, port:port, updatingOwnedOnly:true)
        }
    }
    func setEnabled(_ enabled: Bool, port: Int = 7897, updatingOwnedOnly: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard (1024...65535).contains(port) else { throw failure("Invalid managed mixed proxy port") }
        if !enabled, try backup().isEmpty { return }
        let p = try preferences()
        guard SCPreferencesLock(p, true) else { throw failure("Could not lock system proxy preferences") }
        defer { SCPreferencesUnlock(p) }
        SCPreferencesSynchronize(p)
        var saved = try backup()
        let originalSaved = saved
        var changes: [(SCNetworkProtocol, [String:Any])] = []
        let targets = try services(p, includeDisabled: !enabled)
        if enabled && targets.isEmpty { throw failure("No enabled Ethernet or Wi-Fi service") }
        for (id,proto) in targets {
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:]
            var value = current
            if enabled {
                if updatingOwnedOnly {
                    guard let previous = saved[id]?["applied"], Self.matches(current, previous) else { continue }
                }
                let patch = Self.patch(port:port)
                // Repeated enable preserves the original baseline. External edits become a new baseline.
                let baseline = saved[id].flatMap { old in
                    Self.matches(current, old["applied"] ?? [:]) ? old["before"] : nil
                } ?? current
                saved[id] = ["before":baseline, "applied":patch]
                value.merge(patch) { _,new in new }
            } else if let old = saved[id] {
                value = Self.restored(current:current, before:old["before"] ?? [:], applied:old["applied"] ?? [:])
                saved.removeValue(forKey:id)
            } else { continue }
            changes.append((proto,current))
            guard SCNetworkProtocolSetConfiguration(proto, value as CFDictionary) else { throw failure("Could not stage system proxy settings") }
        }
        // Save the recovery baseline before changing system preferences.
        if enabled { try write(saved) }
        guard SCPreferencesCommitChanges(p), SCPreferencesApplyChanges(p) else {
            for (proto,old) in changes { SCNetworkProtocolSetConfiguration(proto, old as CFDictionary) }
            let restored = SCPreferencesCommitChanges(p) && SCPreferencesApplyChanges(p)
            if restored { try write(originalSaved) }
            throw failure(restored ? "System proxy change failed and was restored" : "System proxy restore needs operator review")
        }
        if !enabled { try write(saved) }
    }
    private func write(_ value: [String: [String: [String: Any]]]) throws {
        if value.isEmpty {
            if FileManager.default.fileExists(atPath:backupURL.path) { try FileManager.default.removeItem(at:backupURL) }
        } else {
            let data = try PropertyListSerialization.data(fromPropertyList:value, format:.binary, options:0)
            try data.write(to:backupURL, options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:backupURL.path)
        }
    }
}
