import Foundation

/// A health reading the agent has already taken, shared with the daemon.
///
/// The consistency observer inspects the runtime every two seconds for its own
/// decisions and used to discard the result, while the daemon recomputed the
/// same thing on every tray poll. That recomputation was the single most
/// expensive part of a poll — measured at 25.9-27.9 ms of a 65.5 ms request —
/// because it re-reads and parses the Mihomo config, probes two DNS endpoints
/// with two-second timeouts, and asks the routing table where Fake-IP goes.
///
/// Publishing the reading the agent already has removes that work without a new
/// IPC path or a new privilege: both processes run as root and already share
/// this directory.
public struct HealthSnapshot: Codable, Sendable {
    public var health: NetworkConsistencyHealth
    /// Identifies the exact agent launch or Mihomo-child reload that produced
    /// this reading. Daemon startup validation accepts only its expected
    /// generation; an otherwise fresh snapshot from the previous runtime is
    /// deliberately ignored.
    public var generation: String?
    /// Wall-clock capture time, used only to decide whether the reading is
    /// still worth trusting. Consumers must treat a missing or stale file as
    /// "no reading" and fall back to inspecting.
    public var capturedAt: Date

    public init(
        health: NetworkConsistencyHealth,
        generation: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.health = health
        self.generation = generation
        self.capturedAt = capturedAt
    }
}

/// A lock-protected generation shared by the agent's service and consistency
/// observer. Profile reload advances it before the Mihomo child is replaced.
public final class RuntimeHealthGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    public init(_ value: String = UUID().uuidString) {
        self.value = value
    }

    public func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func replace(with value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

public struct RuntimeReloadRequest: Codable, Equatable, Sendable {
    public var generation: String

    public init(generation: String) {
        self.generation = generation
    }
}

public enum RuntimeReloadRequestStore {
    public static func publish(_ request: RuntimeReloadRequest, to path: String) throws {
        guard UUID(uuidString: request.generation) != nil else {
            throw NSError(
                domain: "MihomoRuntimeReload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "runtime generation is invalid"]
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    /// Consumes the fixed-path request once. A malformed generation is never
    /// acted on and is removed so it cannot be replayed by a later signal.
    public static func consume(from path: String) -> RuntimeReloadRequest? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let request = try? JSONDecoder().decode(RuntimeReloadRequest.self, from: data),
              UUID(uuidString: request.generation) != nil else {
            return nil
        }
        return request
    }

    public static func remove(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

public enum HealthSnapshotStore {
    /// How old a published reading may be before a reader ignores it.
    ///
    /// The observer republishes every two seconds, so anything much older means
    /// it is not running — in which case its last reading describes a runtime
    /// that may no longer exist and must not be served as current.
    public static let freshnessInterval: TimeInterval = 6

    public static func defaultPath(configurationPath: String) -> String {
        URL(fileURLWithPath: configurationPath)
            .deletingLastPathComponent()
            .appendingPathComponent("runtime-health.json")
            .path
    }

    /// Writes atomically so a reader never sees a partial record.
    public static func publish(_ snapshot: HealthSnapshot, to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let url = URL(fileURLWithPath: path)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path
        )
    }

    /// Returns the published reading when one exists and is recent enough.
    public static func read(
        from path: String,
        now: Date = Date(),
        freshness: TimeInterval = freshnessInterval
    ) -> NetworkConsistencyHealth? {
        readSnapshot(from: path, now: now, freshness: freshness)?.health
    }

    public static func readSnapshot(
        from path: String,
        now: Date = Date(),
        freshness: TimeInterval = freshnessInterval
    ) -> HealthSnapshot? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(HealthSnapshot.self, from: data) else { return nil }
        let age = now.timeIntervalSince(snapshot.capturedAt)
        // A reading from the future is a clock change, not a fresh reading.
        guard age >= 0, age <= freshness else { return nil }
        return snapshot
    }

    public static func remove(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
