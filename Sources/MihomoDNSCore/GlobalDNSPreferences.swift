import Foundation
import SystemConfiguration

public enum GlobalDNSPreferencesError: Error, CustomStringConvertible {
    case unavailable
    case lockFailed(Int32)
    case currentSetMissing
    case pathOperationFailed(String, Int32)
    case commitFailed(Int32)
    case applyFailed(Int32)
    case invalidBackup

    public var description: String {
        switch self {
        case .unavailable: return "cannot open SystemConfiguration preferences"
        case .lockFailed(let code): return "cannot lock SystemConfiguration preferences error=\(code)"
        case .currentSetMissing: return "CurrentSet is missing from SystemConfiguration preferences"
        case .pathOperationFailed(let operation, let code): return "SCPreferences path \(operation) failed error=\(code)"
        case .commitFailed(let code): return "SCPreferencesCommitChanges failed error=\(code)"
        case .applyFailed(let code): return "SCPreferencesApplyChanges failed error=\(code)"
        case .invalidBackup: return "global DNS backup is not a valid property list"
        }
    }
}

public final class GlobalDNSPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private let servers: [String]
    private let backupPath: String
    private let preferencesID: String?

    public init(servers: [String], backupPath: String, preferencesID: String? = nil) {
        self.servers = servers
        self.backupPath = backupPath
        self.preferencesID = preferencesID
    }

    public func apply() throws {
        lock.lock()
        defer { lock.unlock() }
        let preferences = try createLockedPreferences()
        defer { SCPreferencesUnlock(preferences) }
        let path = try currentGlobalDNSPath(preferences)
        let current = SCPreferencesPathGetValue(preferences, path as CFString) as? [String: Any]
        var backup = try loadBackup()
        var entries = backup["Entries"] as? [String: Any] ?? [:]
        if entries[path] == nil {
            var entry: [String: Any] = ["Existed": current != nil]
            if let current { entry["Value"] = current }
            entries[path] = entry
            backup["Entries"] = entries
            try saveBackup(backup)
        }

        var managed = current ?? [:]
        managed[kSCPropNetDNSServerAddresses as String] = servers
        if let existingServers = current?[kSCPropNetDNSServerAddresses as String] as? [String],
           existingServers == servers {
            return
        }
        guard SCPreferencesPathSetValue(preferences, path as CFString, managed as CFDictionary) else {
            throw GlobalDNSPreferencesError.pathOperationFailed("set", SCError())
        }
        try commitAndApply(preferences)
        ServiceLog.info("event=global_dns_applied server_count=\(servers.count)")
    }

    public func restore() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: backupPath) else {
            ServiceLog.info("event=global_dns_restored changed=false reason=no_backup")
            return
        }
        let backup = try loadBackup(required: true)
        guard let entries = backup["Entries"] as? [String: Any] else {
            throw GlobalDNSPreferencesError.invalidBackup
        }
        let preferences = try createLockedPreferences()
        defer { SCPreferencesUnlock(preferences) }
        var changed = false
        for (path, rawEntry) in entries {
            guard let entry = rawEntry as? [String: Any],
                  let existed = entry["Existed"] as? Bool else {
                throw GlobalDNSPreferencesError.invalidBackup
            }
            let current = SCPreferencesPathGetValue(preferences, path as CFString) as? [String: Any]
            let currentServers = current?[kSCPropNetDNSServerAddresses as String] as? [String]
            guard currentServers == servers else {
                ServiceLog.info("event=global_dns_restore_skipped reason=externally_changed")
                continue
            }
            if existed {
                guard let value = entry["Value"] as? [String: Any],
                      SCPreferencesPathSetValue(preferences, path as CFString, value as CFDictionary) else {
                    throw GlobalDNSPreferencesError.pathOperationFailed("restore", SCError())
                }
            } else if !SCPreferencesPathRemoveValue(preferences, path as CFString) {
                throw GlobalDNSPreferencesError.pathOperationFailed("remove", SCError())
            }
            changed = true
        }
        if changed { try commitAndApply(preferences) }
        try FileManager.default.removeItem(atPath: backupPath)
        ServiceLog.info("event=global_dns_restored changed=\(changed)")
    }

    private func createLockedPreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(
            nil,
            "dev.linsheng.mihomo-app.daemon" as CFString,
            preferencesID as CFString?
        ) else {
            throw GlobalDNSPreferencesError.unavailable
        }
        guard SCPreferencesLock(preferences, true) else {
            throw GlobalDNSPreferencesError.lockFailed(SCError())
        }
        return preferences
    }

    private func currentGlobalDNSPath(_ preferences: SCPreferences) throws -> String {
        guard let currentSet = SCPreferencesGetValue(preferences, kSCPrefCurrentSet) as? String else {
            throw GlobalDNSPreferencesError.currentSetMissing
        }
        return "\(currentSet)/Network/Global/DNS"
    }

    private func commitAndApply(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences) else {
            throw GlobalDNSPreferencesError.commitFailed(SCError())
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw GlobalDNSPreferencesError.applyFailed(SCError())
        }
    }

    private func loadBackup(required: Bool = false) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: backupPath) else {
            if required { throw GlobalDNSPreferencesError.invalidBackup }
            return ["Version": 1, "Entries": [String: Any]()]
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: backupPath))
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              value["Version"] as? Int == 1 else {
            throw GlobalDNSPreferencesError.invalidBackup
        }
        return value
    }

    private func saveBackup(_ backup: [String: Any]) throws {
        let url = URL(fileURLWithPath: backupPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
