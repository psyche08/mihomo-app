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
    /// Wall-clock capture time, used only to decide whether the reading is
    /// still worth trusting. Consumers must treat a missing or stale file as
    /// "no reading" and fall back to inspecting.
    public var capturedAt: Date

    public init(health: NetworkConsistencyHealth, capturedAt: Date = Date()) {
        self.health = health
        self.capturedAt = capturedAt
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
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(HealthSnapshot.self, from: data) else { return nil }
        let age = now.timeIntervalSince(snapshot.capturedAt)
        // A reading from the future is a clock change, not a fresh reading.
        guard age >= 0, age <= freshness else { return nil }
        return snapshot.health
    }

    public static func remove(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
