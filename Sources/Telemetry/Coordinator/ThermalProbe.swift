import Foundation

/// The thermal collector: SMC sensors, fans, and the cooling control loop.
///
/// ## Why this owns a thread instead of living in `LiveTelemetryFeed`
///
/// MEASURED on this machine: one SMC key read costs **195 µs of wall time but
/// only 13.8 µs of CPU** — 93% of it is the caller blocked on a microcontroller
/// across a slow bus. A 76-key sweep is therefore **13.0 ms of wall time and
/// 0.76 ms of CPU**.
///
/// Those two numbers pull in opposite directions and both matter:
///
///   * 0.76 ms per second is 0.076% of one core, so sampling every sensor every
///     second is cheap and there is no need for rotating subsets or a reduced
///     key map that could miss the hotspot.
///   * 13.0 ms of BLOCKING inside `LiveTelemetryFeed`'s actor would stall the
///     10 Hz system loop for 13 ms once a second — the same mistake
///     `LMStudioProbe` already cost this project once, at 240 ms.
///
/// So the sweep runs on a dedicated thread, off the cooperative pool entirely,
/// and publishes through a stream like any other source.
public final class ThermalProbe: @unchecked Sendable {

    public nonisolated let samples: AsyncStream<ThermalSample>
    private let cont: AsyncStream<ThermalSample>.Continuation

    private let sensors: ThermalSensors?
    public let cooling: CoolingController
    /// Blocking IOKit and blocking socket I/O, on a thread that is allowed to
    /// block. Utility QoS: this is instrumentation, not interaction.
    private let queue = DispatchQueue(label: "ai-activity.thermal", qos: .utility)

    private let lock = NSLock()
    private var running = false
    private var generating = false

    public init(cooling: CoolingController = CoolingController()) {
        self.sensors = ThermalSensors()
        self.cooling = cooling
        var c: AsyncStream<ThermalSample>.Continuation!
        self.samples = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { c = $0 }
        self.cont = c
    }

    /// Whether the SMC answered at all. `false` is `absent`, not a fault: a Mac
    /// with no fans and no readable die sensors is a legitimate machine.
    public var isAvailable: Bool { sensors != nil }

    public var discovered: [ThermalDomain: Int] { sensors?.discoveredCounts ?? [:] }

    /// Fed by the feed's own activity view, so a boost policy can spin fans up
    /// on the REQUEST rather than waiting for the die to heat.
    public func setGenerating(_ v: Bool) {
        lock.lock(); generating = v; lock.unlock()
    }

    public func start() {
        lock.lock()
        guard !running, sensors != nil else { lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.loop() }
    }

    public func stop() {
        lock.lock(); running = false; lock.unlock()
        // Hand the fans back before going away. The helper's lease would do it
        // anyway within 15 s; this makes quitting the app feel like quitting.
        let c = cooling
        queue.async { c.shutdown() }
        cont.finish()
    }

    private func loop() {
        guard let sensors else { return }
        while lock.withLock({ running }) {
            let started = DispatchTime.now().uptimeNanoseconds
            var s = sensors.sample()
            let gen = lock.withLock { generating }
            s.control = cooling.tick(hotspotC: s.hotspot?.estimate.value,
                                     generating: gen, at: s.t)
            cont.yield(s)

            // Fixed 1 Hz cadence measured from the START of the sweep, so the
            // 13 ms sweep does not slew the clock. A thermal series with a
            // wandering interval cannot be read against the GPU trace.
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            let sleepFor = max(0.1, 1.0 - elapsed)
            Thread.sleep(forTimeInterval: sleepFor)
        }
    }

    /// Off the sampling path, for the Sources inspector.
    public func unattributedSensors() -> [(key: String, celsius: Double)] {
        sensors?.unattributed() ?? []
    }
}
