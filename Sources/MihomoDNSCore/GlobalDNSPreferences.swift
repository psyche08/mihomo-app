import Foundation
import SystemConfiguration

public enum GlobalDNSPreferencesError: Error, CustomStringConvertible {
    case unavailable
    case lockFailed(Int32)
    case currentSetMissing
    case pathOperationFailed(String, Int32)
    case commitFailed(Int32)
    case applyFailed(Int32)
    case dynamicStoreUnavailable
    case primaryServiceMissing
    case dynamicStateOperationFailed(String, Int32)
    case invalidBackup

    public var description: String {
        switch self {
        case .unavailable: return "cannot open SystemConfiguration preferences"
        case .lockFailed(let code): return "cannot lock SystemConfiguration preferences error=\(code)"
        case .currentSetMissing: return "CurrentSet is missing from SystemConfiguration preferences"
        case .pathOperationFailed(let operation, let code): return "SCPreferences path \(operation) failed error=\(code)"
        case .commitFailed(let code): return "SCPreferencesCommitChanges failed error=\(code)"
        case .applyFailed(let code): return "SCPreferencesApplyChanges failed error=\(code)"
        case .dynamicStoreUnavailable: return "cannot open SystemConfiguration dynamic store"
        case .primaryServiceMissing: return "cannot resolve the primary network service"
        case .dynamicStateOperationFailed(let operation, let code):
            return "SCDynamicStore \(operation) failed error=\(code)"
        case .invalidBackup: return "system DNS backup is not a valid property list"
        }
    }
}

enum ResolverServerClassification: String, Equatable, Sendable {
    case missing
    case managed
    case external
    case mixed

    static func classify(observed: [String], managed: [String]) -> Self {
        guard !observed.isEmpty else { return .missing }
        let observedSet = Set(observed)
        let managedSet = Set(managed)
        if observedSet == managedSet { return .managed }
        return observedSet.isDisjoint(with: managedSet) ? .external : .mixed
    }
}

struct ResolverTopologyObservation: Equatable, Sendable {
    var global: ResolverServerClassification
    var primaryScoped: ResolverServerClassification
    var scopedTotal: Int
    var scopedManaged: Int
    var scopedExternal: Int
    var scopedMixed: Int

    static func make(
        managedServers: [String],
        globalServers: [String],
        primaryScopedServers: [String],
        scopedServers: [[String]]
    ) -> Self {
        let scoped = scopedServers.map {
            ResolverServerClassification.classify(observed: $0, managed: managedServers)
        }
        return ResolverTopologyObservation(
            global: .classify(observed: globalServers, managed: managedServers),
            primaryScoped: .classify(observed: primaryScopedServers, managed: managedServers),
            scopedTotal: scoped.count,
            scopedManaged: scoped.count(where: { $0 == .managed }),
            scopedExternal: scoped.count(where: { $0 == .external }),
            scopedMixed: scoped.count(where: { $0 == .mixed })
        )
    }
}

enum ManagedDNSDictionaryCleanup {
    /// Returns an updated dictionary only when ServerAddresses exactly matches
    /// the managed value. An empty dictionary tells the caller to remove the
    /// whole path; nil means ownership cannot be proved and nothing may change.
    static func removingExactServers(
        _ servers: [String],
        from dictionary: [String: Any]
    ) -> [String: Any]? {
        guard dictionary[kSCPropNetDNSServerAddresses as String] as? [String] == servers else {
            return nil
        }
        var updated = dictionary
        updated.removeValue(forKey: kSCPropNetDNSServerAddresses as String)
        return updated
    }
}

