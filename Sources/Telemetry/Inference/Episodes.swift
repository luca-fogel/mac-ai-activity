import Foundation

/// One observed generation, from the moment work starts to the moment it stops.
///
/// This exists because MLX exposes no per-token telemetry at all — no /slots, no
/// port, nothing in Bionic's logs (checked). But an episode's *envelope* is
/// fully observable from the native domain: how long it ran, how hard the GPU
/// worked, and how much energy it burned. That makes GGUF and MLX comparable on
/// duration and energy even when only one of them can report tokens.
public struct Episode: Identifiable, Sendable {
    public let id: Int
    public var backend: String
    public var model: String
    public var start: Instant
    public var end: Instant?

    /// nil for any runtime without token telemetry — never 0.
    public var tokens: Int?
    /// When decode began, if the backend let us see the phase boundary.
    public var prefillEnded: Instant?

    public var peakGPU: Double = 0
    public var gpuSum: Double = 0
    public var gpuSamples: Int = 0
    /// Integrated from the power trace. Coarse, because the power source
    /// refreshes only every few seconds — reported as low confidence.
    public var energyJoules: Double = 0
    public var energySamples: Int = 0

    // MARK: Engine-reported figures (end of prediction only)

    /// Exact, from the engine's own stats block — but knowable only once the
    /// generation is over, and an AVERAGE over it. Kept in separate fields from
    /// the derived ones on purpose: merging an exact retrospective figure with a
    /// sampled live one would make it impossible to say which you are looking at.
    public var reportedTokensPerSecond: Double?
    /// The one exact TTFT in the app: the engine was the client.
    public var reportedTTFT: Double?
    public var reportedStopReason: String?
    /// Which command vouches for the reported figures.
    public var reportedBy: String?

    // MARK: True energy integral (raw units — see the doc below)

    /// `AccumulatedSystemEnergyConsumed` at the episode's first and last power
    /// sample. Differencing these is a TRUE integral over the interval, which
    /// beats multiplying a value that only refreshes every ~4 s by dt.
    ///
    /// Published in RAW UNITS and deliberately not converted: the scale of that
    /// IOKit key is undocumented, and guessing it would put a confidently wrong
    /// joule figure on screen. Both this and `energyJoules` are carried until
    /// they have been calibrated against each other — see
    /// `telemetry-probe --live`, which prints the implied ratio.
    public var energyAccumStart: UInt64?
    public var energyAccumEnd: UInt64?
    /// The accumulator went backwards inside this episode — a counter reset or
    /// wraparound — so the interval is not usable. There is no handling for
    /// this anywhere else, and a negative energy would be worse than none.
    public var energyAccumInvalid = false

    // MARK: Thermal envelope

    /// Hottest die reading seen inside this generation, and where.
    ///
    /// Sampled at 1 Hz against a several-second thermal constant, so a
    /// generation shorter than ~2 s legitimately has none — which is why this
    /// is optional rather than seeded with the temperature at the start.
    public var peakHotspotC: Double?
    public var peakHotspotDomain: ThermalDomain?
    public var startHotspotC: Double?
    public var thermalSamples: Int = 0
    /// Fastest fan observed during the generation, and whether the app was the
    /// one commanding it. A tok/s figure measured under a forced fan is not
    /// comparable with one measured under the SMC's own curve, and this is what
    /// lets the Episodes view say so.
    public var peakFanRPM: Double?
    public var fansForced = false
    /// The OS escalated thermal pressure at some point inside this generation:
    /// the strongest evidence available that a slow run was slow because of heat.
    public var worstPressure: ThermalState = .nominal

    /// How much the die heated over the generation. nil unless both ends were
    /// observed, because a rise computed from one sample is not a rise.
    public var hotspotRiseC: Double? {
        guard let a = startHotspotC, let b = peakHotspotC, thermalSamples >= 2 else { return nil }
        return b - a
    }

    public var duration: Double? { end.map { $0 - start } }

    /// The accumulator's delta in RAW units, or nil when unusable. Not joules.
    public var accumulatedEnergyDelta: UInt64? {
        guard !energyAccumInvalid,
              let a = energyAccumStart, let b = energyAccumEnd, b >= a else { return nil }
        return b - a
    }

    /// Raw accumulator units per trapezoidal joule, for calibrating the two
    /// against each other. Once this is stable across episodes, the accumulator
    /// can replace the trapezoidal estimate; until then it is evidence, not a
    /// measurement.
    public var energyUnitRatio: Double? {
        guard let d = accumulatedEnergyDelta, energyJoules > 1 else { return nil }
        return Double(d) / energyJoules
    }
    public var meanGPU: Double { gpuSamples > 0 ? gpuSum / Double(gpuSamples) : 0 }

    public var prefillSeconds: Double? {
        guard let p = prefillEnded else { return nil }
        return p - start
    }

    /// Energy per token, when tokens are knowable at all.
    public var joulesPerToken: Estimate<Double> {
        guard let t = tokens, t > 0 else {
            return .unavailable("this backend reports no token count")
        }
        guard energySamples >= 1 else {
            return .unavailable("no power interval inside this generation")
        }
        return .low(energyJoules / Double(t), n: energySamples)
    }

