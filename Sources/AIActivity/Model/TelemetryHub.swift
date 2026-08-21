import Foundation
import Observation
import Telemetry

/// The UI-facing store. Owns all history; collectors own none.
///
/// Views never read the ring buffers directly — they read `revision` and
/// prepared column sets. With @Observable, touching any stored property
/// invalidates every view that read it, so a 10 Hz field read by a chart would
/// re-lay-out the whole chart every tick.
@MainActor
@Observable
final class TelemetryHub {

    // ~300 s of history at each stream's own rate. In memory only.
    //
    // @ObservationIgnored is load-bearing, not a micro-optimisation: as plain
    // @Observable properties, every append at 10 Hz invalidated every view that
    // had ever read them, so the coalescing flusher below never actually
    // coalesced anything. Measured cost of getting this wrong: 17.2% of one
    // core versus 0.03% for the collectors it was supposed to be measuring.
    @ObservationIgnored private(set) var gpuSeries = Series<Double?>(capacity: 3_000)
    @ObservationIgnored private(set) var sysTimes: [Double] = []
    /// The sparse inference track: one entry per actual /slots response.
    @ObservationIgnored private(set) var rateSeries = Series<Double?>(capacity: 600)
    @ObservationIgnored private(set) var wattSeries = Series<Double?>(capacity: 300)
    /// Die hotspot and fan rpm, 1 Hz. Their own series because they are their
    /// own domain: 1 Hz against the system domain's 10 Hz, and never resampled
    /// onto it.
    @ObservationIgnored private(set) var tempSeries = Series<Double?>(capacity: 600)
    @ObservationIgnored private(set) var fanSeries = Series<Double?>(capacity: 600)

    /// The single observed value. Replaced once per flush, so a view that
    /// reads anything through it is invalidated exactly once per redraw.
    struct Snapshot {
        var system: SystemSample?
        /// Per engine. A single slot here meant whichever engine polled last
        /// overwrote the other, so an alternating GGUF/MLX workload showed
        /// whichever happened to report most recently.
        var inference: [EngineID: InferenceSample] = [:]
        var power: PowerSample?
        var roster: [RuntimeInfo] = []
        /// The most recent engine-reported receipt, per engine. Retrospective:
        /// it describes a generation that has ALREADY FINISHED and must never be
        /// rendered where a live reading goes.
        var lastPrediction: [EngineID: PredictionSample] = [:]
        var thermal: ThermalSample?
        var revision: Int = 0
        var slotPollCount = 0
        var slotServerMillis: Double = 0
    }
    private(set) var snapshot = Snapshot()

    // Views keep their old, readable call sites; the observation funnel is the
    // snapshot underneath.
    var roster: [RuntimeInfo] { snapshot.roster }
    var latestSystem: SystemSample? { snapshot.system }
    /// Most recent sample from any engine, newest first.
    var latestInference: InferenceSample? {
        snapshot.inference.values.max { $0.t < $1.t }
    }
    var inferenceByEngine: [EngineID: InferenceSample] { snapshot.inference }
    var latestPower: PowerSample? { snapshot.power }
    var latestThermal: ThermalSample? { snapshot.thermal }
    /// The helper's live view, or nil when there is no helper — which is the
    /// app's default, read-only state and not a fault.
    var cooling: CoolingStatus? { snapshot.thermal?.control }
    /// Newest receipt from any engine. Newest-first, and always about the past.
    var lastPrediction: PredictionSample? {
        snapshot.lastPrediction.values.max { $0.t < $1.t }
    }
    func lastPrediction(_ e: EngineID) -> PredictionSample? { snapshot.lastPrediction[e] }
    var revision: Int { snapshot.revision }
    var slotPollCount: Int { snapshot.slotPollCount }
    var slotServerMillis: Double { snapshot.slotServerMillis }

    @ObservationIgnored private var pending = Snapshot()

    @ObservationIgnored let sources = SourceTracker()
    @ObservationIgnored private var feed: (any TelemetryFeed)?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var flusher: Task<Void, Never>?
    @ObservationIgnored private var dirty = false

    private(set) var cadence: CadenceMode = .adaptive
    @ObservationIgnored private(set) var startedAt = Instant.now()

    /// Rolling receipts for the observer-effect readout.
    @ObservationIgnored private var pollLog: [(t: Instant, ms: Double)] = []
    /// When each engine was last observed doing work. Without this, an idle
    /// machine with two models resident always showed the LARGEST one, so the
    /// header sat on llama.cpp's 21 GB model forever even when every recent
    /// generation had run on mlx-lm.
    @ObservationIgnored private(set) var lastBusyAt: [EngineID: Instant] = [:]

    var now: Instant { Instant.now() }

