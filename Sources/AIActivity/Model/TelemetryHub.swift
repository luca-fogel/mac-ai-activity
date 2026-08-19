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
        case .roster(let v):
            pending.roster = v.runtimes
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
    var workingRuntime: RuntimeInfo? {
        // 1. The engine we can SEE generating wins, whichever it is.
        if let e = activeEngine, let r = roster.first(where: { $0.engine == e }) { return r }
        // 2. A runtime that reports busy but exposes no token detail (MLX in Bionic).
        if let r = roster.first(where: { $0.busy }) { return r }
        // 3. Idle: the engine that ran MOST RECENTLY. "Biggest resident" is not
        //    the same question, and answering it here pinned the header to
        //    llama.cpp's 21 GB model no matter what you had actually been using.
        if let e = lastBusyAt.max(by: { $0.value < $1.value })?.key,
           let r = roster.first(where: { $0.engine == e }) { return r }
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
        let target = workingRuntime?.engine ?? engines[0].engine
        return sources.liveness(.slots, target, now: now, expected: 1.0)
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
        guard let slot = activeSlot else { return .unavailable("not generating") }
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
