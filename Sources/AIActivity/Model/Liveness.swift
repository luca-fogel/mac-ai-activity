import Foundation
import Telemetry

/// A source's freshness. The four states are rendered as visually
/// incommensurable, not merely tinted: a source going dark must never look
/// like a source reading zero.
enum Liveness: Equatable {
    case live(hz: Double, jitter: Double)
    /// The value is real but the source has not refreshed yet — battery power
    /// updates only every few seconds. Full ink, but badged with its age.
    case held(age: Double)
    case stale(age: Double)
    case dark(reason: String)

    var isDark: Bool { if case .dark = self { return true }; return false }
}

/// Tracks measured arrival rates per source. The Hz shown in the UI is
/// measured, not the configured setting — otherwise it would just be
/// restating an assumption.
@MainActor
final class SourceTracker {
    struct State {
        var lastAt: Instant?
        var intervals: [Double] = []
        var lastOutcome: Outcome = .ok
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

    func liveness(_ s: SourceKind, _ e: EngineID?, now: Instant,
                  expected: Double) -> Liveness {
        let k = Self.key(s, e)
        guard let st = states[k], let last = st.lastAt else {
            return .dark(reason: states[k]?.lastOutcome.shortReason ?? "no samples yet")
        }
        if st.consecutiveFailures >= 3 {
            return .dark(reason: st.lastOutcome.shortReason)
        }
        let age = now - last
        let hz = measuredHz(s, e)
        if age > expected * 10 { return .dark(reason: "no sample for \(Fmt.secs(age))") }
        if age > expected * 2  { return .stale(age: age) }
        return .live(hz: hz ?? 0, jitter: jitter(s, e) ?? 0)
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
        return abs(1 / max(mean - sd, 1e-6) - 1 / (mean + sd)) / 2
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
}
