import Foundation

/// Derives per-slot metrics from a sparse, jittery /slots stream.
///
/// The governing rule, which eliminates an entire class of silent corruption:
/// **rates are computed ONLY across two consecutive observations that are both
/// `.processing` and carry the SAME `id_task`.** Any other transition resets
/// the accumulator. Without it, a previously-used idle slot's frozen counters
/// get differenced against a new request's counters and produce a plausible,
/// completely fictional throughput number.
public struct SlotStateMachine: Sendable {

    struct Point { var t: Instant; var decoded: Int }

    struct Track {
        var idTask: Int?
        var firstSeenActive: Instant?
        var lastIdleObservation: Instant?   // lower bound for the TTFT interval
        var firstTokenAt: Instant?
        var window: [Point] = []
        var lastDecoded: Int?
        var lastAdvanceAt: Instant?
        var prefillProcessed: Int?
        var prefillCached: Int?
        /// n_decoded is only trustworthy once we have seen it reset for THIS
        /// request. Until then it is the previous request's leftover.
        var decodeTrusted = false
        var lastProcessed: Int?
        /// Last time ANY counter moved. A busy slot where neither prompt
        /// processing nor decoding advances is stuck, and must be shown as
        /// stuck rather than averaged into throughput -- during prefill just
        /// as much as during decode.
        var lastAnyAdvanceAt: Instant?
        var lastPromptTokens: Int?
    }

    /// Seconds of history used for the least-squares decode-rate slope.
    private let windowSeconds: Double = 10
    /// A slot claiming to process while n_decoded is frozen for this long is
    /// reported as stalled, never averaged into throughput.
    private let stallSeconds: Double = 5

    private var tracks: [Int: Track] = [:]

    public init() {}

    /// Called when the endpoint generation changes (Bionic re-spawned the
    /// server). Carrying tracks across would emit a garbage rate spike.
    public mutating func reset() { tracks.removeAll() }

    public mutating func update(_ raw: LlamaSlotsClient.RawSlot,
                                at t: Instant,
                                fittedContext: Int?) -> SlotSample {

        // ---- classify. The three payload shapes are genuinely different. ----
        var tr = tracks[raw.id] ?? Track()

        // ---- request boundary (before anything derived) ----
        let boundary = (raw.idTask != tr.idTask) && raw.idTask != nil
        if raw.isProcessing && (boundary || tr.firstSeenActive == nil) {
            let priorIdle = tr.lastIdleObservation
            tr = Track()
            tr.idTask = raw.idTask
            tr.firstSeenActive = t
            tr.lastIdleObservation = priorIdle
        }

        // ---- is n_decoded trustworthy yet? ----
        // It is NOT reset at request start; it holds the previous request's
        // value for the whole of prefill. Two signals say decode has begun:
        // the counter finally dropping, or prompt processing having stopped
        // while the counter climbs from a low base.
        if raw.isProcessing, raw.idTask == tr.idTask, let d = raw.nDecoded, !tr.decodeTrusted {
            if let last = tr.lastDecoded, d < last {
                tr.decodeTrusted = true
                tr.lastDecoded = nil
                tr.window.removeAll()
            } else if let lp = tr.lastProcessed,
                      raw.nPromptTokensProcessed == lp,
                      let last = tr.lastDecoded, d > last, d < 64 {
                tr.decodeTrusted = true
            }
        }
        if raw.isProcessing {
            let moved = raw.nPromptTokensProcessed != tr.lastProcessed
                || raw.nPromptTokens != tr.lastPromptTokens
                || (tr.decodeTrusted && raw.nDecoded != tr.lastDecoded)
            if moved || tr.lastAnyAdvanceAt == nil { tr.lastAnyAdvanceAt = t }
        }
        tr.lastProcessed = raw.nPromptTokensProcessed
        tr.lastPromptTokens = raw.nPromptTokens
        if !tr.decodeTrusted { tr.lastDecoded = raw.nDecoded }

        // ---- classify (three payload shapes, plus the prefill phase) ----
        let state: SlotState
        if raw.isProcessing {
            state = tr.decodeTrusted ? .processing : .prefilling
        } else if raw.hasCounters {
            state = .idleWithHistory
        } else {
            state = .neverUsed
        }

        if !state.isBusy {
            tr.lastIdleObservation = t
            if state == .idleWithHistory { tr.idTask = raw.idTask }
        }

        // ---- accumulate, only while genuinely decoding on the same task ----
        var stalled = false
        if state.isBusy, let la = tr.lastAnyAdvanceAt, t - la > stallSeconds { stalled = true }
        if state == .processing, raw.idTask == tr.idTask, let d = raw.nDecoded {
            if let last = tr.lastDecoded, d < last {
                // Reused between polls without an observed boundary.
                tr.window.removeAll()
                tr.firstSeenActive = t
            }
            if tr.firstTokenAt == nil && d > 0 { tr.firstTokenAt = t }
            if let last = tr.lastDecoded, d > last { tr.lastAdvanceAt = t }
            else if tr.lastAdvanceAt == nil { tr.lastAdvanceAt = t }

            tr.lastDecoded = d
            tr.window.append(Point(t: t, decoded: d))
            tr.window.removeAll { t - $0.t > windowSeconds }

            if let la = tr.lastAdvanceAt, t - la > stallSeconds { stalled = true }

            if tr.prefillProcessed == nil { tr.prefillProcessed = raw.nPromptTokensProcessed }
            if tr.prefillCached == nil { tr.prefillCached = raw.nPromptTokensCache }
        }

        tracks[raw.id] = tr

        // ---- derive ----
        let decodeRate = Self.slope(tr.window, stalled: stalled, state: state)
        // Never surface the stale counter.
        let trustedDecoded = tr.decodeTrusted ? raw.nDecoded : nil
        let ttft = Self.ttftInterval(tr)
        let prefill = Self.prefillRate(tr, state: state)
        let cache = Self.cacheHitRate(processed: raw.nPromptTokensProcessed,
                                      cached: raw.nPromptTokensCache,
                                      state: state)

        return SlotSample(
            id: raw.id, state: state,
            nCtxReported: raw.nCtx, nCtxFitted: fittedContext,
            speculative: raw.speculative, specTypes: raw.specTypes, idTask: raw.idTask,
            nPromptTokens: raw.nPromptTokens,
            nPromptTokensProcessed: raw.nPromptTokensProcessed,
            nPromptTokensCache: raw.nPromptTokensCache,
            nDecoded: trustedDecoded, nRemain: raw.nRemain,
            hasNextToken: raw.hasNextToken, sampler: raw.sampler,
            decodeTokensPerSecond: decodeRate,
            prefillTokensPerSecond: prefill,
            timeToFirstToken: ttft,
            cacheHitRate: cache)
    }

