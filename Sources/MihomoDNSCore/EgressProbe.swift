import Foundation

/// Outcome of the end-to-end egress probe.
///
/// Every other runtime signal this app collects (DNS forwarding counters, the
/// mihomo DNS listener, the controller HTTP endpoint, the loopback bridge) is
/// answered locally: under Fake-IP a name lookup never leaves the machine, so a
/// fully dead data path still reports healthy. This probe is the only signal
/// that requires bytes to actually leave and come back, which is exactly the
/// failure the observer was previously blind to.
public enum EgressProbeOutcome: String, Equatable, Sendable {
    /// No probe has completed yet, or probing is not applicable (no real
    /// outbound proxy selected).
    case unknown
    /// A request completed through the selected proxy and came back.
    case reachable
    /// The probe ran and no response came back.
    case unreachable
}

/// A probe outcome together with the sequence number that identifies it, so a
/// caller can tell a freshly published result from one it has already acted on.
struct EgressProbeReading: Equatable {
    let outcome: EgressProbeOutcome
    let sequence: UInt64
}

enum EgressRecoveryDecision: Equatable {
    case none
    /// Failing, but not yet long enough to report.
    case debounce
    /// Sustained egress failure following a period where egress demonstrably
    /// worked, while every other (loopback-answered) signal still reads healthy.
    ///
    /// This is a *verdict*, not an instruction: the observer reports it and does
    /// not restart the runtime. A failed probe cannot yet distinguish a broken
    /// local data path — which a restart would fix — from a remote node outage,
    /// which it would not, and restarting drops every live connection and (with
    /// no `store-selected` in the shipped profile) resets the user's mode and
    /// node selection. Recovery can be enabled once field logs from this signal
    /// establish which of the two the wake failure actually is.
    case sustainedFailure
}

/// Decides *when* to spend a probe and *whether* sustained failure justifies
/// restarting the Mihomo runtime.
///
/// The probe costs real proxied traffic, so it runs on its own slow cadence
/// rather than on the 2-second consistency tick. Recovery is deliberately
/// conservative: a proxy that is genuinely down (expired subscription, no
/// upstream network) must not put the runtime into a restart loop, so a
/// triggered recovery is followed by a long cooldown.
struct EgressProbePolicy {
    let intervalNanoseconds: UInt64
    let cooldownNanoseconds: UInt64
    let requiredFailures: Int
    private(set) var consecutiveFailures = 0
    /// Whether egress has ever succeeded for the current runtime.
    ///
    /// Recovery is for *regressions* — a path that worked and then stopped,
    /// which is the wake-from-sleep failure. Without this, two common and
    /// perfectly legitimate states would trigger endless restarts: a machine
    /// with no upstream network at all (every local signal still reads healthy,
    /// because they are all answered on loopback), and a proxy that is simply
    /// down or expired. Neither is fixed by restarting the runtime.
    private(set) var observedReachable = false
    private var lastProbeNanoseconds: UInt64?
    private var cooldownUntilNanoseconds: UInt64?

    init(
        intervalSeconds: UInt64 = 60,
        cooldownSeconds: UInt64 = 600,
        requiredFailures: Int = 3
    ) {
        intervalNanoseconds = intervalSeconds * 1_000_000_000
        cooldownNanoseconds = cooldownSeconds * 1_000_000_000
        self.requiredFailures = max(1, requiredFailures)
    }

    /// Whether a probe is due now. `forced` bypasses the interval and is used
    /// right after a wake, when the data path is most likely to have silently
    /// broken while the machine was suspended.
    ///
    /// Pure predicate: the caller must call `noteProbeStarted` only once a probe
    /// actually started, so a probe that was dropped (one already in flight)
    /// does not consume the interval or the forced flag.
    func isProbeDue(nowNanoseconds: UInt64, forced: Bool) -> Bool {
        if forced { return true }
        guard let lastProbeNanoseconds else { return true }
        return nowNanoseconds &- lastProbeNanoseconds >= intervalNanoseconds
    }

    mutating func noteProbeStarted(nowNanoseconds: UInt64) {
        lastProbeNanoseconds = nowNanoseconds
    }

    /// Forgets when the last probe ran so the next tick probes immediately.
    mutating func clearProbeSchedule() {
        lastProbeNanoseconds = nil
    }

