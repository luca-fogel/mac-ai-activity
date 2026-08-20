import Foundation
import Telemetry

/// The five-state ladder now lives in `Telemetry` (see `Freshness.swift`) so it
/// can be tested without a UI. This alias keeps every view's call sites intact.
typealias Liveness = Freshness

/// Tracks measured arrival rates per source. The Hz shown in the UI is
/// measured, not the configured setting — otherwise it would just be
/// restating an assumption.
@MainActor
final class SourceTracker {
    struct State {
        var lastAt: Instant?
        var intervals: [Double] = []
        /// nil until an attempt has actually completed. A failed attempt and a
        /// not-yet-finished attempt are different facts and must not be merged.
        var lastOutcome: Outcome?
        var consecutiveFailures = 0
        var latencies: [Double] = []
    }

    private(set) var states: [String: State] = [:]

    static func key(_ s: SourceKind, _ e: EngineID?) -> String {
        "\(s.rawValue)|\(e?.rawValue ?? "-")"
    }

    func ingest(_ h: SourceHealth) {
        let k = Self.key(h.source, h.engine)
        var st = states[k] ?? State()
        st.lastOutcome = h.outcome
        if h.outcome.isOK {
            if let gap = h.sincePreviousOK, gap > 0, gap < 120 {
                st.intervals.append(gap)
                if st.intervals.count > 24 { st.intervals.removeFirst() }
            }
            st.lastAt = h.t
            st.consecutiveFailures = 0
            st.latencies.append(h.latency)
            if st.latencies.count > 60 { st.latencies.removeFirst() }
        } else {
            st.consecutiveFailures += 1
        }
        states[k] = st
    }

    /// Gathers this source's measured history and hands the judgement to
    /// `Freshness.judge`. The caller supplies what only it can know: whether a
    /// source of this kind is there at all, and — for a slow-refreshing value —
    /// when that value last moved.
    func liveness(_ s: SourceKind, _ e: EngineID?, now: Instant,
                  policy: FreshnessPolicy,
                  exists: Bool = true,
                  absentReason: String? = nil,
                  valueChangedAt: Instant? = nil) -> Liveness {
        let st = states[Self.key(s, e)]
        return Freshness.judge(
            FreshnessInput(now: now,
                           lastOKAt: st?.lastAt,
                           lastValueChangedAt: valueChangedAt,
                           consecutiveFailures: st?.consecutiveFailures ?? 0,
                           lastOutcome: st?.lastOutcome,
                           measuredHz: measuredHz(s, e),
                           jitter: jitter(s, e),
                           exists: exists,
                           absentReason: absentReason),
            policy: policy)
    }

    func measuredHz(_ s: SourceKind, _ e: EngineID?) -> Double? {
        guard let iv = states[Self.key(s, e)]?.intervals, !iv.isEmpty else { return nil }
        let mean = iv.reduce(0, +) / Double(iv.count)
        return mean > 0 ? 1 / mean : nil
    }

    func jitter(_ s: SourceKind, _ e: EngineID?) -> Double? {
        guard let iv = states[Self.key(s, e)]?.intervals, iv.count > 2 else { return nil }
        let mean = iv.reduce(0, +) / Double(iv.count)
        let varr = iv.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(iv.count)
        guard mean > 0 else { return nil }
        // Convert interval sigma to an Hz-space spread.
        let sd = varr.squareRoot()
        // Guard the reciprocal: when sd approaches mean, 1/(mean-sd) explodes
        // and produced a nonsense "+/-499999.8 Hz" on screen.
        guard sd < mean * 0.9, mean > 1e-3 else { return nil }
        let hi = 1 / (mean - sd), lo = 1 / (mean + sd)
        let j = (hi - lo) / 2
        return j.isFinite && j < 1000 ? j : nil
    }

    func latencyP50(_ s: SourceKind, _ e: EngineID?) -> Double? {
        guard var l = states[Self.key(s, e)]?.latencies, !l.isEmpty else { return nil }
        l.sort(); return l[l.count / 2]
    }

    func intervals(_ s: SourceKind, _ e: EngineID?) -> [Double] {
        states[Self.key(s, e)]?.intervals ?? []
    }

    func lastOutcome(_ s: SourceKind, _ e: EngineID?) -> Outcome? {
        states[Self.key(s, e)]?.lastOutcome
    }

    // MARK: - Value-change cadence, which is NOT the poll cadence

    /// Observed refresh intervals of a slow-changing VALUE, tracked separately
    /// from the poll intervals above.
    ///
    /// Power is the motivating case: we poll at 0.2 Hz but the value moves on
    /// AppleSmartBattery's own ~4 s schedule, and the only honest bound on "how
    /// long is too long" is how long this source has actually been observed to
    /// take. The previous hardcoded 30 s was a guess in both directions.
    private var valueChanges: [String: (last: Instant, gaps: [Double])] = [:]

    /// Call with the source's own "last changed" timestamp. Repeat calls with
    /// an unchanged timestamp are ignored, which is what makes this a record of
    /// changes rather than of polls.
    func noteValueChange(_ s: SourceKind, _ e: EngineID?, changedAt: Instant) {
        let k = Self.key(s, e)
        guard var rec = valueChanges[k] else {
            valueChanges[k] = (last: changedAt, gaps: [])
            return
        }
        guard changedAt != rec.last else { return }
        let gap = changedAt - rec.last
        if gap > 0, gap < 300 {
            rec.gaps.append(gap)
            if rec.gaps.count > 24 { rec.gaps.removeFirst() }
        }
        rec.last = changedAt
        valueChanges[k] = rec
    }

    /// How long this value may sit unchanged before the silence is itself
    /// suspicious. nil until there is enough history to say anything, in which
    /// case the caller must supply its own documented default.
    func valueRefreshBound(_ s: SourceKind, _ e: EngineID?) -> Double? {
        guard let gaps = valueChanges[Self.key(s, e)]?.gaps, gaps.count > 2,
              let longest = gaps.max(), longest > 0 else { return nil }
        // 3x the longest gap actually seen. The question is "is this longer
        // than this source has ever taken?", not "longer than average" — a mean
        // would flag every ordinary slow tick.
        return longest * 3
    }

    func valueRefreshGaps(_ s: SourceKind, _ e: EngineID?) -> [Double] {
        valueChanges[Self.key(s, e)]?.gaps ?? []
    }
}
