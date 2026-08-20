import Foundation

/// A rolling record of whole-system wattage, integrable over an arbitrary past
/// window.
///
/// This exists because of the shape of the only per-token telemetry MLX has.
/// LM Studio reports a prediction once it is FINISHED, and tells us how long it
/// took (`totalTimeSec`) — so the generation's interval is known exactly, but
/// only in retrospect. Integrating power over that interval afterwards is
/// strictly better than what the GUI did, which was to open and close an
/// "episode" on the roster's 0.2 Hz busy signal and therefore miss any
/// generation shorter than one poll. MEASURED: a 131-token generation finished
/// in ~2.2 s and left no envelope at all.
///
/// Two honesty constraints:
///   * A window is only integrable if the trace actually COVERS it. Asking for
///     energy over a generation that began before this process started must
///     return `.unavailable`, not a partial integral silently presented as a
///     whole one.
///   * Confidence is never `.high`. AppleSmartBattery refreshes every ~4 s, so
///     between two readings the true draw is unknown and the trapezoid is an
///     approximation — a short generation may sit entirely inside one held
///     value.
public struct PowerTrace: Sendable {

    public struct Reading: Sendable, Equatable {
        public var t: Instant
        public var watts: Double
        public init(t: Instant, watts: Double) { self.t = t; self.watts = watts }
    }

    private var readings: [Reading] = []
    private var busyWindows: [(from: Instant, to: Instant)] = []
    private let capacity: Int

    public init(capacity: Int = 8192) { self.capacity = capacity }

    public var count: Int { readings.count }
    public var latest: Reading? { readings.last }
    public var span: Double? {
        guard let f = readings.first, let l = readings.last else { return nil }
        return l.t - f.t
    }

    /// `nil` watts is dropped, not stored as 0 — on AC the source genuinely has
    /// no number, and a zero would integrate to a free lunch.
    public mutating func note(_ watts: Double?, at t: Instant) {
        guard let w = watts, w.isFinite, w > 0 else { return }
        readings.append(Reading(t: t, watts: w))
        if readings.count > capacity { readings.removeFirst(readings.count - capacity) }
    }

    /// Records that a generation occupied this window, so the idle floor can
    /// exclude it. Called with the same window that gets integrated.
    public mutating func markBusy(from: Instant, to: Instant) {
        busyWindows.append((from, to))
        if busyWindows.count > 256 { busyWindows.removeFirst(busyWindows.count - 256) }
    }

    /// Trapezoidal integral of watts over [from, to], in joules.
    ///
    /// Endpoints are interpolated from the bracketing readings so that a window
    /// shorter than the sampling interval still yields the right answer rather
    /// than nothing.
    /// How far past the last reading a window may extend and still be judged
    /// covered.
    ///
    /// The trailing edge is a sampling-phase artifact, not missing data: a
    /// generation ends when it ends, while our last sample landed up to one
    /// interval earlier. Holding the last value across a sub-second tail is
    /// exactly the semantics of a source that only refreshes every ~4 s. The
    /// LEADING edge gets no such tolerance — a window starting before the trace
    /// is genuinely unobserved, and a partial integral presented as a whole one
    /// would understate energy and therefore understate joules per token.
    public static let trailingTolerance: Double = 1.5

    public func energy(from: Instant, to: Instant) -> Estimate<Double> {
        guard to.s > from.s else {
            return .unavailable("generation window has no duration")
        }
        guard let first = readings.first, let last = readings.last else {
            return .unavailable("no power readings — on AC the source reports no wattage")
        }
        // Coverage is a precondition, not a detail: a partial integral presented
        // as a whole one is exactly the class of lie this is built to avoid.
        guard first.t.s <= from.s else {
            return .unavailable(String(format: "power trace began %.1fs after this generation started",
                                       first.t - from))
        }
        guard last.t.s >= to.s - Self.trailingTolerance else {
            return .unavailable(String(format: "power trace ends %.1fs before this generation finished",
                                       to - last.t))
        }

        var points: [Reading] = [Reading(t: from, watts: interpolate(at: from))]
        points.append(contentsOf: readings.filter { $0.t.s > from.s && $0.t.s < to.s })
        points.append(Reading(t: to, watts: interpolate(at: to)))

        var joules = 0.0
        for i in 1..<points.count {
            let dt = points[i].t - points[i - 1].t
            guard dt > 0 else { continue }
            joules += (points[i].watts + points[i - 1].watts) / 2 * dt
        }
        guard joules > 0 else { return .unavailable("integrated to zero energy") }
        // Never .high: the source refreshes every ~4 s, so the interior of every
        // interval is interpolated rather than measured.
        return .low(joules, n: points.count)
    }

    /// Linear value at an arbitrary time, from the readings bracketing it.
    private func interpolate(at t: Instant) -> Double {
        guard let first = readings.first else { return 0 }
        if t.s <= first.t.s { return first.watts }
        guard let last = readings.last else { return 0 }
        if t.s >= last.t.s { return last.watts }
        var lo = first
        for r in readings {
            if r.t.s <= t.s { lo = r; continue }
            let dt = r.t - lo.t
            guard dt > 0 else { return r.watts }
            let f = (t - lo.t) / dt
            return lo.watts + (r.watts - lo.watts) * f
        }
        return last.watts
    }

    /// The lowest draw observed while nothing was generating.
    ///
    /// Reported separately because the marginal cost of inference — draw above
    /// this floor — is far more interesting than total draw, and is invisible
    /// without a baseline. Windows known to contain a generation are excluded,
    /// so a session that was busy throughout honestly has no floor.
    public var idleFloor: Estimate<Double> {
        let quiet = readings.filter { r in
            !busyWindows.contains { r.t.s >= $0.from.s && r.t.s <= $0.to.s }
        }
        guard quiet.count >= 3, let floor = quiet.map(\.watts).min() else {
            return .unavailable("not enough idle time observed to establish a floor")
        }
        return .low(floor, n: quiet.count)
    }

    /// Mean draw across the window, for display alongside the integral.
    public func meanWatts(from: Instant, to: Instant) -> Double? {
        guard let e = energy(from: from, to: to).value else { return nil }
        let dt = to - from
        return dt > 0 ? e / dt : nil
    }
}
