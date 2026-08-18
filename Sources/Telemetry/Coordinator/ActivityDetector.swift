import Foundation

/// Decides whether inference is happening, so the system stream can drop to a
/// low idle rate and rise only when there is something to see.
///
/// Backend CPU is deliberately NOT a signal: measured 0.0-0.3% of one core
/// during confirmed generation, because llama.cpp blocks on a Metal
/// command-buffer wait and the CPU thread sleeps. A CPU-based predicate would
/// report idle through every single inference.
public struct ActivityDetector: Sendable {

    /// GPU utilization is a fast hint, but its idle floor differs per machine
    /// and per driver. Rather than hardcode a threshold, learn it: if the
    /// observed minimum never falls, the signal carries no information and is
    /// dropped from the predicate instead of quietly lying.
    public struct GPUCalibration: Sendable {
        public var minimumSeen: Double = 1.0
        public var observedFor: Double = 0
        public var isReliable: Bool { observedFor > 60 && minimumSeen < 0.85 }
        public var threshold: Double { minimumSeen + 0.5 * (1.0 - minimumSeen) }
    }

    public private(set) var calibration = GPUCalibration()
    public private(set) var isActive = false

    private var lastConfirmAt: Instant?
    private var lastChangeAt = Instant(0)
    private let gracePeriod: Double = 3      // no advance for this long -> idle
    private let minimumDwell: Double = 2     // anti-flap

    public init() {}

    public mutating func observeGPU(_ utilization: Double?, at t: Instant, dt: Double) {
        guard let u = utilization else { return }
        calibration.minimumSeen = min(calibration.minimumSeen, u)
        calibration.observedFor += dt
    }

    /// `confirmed` is the authoritative signal: a slot advanced n_decoded.
    public mutating func update(confirmed: Bool, gpu: Double?, at t: Instant) {
        if confirmed { lastConfirmAt = t }

        let hint = calibration.isReliable && (gpu ?? 0) > calibration.threshold
        let wants: Bool
        if confirmed || hint {
            wants = true
        } else if let last = lastConfirmAt {
            wants = (t - last) < gracePeriod
        } else {
            wants = false
        }

        guard wants != isActive else { return }
        guard t - lastChangeAt >= minimumDwell || wants else { return }
        isActive = wants
        lastChangeAt = t
    }

    /// 10 Hz while generating; 2 Hz when there is nothing to resolve.
    public var systemInterval: Double { isActive ? 0.1 : 0.5 }
}