    func attach(_ feed: any TelemetryFeed) {
        self.feed = feed
        pump?.cancel()
        pump = Task { [weak self] in
            await feed.start()
            for await s in feed.samples {
                guard let self else { break }
                await self.ingest(s)
            }
        }
        flusher?.cancel()
        flusher = Task { [weak self] in
            // Adaptive REDRAW rate. Sampling is unaffected -- the ring buffers
            // still fill at the collectors' full rate, so no history is lost.
            // Only how often SwiftUI re-lays-out the window changes.
            //
            // Measured: collectors 0.40% of one core, a static window 0.20%,
            // and a live window ~9.8%. The cost is per-redraw layout work, so
            // this is the only lever that matters. Idle redraws at 1 Hz (Activity
            // Monitor's own cadence); generating redraws at 5 Hz. Measured: 10 Hz
            // display cost 16.7% of a core, 5 Hz ~8%, 1 Hz 2.3%.
            while !Task.isCancelled {
                let hz: UInt64 = await MainActor.run { [weak self] in
                    (self?.isGenerating ?? false) ? 200_000_000 : 1_000_000_000
                }
                try? await Task.sleep(nanoseconds: hz)
                guard let self else { break }
                self.flush()
            }
        }
    }

    /// Mirrors the controller's policy so the UI has something observable to
    /// bind to. The controller remains the source of truth — this is a copy,
    /// and it is written only here.
    private(set) var coolingPolicy: CoolingPolicy = .system

    var coolingAvailable: Bool { feed?.cooling?.isInstalled ?? false }
    var coolingError: String? { feed?.cooling?.error }

    func setCoolingPolicy(_ p: CoolingPolicy) {
        coolingPolicy = p
        feed?.cooling?.setPolicy(p)
    }

    func setCadence(_ m: CadenceMode) {
        cadence = m
        let f = feed
        Task { await f?.setCadence(m) }
    }

    func detach() {
        pump?.cancel(); flusher?.cancel()
        let f = feed
        Task { await f?.stop() }
    }

    /// An instrument nobody is looking at should cost nothing. When the window
    /// is occluded we stop publishing entirely; the collectors keep running at
    /// ~31 us/tick so no history is lost, but SwiftUI does no work at all.
    @ObservationIgnored private var visible = true

    func setVisible(_ v: Bool) {
        guard v != visible else { return }
        visible = v
        if v { dirty = true; flush() }
    }

    private func flush() {
        guard visible, dirty else { return }
        dirty = false
        pending.revision &+= 1
        snapshot = pending          // ONE observation event per redraw
    }

    private func ingest(_ s: Sample) {
        switch s {
        case .system(let v):
            gpuSeries.append(t: v.t.s, v.gpuDevice)
            sysTimes = gpuSeries.times
            pending.system = v
            tracker.noteGPU(v.gpuDevice, at: v.t)
            refreshEpisodes(at: v.t)
        case .inference(let v):
            if v.slots.contains(where: { $0.state.isBusy }) { lastBusyAt[v.engine] = v.t }
            if let busy = v.slots.first(where: { $0.state == .processing }) {
                tracker.noteTokens(busy.nDecoded, prefillEnded: v.t)
            }
            rateSeries.append(t: v.t.s,
                              v.slots.first { $0.state == .processing }?
                                     .decodeTokensPerSecond.value)
            pending.inference[v.engine] = v
            pollLog.append((v.t, v.pollDuration * 1000))
            pollLog.removeAll { v.t - $0.t > 60 }
            pending.slotPollCount = pollLog.count
            pending.slotServerMillis = pollLog.reduce(0) { $0 + $1.ms }
        case .power(let v):
            wattSeries.append(t: v.t.s, v.watts.value)
            pending.power = v
            tracker.noteWatts(v.watts.value, at: v.t)
            // A true integral, alongside the trapezoidal one, until the raw
            // units have been calibrated. See Episode.energyUnitRatio.
            tracker.noteAccumulatedEnergy(v.accumulatedEnergy, at: v.t)
            // The battery controller's refresh cadence, which is not ours.
            sources.noteValueChange(.power, nil, changedAt: v.lastRefreshedAt)
        case .roster(let v):
            pending.roster = v.runtimes
        case .prediction(let v):
            pending.lastPrediction[v.engine] = v
            // The receipt is what finally gives an MLX episode a token count.
            // It may arrive just after the episode closed, which noteReceipt
            // handles; an unattributable one is dropped, not invented.
            tracker.noteReceipt(tokens: v.predictedTokens,
                                tokensPerSecond: v.tokensPerSecond.value,
                                ttft: v.timeToFirstToken.value,
                                stopReason: v.stopReason,
                                reportedBy: v.source,
                                at: v.t)
            episodes = tracker.completed
            currentEpisode = tracker.current
        case .thermal(let v):
            tempSeries.append(t: v.t.s, v.hotspot?.estimate.value)
            fanSeries.append(t: v.t.s, v.fans.compactMap { $0.actualRPM }.max())
            pending.thermal = v
            tracker.noteThermal(hotspotC: v.hotspot?.estimate.value,
                                domain: v.hotspot?.domain,
                                fanRPM: v.fans.compactMap { $0.actualRPM }.max(),
                                fansForced: v.control?.forcing ?? false,
                                pressure: v.pressure,
                                at: v.t)
        case .health(let h):
            sources.ingest(h)
        }
        dirty = true
    }

