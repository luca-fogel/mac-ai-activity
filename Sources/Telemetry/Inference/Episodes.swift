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

    public var duration: Double? { end.map { $0 - start } }
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

    public mutating func noteTokens(_ n: Int?, prefillEnded: Instant?) {
        guard var e = current else { return }
        if let n { e.tokens = max(e.tokens ?? 0, n) }
        if e.prefillEnded == nil, let p = prefillEnded { e.prefillEnded = p }
        episodes[episodes.count - 1] = e
    }

    /// Newest first, completed episodes only.
    public var completed: [Episode] { episodes.filter { $0.end != nil }.reversed() }
}