    /// Folds a completed probe outcome into a recovery decision.
    mutating func decide(
        outcome: EgressProbeOutcome,
        runtimeReady: Bool,
        nowNanoseconds: UInt64
    ) -> EgressRecoveryDecision {
        // Only a probe that actually ran against a healthy-looking runtime can
        // implicate the local data path. `unknown` means we could not probe.
        guard runtimeReady, outcome != .unknown else {
            consecutiveFailures = 0
            return .none
        }
        guard outcome == .unreachable else {
            observedReachable = true
            consecutiveFailures = 0
            return .none
        }
        // Never seen a working path in this runtime: this is "not configured /
        // offline / proxy down", not a regression a restart can fix.
        guard observedReachable else {
            consecutiveFailures = 0
            return .none
        }
        if let cooldownUntilNanoseconds {
            guard nowNanoseconds >= cooldownUntilNanoseconds else { return .debounce }
            self.cooldownUntilNanoseconds = nil
        }
        consecutiveFailures += 1
        guard consecutiveFailures >= requiredFailures else { return .debounce }
        consecutiveFailures = 0
        cooldownUntilNanoseconds = nowNanoseconds &+ cooldownNanoseconds
        // One verdict per episode: egress must demonstrably work again before
        // another sustained failure can be reported, which keeps a persistently
        // dead path from repeating the same finding forever.
        observedReachable = false
        return .sustainedFailure
    }

    /// Clears transient failure state (used on wake) while preserving the fact
    /// that egress previously worked, which is what makes a post-wake failure
    /// recognisable as a regression.
    mutating func reset() {
        consecutiveFailures = 0
    }
}

/// Runs egress probes off the consistency queue and publishes the latest result.
///
/// A probe can take seconds (the controller applies a per-node timeout), so it
/// must never run inline on the 2-second consistency timer. The controller reads
/// `latest()` — a non-blocking snapshot — and separately asks for a probe to be
/// scheduled.
final class EgressProbeCoordinator: @unchecked Sendable {
    private let configuration: ProxyConfiguration
    private let probe: @Sendable (ProxyConfiguration) -> EgressProbeOutcome
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.egress")
    private let lock = NSLock()
    private var outcome: EgressProbeOutcome = .unknown
    private var inFlight = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0

    init(
        configuration: ProxyConfiguration,
        probe: @escaping @Sendable (ProxyConfiguration) -> EgressProbeOutcome = {
            MihomoRuntimeInspector.probeEgress(configuration: $0)
        }
    ) {
        self.configuration = configuration
        self.probe = probe
    }

    /// Non-blocking snapshot of the most recent completed probe, tagged with a
    /// sequence number that advances only when a genuinely new result is
    /// published (or the cache is invalidated).
    ///
    /// The sequence is what stops a single probe result from being counted as
    /// many failures: the consistency timer ticks every 2 seconds but probes run
    /// at most once a minute, so a caller that folds `outcome` on every tick
    /// would reach its failure threshold off one probe.
    func latest() -> EgressProbeReading {
        lock.lock()
        defer { lock.unlock() }
        return EgressProbeReading(outcome: outcome, sequence: sequence)
    }

    /// Schedules a probe unless one is already running.
    /// - Returns: whether a probe actually started.
    @discardableResult
    func schedule(completion: (@Sendable (EgressProbeOutcome) -> Void)? = nil) -> Bool {
        lock.lock()
        guard !inFlight else {
            lock.unlock()
            return false
        }
        inFlight = true
        let currentGeneration = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let result = self.probe(self.configuration)
            self.lock.lock()
            self.inFlight = false
            // Drop a result produced by a probe that started before the last
            // invalidate() — the runtime it measured no longer exists.
            let stale = currentGeneration != self.generation
            if !stale {
                self.outcome = result
                self.sequence &+= 1
            }
            self.lock.unlock()
            if !stale {
                completion?(result)
            }
        }
        return true
    }

    /// Discards the cached result and any in-flight probe's result, e.g. across
    /// a sleep boundary or a runtime restart where the old measurement no longer
    /// describes the current data path.
    func invalidate() {
        lock.lock()
        outcome = .unknown
        generation &+= 1
        sequence &+= 1
        lock.unlock()
    }
}