public final class GlobalDNSPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private let servers: [String]
    private let backupPath: String
    private let preferencesID: String?
    private let primaryServiceIDOverride: String?

    public init(
        servers: [String],
        backupPath: String,
        preferencesID: String? = nil,
        primaryServiceIDOverride: String? = nil
    ) {
        self.servers = servers
        self.backupPath = backupPath
        self.preferencesID = preferencesID
        self.primaryServiceIDOverride = primaryServiceIDOverride
    }

    public func apply() throws {
        lock.lock()
        defer { lock.unlock() }
        let preferences = try createLockedPreferences()
        defer { SCPreferencesUnlock(preferences) }
        let dynamic = preferencesID == nil ? try? dynamicDNSContext() : nil
        let path = try currentManagedDNSPath(preferences, dynamicServiceID: dynamic?.serviceID)
        let current = SCPreferencesPathGetValue(preferences, path as CFString) as? [String: Any]
        var backup = try loadBackup()
        var entries = backup["Entries"] as? [String: Any] ?? [:]
        var backupChanged = false
        if entries[path] == nil {
            var entry: [String: Any] = ["Existed": current != nil]
            if let current { entry["Value"] = current }
            entries[path] = entry
            backup["Entries"] = entries
            backupChanged = true
        }
        if let dynamic {
            var dynamicEntries = backup["DynamicEntries"] as? [String: Any] ?? [:]
            if dynamicEntries[dynamic.key] == nil {
                var entry: [String: Any] = ["Existed": dynamic.value != nil]
                if let value = dynamic.value { entry["Value"] = value }
                dynamicEntries[dynamic.key] = entry
                backup["DynamicEntries"] = dynamicEntries
                backupChanged = true
            }
        }
        if backupChanged { try saveBackup(backup) }

        var persistentChanged = try restoreStalePersistentEntries(
            entries,
            excluding: path,
            preferences: preferences
        )
        var managed = current ?? [:]
        managed[kSCPropNetDNSServerAddresses as String] = servers
        if let existingServers = current?[kSCPropNetDNSServerAddresses as String] as? [String],
           existingServers == servers {
            if persistentChanged {
                try commitAndApply(preferences)
            } else if effectiveServers() != servers {
                guard SCPreferencesApplyChanges(preferences) else {
                    throw GlobalDNSPreferencesError.applyFailed(SCError())
                }
            }
        } else {
            guard SCPreferencesPathSetValue(preferences, path as CFString, managed as CFDictionary) else {
                throw GlobalDNSPreferencesError.pathOperationFailed("set", SCError())
            }
            try commitAndApply(preferences)
            persistentChanged = true
        }

        let staleDynamicChanged = try restoreStaleDynamicState(
            backup["DynamicEntries"],
            excluding: dynamic?.key
        )
        let dynamicChanged = try applyDynamicState(dynamic)
        let scope = dynamic == nil && primaryServiceIDOverride == nil ? "global_fallback" : "primary_service"
        if persistentChanged {
            ServiceLog.info("event=system_dns_applied scope=\(scope) server_count=\(servers.count)")
        } else if dynamicChanged || staleDynamicChanged {
            ServiceLog.info("event=system_dns_reapplied scope=\(scope) server_count=\(servers.count)")
        }
    }

    public func isApplied() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let preferences = try createLockedPreferences()
        defer { SCPreferencesUnlock(preferences) }
        let dynamicServiceID = preferencesID == nil ? (try? dynamicDNSContext().serviceID) : nil
        let path = try currentManagedDNSPath(preferences, dynamicServiceID: dynamicServiceID)
        let current = SCPreferencesPathGetValue(preferences, path as CFString) as? [String: Any]
        return current?[kSCPropNetDNSServerAddresses as String] as? [String] == servers
    }

    public func containsManagedServerPersistently() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let preferences = try createLockedPreferences()
        defer { SCPreferencesUnlock(preferences) }
        guard let currentSet = SCPreferencesGetValue(
            preferences,
            kSCPrefCurrentSet
        ) as? String else {
            throw GlobalDNSPreferencesError.currentSetMissing
        }
        let globalPath = "\(currentSet)/Network/Global/DNS"
        if persistentServers(at: globalPath, preferences: preferences)
            .contains(where: { servers.contains($0) }) {
            return true
        }
        let servicesPath = "\(currentSet)/Network/Service"
        let services = (
            SCPreferencesPathGetValue(preferences, servicesPath as CFString) as? [String: Any]
        ) ?? [:]
        for serviceID in services.keys {
            let path = "\(servicesPath)/\(serviceID)/DNS"
            if persistentServers(at: path, preferences: preferences)
                .contains(where: { servers.contains($0) }) {
                return true
            }
        }
        return false
    }

    public func isEffective() -> Bool {
        effectiveServers() == servers
    }

    /// Returns a log-safe view of macOS resolver topology. It deliberately
    /// classifies address sets instead of returning service IDs or resolver
    /// addresses, so a field diagnostic can distinguish Global DNS from
    /// scoped drift without persisting enterprise network details.
    func resolverTopology() throws -> ResolverTopologyObservation {
        let store = try createDynamicStore("dev.linsheng.mihomo-app.daemon.dns-topology")
        let globalServers = dynamicServers(at: "State:/Network/Global/DNS", store: store)
        let primaryServers: [String]
        do {
            primaryServers = try dynamicDNSContext().value?[kSCPropNetDNSServerAddresses as String]
                as? [String] ?? []
        } catch GlobalDNSPreferencesError.primaryServiceMissing {
            primaryServers = []
        }

        guard let keys = SCDynamicStoreCopyKeyList(
            store,
            "State:/Network/Service/.*/DNS" as CFString
        ) as? [String] else {
            throw GlobalDNSPreferencesError.dynamicStateOperationFailed(
                "enumerate DNS topology",
                SCError()
            )
        }
        let scopedServers = keys.sorted().map { dynamicServers(at: $0, store: store) }
        return ResolverTopologyObservation.make(
            managedServers: servers,
            globalServers: globalServers,
            primaryScopedServers: primaryServers,
            scopedServers: scopedServers
        )
    }

    public func containsManagedServerEffectively() throws -> Bool {
        guard preferencesID == nil else { return false }
        let store = try createDynamicStore(
            "dev.linsheng.mihomo-app.daemon.dns-restore-check"
        )
        if dynamicServers(
            at: "State:/Network/Global/DNS",
            store: store
        ).contains(where: { servers.contains($0) }) {
            return true
        }
        guard let keys = SCDynamicStoreCopyKeyList(
            store,
            "State:/Network/Service/.*/DNS" as CFString
        ) as? [String] else {
            throw GlobalDNSPreferencesError.dynamicStateOperationFailed(
                "enumerate DNS state",
                SCError()
            )
        }
        for key in keys {
            if dynamicServers(at: key, store: store)
                .contains(where: { servers.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func persistentServers(at path: String, preferences: SCPreferences) -> [String] {
        let dns = SCPreferencesPathGetValue(preferences, path as CFString) as? [String: Any]
        return dns?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
    }

    private func dynamicServers(at key: String, store: SCDynamicStore) -> [String] {
        let dns = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        return dns?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
    }

    public func hasManagedBackup() -> Bool {
        FileManager.default.fileExists(atPath: backupPath)
    }

    public func restore() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: backupPath) else {
            let preferences = try createLockedPreferences()
            defer { SCPreferencesUnlock(preferences) }
            // A crash, an older build, or a primary-service transition can
            // leave our exact loopback resolver on a service that is no longer
            // current. With no backup there is nothing safe to reconstruct, so
            // enumerate every DNS scope and remove only the ServerAddresses
            // value that exactly matches ours. Preserve search domains and all
            // other externally-owned DNS keys.
            var changed = try removeUnbackedManagedPersistentState(preferences)
            if changed {
                try commitAndApply(preferences)
            }
            if try removeManagedDynamicState() { changed = true }
            ServiceLog.info("event=system_dns_restored changed=\(changed) reason=no_backup")
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
                ServiceLog.info("event=system_dns_restore_skipped reason=externally_changed")
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
        let backedPaths = Set(entries.keys)
        if try removeUnbackedManagedPersistentState(
            preferences,
            excluding: backedPaths
        ) {
            changed = true
        }
        if changed { try commitAndApply(preferences) }
        if try restoreDynamicState(backup["DynamicEntries"]) { changed = true }
        let backedDynamicKeys = Set(
            (backup["DynamicEntries"] as? [String: Any])?.keys.map { $0 } ?? []
        )
        if try removeManagedDynamicState(excluding: backedDynamicKeys) { changed = true }
        try FileManager.default.removeItem(atPath: backupPath)
        ServiceLog.info("event=system_dns_restored changed=\(changed)")
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

    private func currentManagedDNSPath(
        _ preferences: SCPreferences,
        dynamicServiceID: String?
    ) throws -> String {
        guard let currentSet = SCPreferencesGetValue(preferences, kSCPrefCurrentSet) as? String else {
            throw GlobalDNSPreferencesError.currentSetMissing
        }
        let serviceID = primaryServiceIDOverride ?? dynamicServiceID
        guard let serviceID, isSafeServiceID(serviceID) else {
            return "\(currentSet)/Network/Global/DNS"
        }
        return "\(currentSet)/Network/Service/\(serviceID)/DNS"
    }

    private func allPersistentDNSPaths(_ preferences: SCPreferences) throws -> [String] {
        guard let currentSet = SCPreferencesGetValue(preferences, kSCPrefCurrentSet) as? String else {
            throw GlobalDNSPreferencesError.currentSetMissing
        }
        let servicesPath = "\(currentSet)/Network/Service"
        let services = (
            SCPreferencesPathGetValue(preferences, servicesPath as CFString) as? [String: Any]
        ) ?? [:]
        var paths = ["\(currentSet)/Network/Global/DNS"]
        paths.append(contentsOf: services.keys.sorted().compactMap { serviceID in
            isSafeServiceID(serviceID) ? "\(servicesPath)/\(serviceID)/DNS" : nil
        })
        return paths
    }

    private func removeUnbackedManagedPersistentState(
        _ preferences: SCPreferences,
        excluding backedPaths: Set<String> = []
    ) throws -> Bool {
        var changed = false
        for path in try allPersistentDNSPaths(preferences) where !backedPaths.contains(path) {
            guard let current = SCPreferencesPathGetValue(
                preferences,
                path as CFString
            ) as? [String: Any],
                let updated = ManagedDNSDictionaryCleanup.removingExactServers(
                    servers,
                    from: current
                ) else {
                continue
            }
            let succeeded: Bool
            if updated.isEmpty {
                succeeded = SCPreferencesPathRemoveValue(preferences, path as CFString)
            } else {
                succeeded = SCPreferencesPathSetValue(
                    preferences,
                    path as CFString,
                    updated as CFDictionary
                )
            }
            guard succeeded else {
                throw GlobalDNSPreferencesError.pathOperationFailed(
                    "remove unbacked managed DNS",
                    SCError()
                )
            }
            changed = true
        }
        return changed
    }

    private func isSafeServiceID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
    }

    private func restoreStalePersistentEntries(
        _ entries: [String: Any],
        excluding currentPath: String,
        preferences: SCPreferences
    ) throws -> Bool {
        var changed = false
        for (path, rawEntry) in entries where path != currentPath {
            let current = SCPreferencesPathGetValue(preferences, path as CFString) as? [String: Any]
            guard current?[kSCPropNetDNSServerAddresses as String] as? [String] == servers else {
                continue
            }
            guard let entry = rawEntry as? [String: Any],
                  let existed = entry["Existed"] as? Bool else {
                throw GlobalDNSPreferencesError.invalidBackup
            }
            if existed {
                guard let value = entry["Value"] as? [String: Any],
                      SCPreferencesPathSetValue(preferences, path as CFString, value as CFDictionary) else {
                    throw GlobalDNSPreferencesError.pathOperationFailed("restore stale service", SCError())
                }
            } else if !SCPreferencesPathRemoveValue(preferences, path as CFString) {
                throw GlobalDNSPreferencesError.pathOperationFailed("remove stale service", SCError())
            }
            changed = true
        }
        return changed
    }

    private func commitAndApply(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences) else {
            throw GlobalDNSPreferencesError.commitFailed(SCError())
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw GlobalDNSPreferencesError.applyFailed(SCError())
        }
    }

    private func effectiveServers() -> [String]? {
        (try? dynamicDNSContext().value)?[kSCPropNetDNSServerAddresses as String] as? [String]
    }

    private func createDynamicStore(_ name: String) throws -> SCDynamicStore {
        guard let store = SCDynamicStoreCreate(
            nil,
            name as CFString,
            nil,
            nil
        ) else {
            throw GlobalDNSPreferencesError.dynamicStoreUnavailable
        }
        return store
    }

    private func dynamicDNSContext() throws -> (
        store: SCDynamicStore,
        key: String,
        value: [String: Any]?,
        serviceID: String
    ) {
        let store = try createDynamicStore("dev.linsheng.mihomo-app.daemon.dns-check")
        let globalIPv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
            as? [String: Any]
        let globalIPv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString)
            as? [String: Any]
        guard let serviceID = (globalIPv4?["PrimaryService"] as? String)
            ?? (globalIPv6?["PrimaryService"] as? String) else {
            throw GlobalDNSPreferencesError.primaryServiceMissing
        }
        let key = "State:/Network/Service/\(serviceID)/DNS"
        let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        return (store, key, value, serviceID)
    }

    private func applyDynamicState(_ existingContext: (
        store: SCDynamicStore,
        key: String,
        value: [String: Any]?,
        serviceID: String
    )?) throws -> Bool {
        guard preferencesID == nil else { return false }
        let dynamic = try existingContext ?? dynamicDNSContext()
        if dynamic.value?[kSCPropNetDNSServerAddresses as String] as? [String] == servers {
            return false
        }
        var managed = dynamic.value ?? [:]
        managed[kSCPropNetDNSServerAddresses as String] = servers
        guard SCDynamicStoreSetValue(dynamic.store, dynamic.key as CFString, managed as CFDictionary) else {
            throw GlobalDNSPreferencesError.dynamicStateOperationFailed("set", SCError())
        }
        return true
    }

    private func restoreStaleDynamicState(_ rawEntries: Any?, excluding currentKey: String?) throws -> Bool {
        guard preferencesID == nil, let rawEntries else { return false }
        guard let entries = rawEntries as? [String: Any] else {
            throw GlobalDNSPreferencesError.invalidBackup
        }
        let store = try createDynamicStore("dev.linsheng.mihomo-app.daemon.dns-transition")
        var changed = false
        for (key, rawEntry) in entries where key != currentKey {
            let current = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
            guard current?[kSCPropNetDNSServerAddresses as String] as? [String] == servers else {
                continue
            }
            guard let entry = rawEntry as? [String: Any],
                  let existed = entry["Existed"] as? Bool else {
                throw GlobalDNSPreferencesError.invalidBackup
            }
            if existed {
                guard let value = entry["Value"] as? [String: Any],
                      SCDynamicStoreSetValue(store, key as CFString, value as CFDictionary) else {
                    throw GlobalDNSPreferencesError.dynamicStateOperationFailed("restore stale service", SCError())
                }
            } else if !SCDynamicStoreRemoveValue(store, key as CFString) {
                throw GlobalDNSPreferencesError.dynamicStateOperationFailed("remove stale service", SCError())
            }
            changed = true
        }
        return changed
    }

    private func restoreDynamicState(_ rawEntries: Any?) throws -> Bool {
        guard preferencesID == nil else { return false }
        guard let rawEntries else { return false }
        guard let entries = rawEntries as? [String: Any] else {
            throw GlobalDNSPreferencesError.invalidBackup
        }
        let store = try createDynamicStore("dev.linsheng.mihomo-app.daemon.dns-restore")
        var changed = false
        for (key, rawEntry) in entries {
            let current = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
            guard current?[kSCPropNetDNSServerAddresses as String] as? [String] == servers else {
                continue
            }
            guard let entry = rawEntry as? [String: Any],
                  let existed = entry["Existed"] as? Bool else {
                throw GlobalDNSPreferencesError.invalidBackup
            }
            if existed {
                guard let value = entry["Value"] as? [String: Any],
                      SCDynamicStoreSetValue(store, key as CFString, value as CFDictionary) else {
                    throw GlobalDNSPreferencesError.dynamicStateOperationFailed("restore", SCError())
                }
            } else if !SCDynamicStoreRemoveValue(store, key as CFString) {
                throw GlobalDNSPreferencesError.dynamicStateOperationFailed("remove", SCError())
            }
            changed = true
        }
        return changed
    }

    private func removeManagedDynamicState(excluding backedKeys: Set<String> = []) throws -> Bool {
        guard preferencesID == nil else { return false }
        let store = try createDynamicStore("dev.linsheng.mihomo-app.daemon.dns-cleanup")
        var keys = ["State:/Network/Global/DNS"]
        guard let serviceKeys = SCDynamicStoreCopyKeyList(
            store,
            "State:/Network/Service/.*/DNS" as CFString
        ) as? [String] else {
            throw GlobalDNSPreferencesError.dynamicStateOperationFailed(
                "enumerate cleanup state",
                SCError()
            )
        }
        keys.append(contentsOf: serviceKeys)
        var changed = false
        for key in Set(keys).subtracting(backedKeys).sorted() {
            guard let current = SCDynamicStoreCopyValue(
                store,
                key as CFString
            ) as? [String: Any],
                let updated = ManagedDNSDictionaryCleanup.removingExactServers(
                    servers,
                    from: current
                ) else {
                continue
            }
            let succeeded = updated.isEmpty
                ? SCDynamicStoreRemoveValue(store, key as CFString)
                : SCDynamicStoreSetValue(store, key as CFString, updated as CFDictionary)
            guard succeeded else {
                throw GlobalDNSPreferencesError.dynamicStateOperationFailed("remove", SCError())
            }
            changed = true
        }
        return changed
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