    // MARK: - Derived, computed on demand (not stored, so no invalidation storms)

    /// The active slot across all engines, if any.
    /// The busy slot across ALL engines, not just the one that reported last.
    var activeSlot: SlotSample? {
        for (_, sample) in snapshot.inference.sorted(by: { $0.value.t > $1.value.t }) {
            if let s = sample.slots.first(where: { $0.state.isBusy }) { return s }
        }
        return nil
    }

    /// Which engine that busy slot belongs to.
    var activeEngine: EngineID? {
        for (engine, sample) in snapshot.inference.sorted(by: { $0.value.t > $1.value.t })
        where sample.slots.contains(where: { $0.state.isBusy }) { return engine }
        return nil
    }

    var isGenerating: Bool { activeSlot != nil || busyOpaqueRuntime != nil }

    /// A runtime we can see is working but cannot instrument (MLX).
    var busyOpaqueRuntime: RuntimeInfo? {
        roster.first { $0.busy && !$0.exposesTokenTelemetry }
    }

    /// The runtime actually doing the work, which is NOT necessarily the one
    /// with an HTTP API. Showing llama.cpp's model name while MLX is generating
    /// was the app reporting a stale identity as if it were live.
    /// The row that best DESCRIBES an engine, where an engine has several.
    ///
    /// Jan contributes a router row, a row per loaded instance and a row per
    /// model it could load. The router is listed first and holds no weights, so
    /// taking the first match reported "no model resident" in the header — and
    /// an absent inference domain — throughout a generation that was visibly
    /// running. Rank by what the row can actually tell us instead of by
    /// position: generating beats resident, resident beats merely present.
    func bestRuntime(for engine: EngineID) -> RuntimeInfo? {
        let rows = roster.filter { $0.engine == engine }
        if rows.count <= 1 { return rows.first }
        return rows.max { a, b in
            func rank(_ r: RuntimeInfo) -> (Int, Int, UInt64) {
                ((r.busy && r.modelName != nil) ? 1 : 0,
                 (r.reachable && r.modelName != nil) ? 1 : 0,
                 r.residentBytes)
            }
            return rank(a) < rank(b)
        }
    }

    var workingRuntime: RuntimeInfo? {
        // 1. The engine we can SEE generating wins, whichever it is.
        if let e = activeEngine, let r = bestRuntime(for: e) { return r }
        // 2. A runtime that reports busy but exposes no token detail (MLX in Bionic).
        if let r = roster.first(where: { $0.busy }) { return r }
        // 3. Idle: the engine that ran MOST RECENTLY. "Biggest resident" is not
        //    the same question, and answering it here pinned the header to
        //    llama.cpp's 21 GB model no matter what you had actually been using.
        if let e = lastBusyAt.max(by: { $0.value < $1.value })?.key,
           let r = bestRuntime(for: e) { return r }
        // 4. Nothing has run since the app launched (and nothing is persisted,
        //    by design). Prefer the most RECENTLY STARTED runtime: the server
        //    you brought up last is the one you are working with. Ranking by
        //    size instead meant llama.cpp's 29.5 GB always won and the header
        //    sat on a model the user had stopped using.
        let resident = roster.filter { $0.residentBytes > 1_000_000_000 }
        if let newest = resident.max(by: {
            ($0.generation?.startedAt ?? 0) < ($1.generation?.startedAt ?? 0)
        }) { return newest }
        return roster.max { ($0.residentBytes, $0.engine.rawValue) < ($1.residentBytes, $1.engine.rawValue) }
    }

    /// Health of the inference domain, for whichever engine is actually there.
    /// Hardcoding this to Bionic meant stopping that server showed a permanent
    /// red error even when mlx-lm was serving fine.
    var inferenceLiveness: Liveness {
        let engines = roster.filter { $0.engine != .ollama && $0.engine != .localai }
        guard !engines.isEmpty else {
            return .absent("no inference server running")
        }
        let runtime = workingRuntime ?? engines[0]
        // A runtime with no /slots-equivalent will never report into this
        // domain, so waiting for it is not a fault. This is the case that put a
        // red "no samples yet" chip next to a visibly healthy MLX generation:
        // the collector was fine, the channel simply does not exist.
        guard runtime.exposesTokenTelemetry else {
            return .absent(runtime.telemetryGap ?? "no per-token telemetry")
        }
        return sources.liveness(.slots, runtime.engine, now: now,
                                policy: .slots(for: runtime.engine))
    }

