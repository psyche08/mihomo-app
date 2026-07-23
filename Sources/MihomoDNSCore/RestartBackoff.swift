import Foundation

public enum RestartBackoffDecision: Equatable {
    case retry(delayMilliseconds: Int, failures: Int)
    case open(failures: Int)
}

public struct RestartBackoffPolicy: Equatable {
    public let baseDelayMilliseconds: Int
    public let maximumDelayMilliseconds: Int
    public let maximumFailures: Int
    public let stableRuntimeMilliseconds: Int
    public private(set) var consecutiveFailures = 0

    public init(
        baseDelayMilliseconds: Int = 1_000,
        maximumDelayMilliseconds: Int = 30_000,
        maximumFailures: Int = 6,
        stableRuntimeMilliseconds: Int = 60_000
    ) {
        self.baseDelayMilliseconds = max(1, baseDelayMilliseconds)
        self.maximumDelayMilliseconds = max(self.baseDelayMilliseconds, maximumDelayMilliseconds)
        self.maximumFailures = max(1, maximumFailures)
        self.stableRuntimeMilliseconds = max(1, stableRuntimeMilliseconds)
    }

    public mutating func recordFailure(runtimeMilliseconds: Int) -> RestartBackoffDecision {
        if runtimeMilliseconds >= stableRuntimeMilliseconds {
            consecutiveFailures = 0
        }
        consecutiveFailures += 1
        guard consecutiveFailures < maximumFailures else {
            return .open(failures: consecutiveFailures)
        }
        let exponent = min(consecutiveFailures - 1, 20)
        let multiplier = 1 << exponent
        let delay = min(maximumDelayMilliseconds, baseDelayMilliseconds * multiplier)
        return .retry(delayMilliseconds: delay, failures: consecutiveFailures)
    }

    public mutating func reset() {
        consecutiveFailures = 0
    }
}