    public var energy: Estimate<Double> {
        energySamples >= 1 ? .low(energyJoules, n: energySamples)
                           : .unavailable("no power interval inside this generation")
    }
}

/// Builds episodes from the live streams. In memory only, capped — nothing here
/// is persisted, matching the app's live-display-only constraint.
public struct EpisodeTracker: Sendable {
    public init() {}
    public private(set) var episodes: [Episode] = []
    private var nextID = 1
    private var lastPowerAt: Instant?
    private var lastWatts: Double?
    private let cap = 24

    public var current: Episode? {
        guard let last = episodes.last, last.end == nil else { return nil }
        return last
    }

    public mutating func note(generating: Bool, backend: String, model: String, at t: Instant) {
        if generating {
            if current == nil {
                episodes.append(Episode(id: nextID, backend: backend, model: model, start: t))
                nextID += 1
                if episodes.count > cap { episodes.removeFirst(episodes.count - cap) }
            }
        } else if var open = current {
            open.end = t
            episodes[episodes.count - 1] = open
            lastWatts = nil
            lastPowerAt = nil
        }
    }

    public mutating func noteGPU(_ util: Double?, at t: Instant) {
        guard let u = util, var e = current else { return }
        e.peakGPU = max(e.peakGPU, u)
        e.gpuSum += u
        e.gpuSamples += 1
        episodes[episodes.count - 1] = e
    }

    /// Trapezoidal integration of the power trace.
    public mutating func noteWatts(_ w: Double?, at t: Instant) {
        defer { lastWatts = w; lastPowerAt = t }
        guard let w, var e = current, let pw = lastWatts, let pt = lastPowerAt else { return }
        let dt = t - pt
        guard dt > 0, dt < 30 else { return }
        e.energyJoules += (w + pw) / 2 * dt
        e.energySamples += 1
        episodes[episodes.count - 1] = e
    }

    /// Folds one thermal tick into the open episode.
    ///
    /// Nothing here is interpolated: with no open episode there is nothing to
    /// record, and a generation that ended between two thermal ticks simply has
    /// fewer samples, which `thermalSamples` reports.
    public mutating func noteThermal(hotspotC: Double?,
                                     domain: ThermalDomain?,
                                     fanRPM: Double?,
                                     fansForced: Bool,
                                     pressure: ThermalState,
                                     at t: Instant) {
        guard var e = current else { return }
        if let c = hotspotC {
            if e.startHotspotC == nil { e.startHotspotC = c }
            if c > (e.peakHotspotC ?? -.infinity) {
                e.peakHotspotC = c
                e.peakHotspotDomain = domain
            }
            e.thermalSamples += 1
        }
        if let f = fanRPM { e.peakFanRPM = max(e.peakFanRPM ?? 0, f) }
        if fansForced { e.fansForced = true }
        if pressure.severity > e.worstPressure.severity { e.worstPressure = pressure }
        episodes[episodes.count - 1] = e
    }

    /// Attaches an engine-reported receipt to the generation it describes.
    ///
    /// The receipt lands at the END of a prediction, and by then the episode may
    /// already have closed: busy/idle is observed on the roster's 0.2 Hz clock,
    /// so the boundary can be crossed in either order. Attaching to a
    /// just-closed episode inside a grace window is therefore correct.
    ///
    /// A receipt never CREATES an episode. The stream is instance-wide and
    /// carries no caller identity, so a prediction driven by some other process
    /// is indistinguishable from ours — and we would know nothing about its
    /// envelope. An unattributable receipt is dropped rather than invented into
    /// an episode with no GPU or power trace behind it.
    @discardableResult
    public mutating func noteReceipt(tokens: Int?,
                                     tokensPerSecond: Double?,
                                     ttft: Double?,
                                     stopReason: String,
                                     reportedBy: String,
                                     at t: Instant,
                                     grace: Double = 15) -> Bool {
        guard let i = episodes.indices.last else { return false }
        var e = episodes[i]
        if let end = e.end, t - end > grace { return false }
        if let n = tokens { e.tokens = max(e.tokens ?? 0, n) }
        e.reportedTokensPerSecond = tokensPerSecond
        e.reportedTTFT = ttft
        e.reportedStopReason = stopReason
        e.reportedBy = reportedBy
        episodes[i] = e
        return true
    }

    /// Samples the monotonic energy accumulator at the episode's boundaries.
    public mutating func noteAccumulatedEnergy(_ raw: UInt64?, at t: Instant) {
        guard let raw, var e = current else { return }
        if e.energyAccumStart == nil {
            e.energyAccumStart = raw
        } else if let last = e.energyAccumEnd ?? e.energyAccumStart, raw < last {
            // Reset or wraparound: the interval is no longer an integral.
            e.energyAccumInvalid = true
        }
        e.energyAccumEnd = raw
        episodes[episodes.count - 1] = e
    }

    public mutating func noteTokens(_ n: Int?, prefillEnded: Instant?) {
        guard var e = current else { return }
        if let n { e.tokens = max(e.tokens ?? 0, n) }
        if e.prefillEnded == nil, let p = prefillEnded { e.prefillEnded = p }
        episodes[episodes.count - 1] = e
    }

    /// Newest first, completed episodes only.
    public var completed: [Episode] { episodes.filter { $0.end != nil }.reversed() }
}