    /// A prediction completed, but no episode was ever opened for it.
    ///
    /// Busy/idle is observed on the roster's 0.2 Hz clock, so a generation
    /// shorter than one poll passes entirely between two observations. The
    /// receipt proves it happened; there is simply no GPU or power trace to
    /// draw for it. MEASURED: a 131-token MLX generation finished in ~2.2 s
    /// against a 5 s roster interval, and the phase panel went on reporting
    /// "no generations yet" while its receipt was on screen.
    ///
    /// A receipt must not manufacture an episode — the stream is instance-wide
    /// with no caller identity, and an envelope with no trace behind it would be
    /// a fabrication. So the app says which of the two situations it is in.
    var unenvelopedPrediction: PredictionSample? {
        guard episodes.isEmpty, currentEpisode == nil else { return nil }
        return lastPrediction
    }

    /// Engines holding a model right now. Surfaced because showing ONE model in
    /// the header is misleading when several are loaded and competing for RAM.
    var residentRuntimes: [RuntimeInfo] {
        roster.filter { $0.residentBytes > 1_000_000_000 }
    }

    /// The GPU is clearly working, but nothing we can instrument accounts for
    /// it. Saying "idle" here would be the same class of lie as rendering a
    /// missing measurement as zero.
    var unattributedActivity: String? {
        guard let gpu = latestSystem?.gpuDevice, gpu > 0.5 else { return nil }
        guard activeSlot == nil else { return nil }
        if let r = busyOpaqueRuntime {
            return "\(r.modelName ?? "MLX model") is generating on \(r.backend ?? "MLX"), which exposes no per-token telemetry"
        }
        return "GPU is at \(Int(gpu * 100))% but no instrumented endpoint accounts for it"
    }

    /// Whole-system watts minus the idle floor: the marginal cost of inference.
    /// Far more interesting than total draw, and invisible without a baseline.
    @ObservationIgnored private(set) var idleWattsFloor: Double?
    @ObservationIgnored private var tracker = EpisodeTracker()
    // Ignored, like the ring buffers: these change at 10 Hz and would otherwise
    // invalidate every view on every sample, defeating the coalescing flusher.
    // Views depend on `revision` (snapshot-backed) and read these through it.
    @ObservationIgnored private(set) var episodes: [Episode] = []
    @ObservationIgnored private(set) var currentEpisode: Episode?

    /// Opens and closes episodes as work starts and stops. Uses the union of
    /// signals, so an MLX generation (visible only as busy + GPU) is tracked
    /// just as a llama.cpp one is.
    private func refreshEpisodes(at t: Instant) {
        let r = workingRuntime
        tracker.note(generating: isGenerating,
                     backend: r?.backend ?? "unknown",
                     model: r?.modelName ?? "unknown",
                     at: t)
        let cur = tracker.current
        if cur?.id != currentEpisode?.id { episodes = tracker.completed }
        currentEpisode = cur
    }

    func noteIdleFloor() {
        guard !isGenerating, let w = latestPower?.watts.value else { return }
        idleWattsFloor = min(idleWattsFloor ?? w, w)
    }

    var marginalWatts: Double? {
        guard let w = latestPower?.watts.value, let floor = idleWattsFloor, w > floor
        else { return nil }
        return w - floor
    }

    /// The hero figure. A ratio of two quantities sampled at different rates
    /// and with different confidence, so it always carries its decoration.
    var joulesPerToken: Estimate<Double> {
        guard let p = latestPower else { return .unavailable("no power sample yet") }
        guard let w = p.watts.value else {
            return .unavailable(p.watts.confidence.reason ?? "power unavailable")
        }
        guard let slot = activeSlot else {
            // "not generating" was a lie whenever MLX was the engine: it IS
            // generating, and the app can see that. The honest answer names the
            // structural gap, and points at the figure that IS available.
            if let r = busyOpaqueRuntime {
                return .unavailable(
                    "\(r.backend ?? "this backend") reports stats only at the end of a prediction — no live rate exists")
            }
            return .unavailable("not generating")
        }
        guard let rate = slot.decodeTokensPerSecond.value, rate > 0.01 else {
            return .unavailable(slot.decodeTokensPerSecond.confidence.reason ?? "no decode rate")
        }
        let jpt = w / rate
        // Never better than the weaker of its two inputs, and power is held.
        let n = slot.decodeTokensPerSecond.sampleCount
        return .low(jpt, uncertainty: slot.decodeTokensPerSecond.uncertainty.map { u in
            rate > 0 ? jpt * (u / rate) : jpt
        }, n: n)
    }
}