    // MARK: - Derivations

    /// Least-squares slope over the window, not an instantaneous delta.
    ///
    /// /slots latency swings 100-450 ms, so a single Δ/Δt carries roughly ±22%
    /// error against a 1 s poll. The regression collapses that; the raw points
    /// still go to the UI for the trace.
    static func slope(_ pts: [Point], stalled: Bool, state: SlotState) -> Estimate<Double> {
        if stalled { return .unavailable("slot stalled — n_decoded frozen") }
        if state == .prefilling {
            return .unavailable("prefilling — n_decoded still holds the previous request's value")
        }
        if state != .processing { return .unavailable("slot is not generating") }
        if stalled { return .unavailable("slot stalled — n_decoded frozen") }
        guard pts.count >= 2 else { return .unavailable("need 2 samples") }
        let t0 = pts[0].t.s
        let xs = pts.map { $0.t.s - t0 }, ys = pts.map { Double($0.decoded) }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in 0..<xs.count { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
        guard sxx > 1e-9 else { return .unavailable("samples too close in time") }
        let slope = sxy / sxx

        // Standard error of the slope -> honest uncertainty.
        var sse = 0.0
        let b = my - slope * mx
        for i in 0..<xs.count { let r = ys[i] - (slope * xs[i] + b); sse += r * r }
        let se = xs.count > 2 ? (sse / Double(xs.count - 2) / sxx).squareRoot() : Double.nan

        if pts.count < 5 || !se.isFinite {
            return .low(max(0, slope), uncertainty: se.isFinite ? se : nil, n: pts.count)
        }
        return Estimate(value: max(0, slope), uncertainty: se,
                        sampleCount: pts.count, confidence: .high)
    }

    /// TTFT is fundamentally a client-side metric and we are not the client.
    /// We can only bound it: the request began somewhere between the last idle
    /// poll and the first active poll. Published as an interval, never a point.
    static func ttftInterval(_ tr: Track) -> Estimate<Double> {
        guard let first = tr.firstSeenActive, let tok = tr.firstTokenAt else {
            return .unavailable("no first token observed")
        }
        let hi = tok - (tr.lastIdleObservation ?? first)
        let lo = tok - first
        guard hi >= lo, hi.isFinite else { return .unavailable("bounds unusable") }
        return .bounded(Interval(lo: max(0, lo), hi: max(0, hi)))
    }

    static func prefillRate(_ tr: Track, state: SlotState) -> Estimate<Double> {
        guard let processed = tr.prefillProcessed, processed > 0,
              let start = tr.firstSeenActive, let tok = tr.firstTokenAt else {
            return .unavailable("prefill not observed")
        }
        let dt = tok - start
        // At 1 Hz the prefill phase is often shorter than one sample interval.
        guard dt > 0.05 else {
            return .unavailable("prefill shorter than the poll interval")
        }
        return .low(Double(processed) / dt, n: 2)
    }

    /// cache / (cache + processed).
    ///
    /// NOT cache / n_prompt_tokens: n_prompt_tokens keeps growing during decode
    /// (it is total context), so that denominator makes the hit rate silently
    /// decay toward zero over a long generation. Both of these freeze after
    /// prefill, so this is correct at ANY sample of an active or just-finished
    /// slot with no latching required.
    static func cacheHitRate(processed: Int?, cached: Int?, state: SlotState) -> Estimate<Double> {
        guard state != .neverUsed else { return .unavailable("slot never used") }
        guard let p = processed, let c = cached else {
            return .unavailable("prefill counters absent")
        }
        let total = p + c
        guard total > 0 else { return .unavailable("no prompt tokens") }
        return .high(Double(c) / Double(total))
    }
}
