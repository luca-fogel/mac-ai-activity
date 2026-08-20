import Foundation

/// A source's freshness. The five states are rendered as visually
/// incommensurable, not merely tinted: a source going dark must never look
/// like a source reading zero.
///
/// Lives in `Telemetry` rather than the UI because deciding which state a
/// source is in is domain logic — it depends on how the source works, not on
/// how it is drawn — and because it is the part most worth testing.
public enum Freshness: Sendable, Equatable {
    /// No source of this kind is there. Distinct from `dark`: nothing has
    /// failed, there is simply nothing to report. Rendering a stopped server —
    /// or a backend that structurally exposes no counters — as an error reads
    /// as a fault the user should act on.
    case absent(String)
    case live(hz: Double, jitter: Double)
    /// The value is real but its source has not refreshed yet — battery power
    /// updates only every few seconds. Full ink, badged with its age.
    case held(age: Double)
    case stale(age: Double)
    case dark(reason: String)

    public var isDark: Bool { if case .dark = self { return true }; return false }
    public var isAbsent: Bool { if case .absent = self { return true }; return false }
}

/// How to judge a source's freshness.
///
/// The sources in this app differ in *kind*, not merely in rate, and a single
/// "expected interval" cannot serve them all. Power polls reliably at 0.2 Hz
/// while the value underneath it legitimately does not move for tens of
/// seconds; a push stream emits only when work happens, so silence carries no
/// information about health at all. Collapsing those into one rule is what
/// produced a warning-coloured `pwr stale 44.5s` on a perfectly healthy
/// collector.
public enum FreshnessPolicy: Sendable, Equatable {
    /// Polled at a known rate. Age since the last success is the whole signal.
    case polled(expected: Double)
    /// Polled reliably, but the VALUE refreshes slowly. Two clocks: the poll
    /// must be healthy, and then age since the last value CHANGE is `held`
    /// until it exceeds `refreshBound`.
    case heldValue(pollExpected: Double, refreshBound: Double)
    /// Push. Events arrive only when work happens, so quiet is `absent`
    /// (nothing is happening), never `stale` (something is wrong).
    case eventDriven(quietAfter: Double)
}

/// Everything the decision needs, gathered by the caller.
///
/// Deliberately a plain value: the judgement is a pure function of it, which is
/// what makes the five-state ladder testable without a running collector.
public struct FreshnessInput: Sendable {
    public var now: Instant
    /// When this source last reported successfully. nil = never.
    public var lastOKAt: Instant?
    /// For `.heldValue` only: when the underlying value last actually changed.
    public var lastValueChangedAt: Instant?
    public var consecutiveFailures: Int
    /// The most recent attempt's outcome. nil = no attempt has completed yet,
    /// which is NOT the same as an attempt that failed.
    public var lastOutcome: Outcome?
    public var measuredHz: Double?
    public var jitter: Double?
    /// Whether a source of this kind is there at all. `false` means nothing has
    /// failed — the server is stopped, or this backend exposes no such channel.
    public var exists: Bool
    /// Why it is not there, when the caller knows. Shown verbatim.
    public var absentReason: String?

    public init(now: Instant,
                lastOKAt: Instant? = nil,
                lastValueChangedAt: Instant? = nil,
                consecutiveFailures: Int = 0,
                lastOutcome: Outcome? = nil,
                measuredHz: Double? = nil,
                jitter: Double? = nil,
                exists: Bool = true,
                absentReason: String? = nil) {
        self.now = now
        self.lastOKAt = lastOKAt
        self.lastValueChangedAt = lastValueChangedAt
        self.consecutiveFailures = consecutiveFailures
        self.lastOutcome = lastOutcome
        self.measuredHz = measuredHz
        self.jitter = jitter
        self.exists = exists
        self.absentReason = absentReason
    }
}

extension Freshness {

    /// The five-state ladder, as one pure function.
    public static func judge(_ i: FreshnessInput, policy: FreshnessPolicy) -> Freshness {

        // 1. Nothing there is not a fault. This outranks everything, including
        //    a stale failure record left over from before the source went away.
        if !i.exists { return .absent(i.absentReason ?? "not running") }

        // 2. Repeated failures are a fault under any policy.
        if i.consecutiveFailures >= 3, let o = i.lastOutcome, !o.isOK {
            return .dark(reason: o.shortReason)
        }

        switch policy {

        case .eventDriven(let quietAfter):
            // A push source that has said nothing is not broken. At startup it
            // has simply not seen work yet, and between events it is idle.
            guard let last = i.lastOKAt else {
                return .absent(i.absentReason ?? "no event yet")
            }
            let age = i.now - last
            if age > quietAfter { return .absent(Self.quiet(age)) }
            return .live(hz: i.measuredHz ?? 0, jitter: i.jitter ?? 0)

        case .polled(let expected):
            guard let last = i.lastOKAt else { return coldStart(i) }
            let age = i.now - last
            if age > expected * 10 { return .dark(reason: Self.noSample(age)) }
            if age > expected * 2  { return .stale(age: age) }
            return .live(hz: i.measuredHz ?? 0, jitter: i.jitter ?? 0)

        case .heldValue(let pollExpected, let refreshBound):
            guard let last = i.lastOKAt else { return coldStart(i) }
            // Clock one: is the collector still being answered?
            let pollAge = i.now - last
            if pollAge > pollExpected * 10 { return .dark(reason: Self.noSample(pollAge)) }
            if pollAge > pollExpected * 2  { return .stale(age: pollAge) }
            // Clock two: the poll is healthy, so any age here belongs to the
            // value, not to us. Holding is the normal case, not a degradation.
            guard let changed = i.lastValueChangedAt else {
                return .live(hz: i.measuredHz ?? 0, jitter: i.jitter ?? 0)
            }
            let valueAge = max(0, i.now - changed)
            if valueAge > refreshBound { return .stale(age: valueAge) }
            return .held(age: valueAge)
        }
    }

    /// A source that exists but has not reported yet.
    ///
    /// The distinction that was missing: an attempt that FAILED is a fault, and
    /// no attempt having finished yet is simply no data. Treating both as dark
    /// put a red chip on screen for every source during the first second of
    /// every launch, and permanently on any source whose health is never
    /// emitted at all.
    private static func coldStart(_ i: FreshnessInput) -> Freshness {
        if let o = i.lastOutcome, !o.isOK { return .dark(reason: o.shortReason) }
        return .absent("no sample yet")
    }

    private static func noSample(_ age: Double) -> String {
        "no sample for " + secs(age)
    }

    private static func quiet(_ age: Double) -> String {
        "quiet " + secs(age)
    }

    /// Local so `Telemetry` stays free of any UI dependency.
    private static func secs(_ v: Double) -> String {
        v < 10 ? String(format: "%.1fs", v) : String(format: "%.0fs", v)
    }
}
