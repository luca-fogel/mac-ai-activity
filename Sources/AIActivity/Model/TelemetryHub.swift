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
        var inference: InferenceSample?
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
    var latestInference: InferenceSample? { snapshot.inference }
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
            // 20 Hz ceiling on redraws, regardless of arrival pattern.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
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
        case .inference(let v):
            rateSeries.append(t: v.t.s,
                              v.slots.first { $0.state == .processing }?
                                     .decodeTokensPerSecond.value)
            pending.inference = v
            pollLog.append((v.t, v.pollDuration * 1000))
            pollLog.removeAll { v.t - $0.t > 60 }
            pending.slotPollCount = pollLog.count
            pending.slotServerMillis = pollLog.reduce(0) { $0 + $1.ms }
        case .power(let v):
            wattSeries.append(t: v.t.s, v.watts.value)
            pending.power = v
        case .roster(let v):
            pending.roster = v.runtimes
        case .health(let h):
            sources.ingest(h)
        }
        dirty = true
    }

    // MARK: - Derived, computed on demand (not stored, so no invalidation storms)

    /// The active slot across all engines, if any.
    var activeSlot: SlotSample? {
        latestInference?.slots.first { $0.state == .processing }
    }

    var isGenerating: Bool { activeSlot != nil }

    /// Whole-system watts minus the idle floor: the marginal cost of inference.
    /// Far more interesting than total draw, and invisible without a baseline.
    @ObservationIgnored private(set) var idleWattsFloor: Double?

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
