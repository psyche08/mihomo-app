import Foundation

/// A wall-clock-independent elapsed timer for startup diagnostics.
///
/// Each process owns its own instance. Fixed phase names in the caller make
/// App, daemon and agent startup logs comparable without logging user data.
public struct MonotonicStartupClock: Sendable {
    private let startedAtNanoseconds: UInt64

    public init() {
        startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    public func elapsedMilliseconds() -> UInt64 {
        Self.elapsedMilliseconds(
            startedAtNanoseconds: startedAtNanoseconds,
            nowNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    static func elapsedMilliseconds(
        startedAtNanoseconds: UInt64,
        nowNanoseconds: UInt64
    ) -> UInt64 {
        guard nowNanoseconds >= startedAtNanoseconds else { return 0 }
        return (nowNanoseconds - startedAtNanoseconds) / 1_000_000
    }
}
