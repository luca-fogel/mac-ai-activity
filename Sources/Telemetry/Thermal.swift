import Foundation

/// The thermal domain: what is hot, how hard the fans are working, and who is
/// allowed to change that.
///
/// Sampled on its own clock (~1 Hz) because it belongs to neither the 10 Hz
/// system domain nor the 0.2 Hz power domain: die temperature moves on a
/// several-second thermal time constant, and fan rpm moves slower still.

// MARK: - Sensors

public enum ThermalDomain: String, Sendable, CaseIterable, Hashable {
    case cpuPerformance
    case cpuEfficiency
    case gpu
    case battery

    /// SMC key prefixes, established by load response rather than convention.
    /// See `ThermalSensors` for the measurement that produced this map.
    public var keyPrefixes: [String] {
        switch self {
        case .cpuPerformance: return ["Tp"]
        case .cpuEfficiency:  return ["Te"]
        case .gpu:            return ["Tg"]
        case .battery:        return ["TB"]
        }
    }

    public var displayName: String {
        switch self {
        case .cpuPerformance: return "CPU P"
        case .cpuEfficiency:  return "CPU E"
        case .gpu:            return "GPU"
        case .battery:        return "Battery"
        }
    }

    /// Whether this domain is part of the SoC hotspot. The battery is a real
    /// measurement but it is not the die, and averaging it in would drag the
    /// headline figure toward ambient.
    public var isDie: Bool { self != .battery }
}

public struct SensorGroup: Sendable {
    public var domain: ThermalDomain
    /// Sensors reporting a plausible, ungated temperature.
    public var live: [(key: String, celsius: Double)]
    /// Sensors below the parked floor: a power-gated cluster, not a cold one.
    /// Kept, counted and shown — never silently dropped and never averaged in.
    public var parked: [(key: String, celsius: Double)]

    public init(domain: ThermalDomain,
                live: [(key: String, celsius: Double)],
                parked: [(key: String, celsius: Double)]) {
        self.domain = domain; self.live = live; self.parked = parked
    }

    /// The hotspot: a max, not a mean.
    ///
    /// A mean over 54 P-core sensors is a number about the die's area, not
    /// about whether anything is throttling. Throttling is decided by the
    /// hottest spot, so that is what gets published.
    public var hottest: Estimate<Double> {
        guard let peak = live.map(\.celsius).max() else {
            if !parked.isEmpty {
                return .unavailable("all \(parked.count) sensors below \(Int(ThermalSensors.parkedFloorC)) °C — cluster power-gated")
            }
            return .unavailable("no readable sensor")
        }
        // Scatter across a cluster is physical, not noise, so it travels as
        // uncertainty rather than being smoothed away.
        let spread = (live.map(\.celsius).max() ?? peak) - (live.map(\.celsius).min() ?? peak)
        return Estimate(value: peak, uncertainty: spread / 2,
                        sampleCount: live.count, confidence: .high)
    }

    public var mean: Double? {
        guard !live.isEmpty else { return nil }
        return live.reduce(0) { $0 + $1.celsius } / Double(live.count)
    }
}

// MARK: - Fans

public enum FanMode: String, Sendable, Equatable {
    /// The SMC's own control loop owns this fan.
    case auto
    /// `F<n>Md` is 1: the fan is holding whatever rpm was last written.
    case forced
    /// The mode byte was unreadable. Not the same as auto.
    case unknown
}

public struct FanSample: Sendable, Identifiable, Equatable {
    public var index: Int
    public var actualRPM: Double?
    public var targetRPM: Double?
    public var minRPM: Double?
    public var maxRPM: Double?
    public var mode: FanMode
    public var id: Int { index }

    public init(index: Int, actualRPM: Double?, targetRPM: Double?,
                minRPM: Double?, maxRPM: Double?, mode: FanMode) {
        self.index = index; self.actualRPM = actualRPM; self.targetRPM = targetRPM
        self.minRPM = minRPM; self.maxRPM = maxRPM; self.mode = mode
    }

    /// Where this fan sits in its own range, 0…1. nil unless all three of the
    /// numbers it needs are present — a duty cycle computed against a guessed
    /// maximum is a decoration, not a measurement.
    public var dutyFraction: Double? {
        guard let a = actualRPM, let lo = minRPM, let hi = maxRPM, hi > lo else { return nil }
        return min(1, max(0, (a - lo) / (hi - lo)))
    }

    /// A forced fan whose actual rpm has not reached its target yet is spinning
    /// up, which is normal for a few seconds and a fault if it persists.
    public var isTracking: Bool {
        guard let a = actualRPM, let t = targetRPM else { return true }
        return abs(a - t) < max(150, t * 0.08)
    }
}

// MARK: - The sample

public struct ThermalSample: Sendable {
    public var t: Instant
    public var groups: [SensorGroup]
    public var fans: [FanSample]
    /// The OS's own pressure ladder. Coarse but authoritative, and unlike the
    /// die sensors it accounts for whatever the kernel knows that we do not.
    public var pressure: ThermalState
    public var pressureSince: Instant
    public var speedLimit: Estimate<Double>
    public var sampleCostMicros: Double
    public var sensorsRead: Int
    /// Live control state, as reported by the helper. nil = no helper running,
    /// which is the normal, safe, read-only state of this app.
    public var control: CoolingStatus?

    public init(t: Instant, groups: [SensorGroup], fans: [FanSample],
                pressure: ThermalState, pressureSince: Instant,
                speedLimit: Estimate<Double>, sampleCostMicros: Double,
                sensorsRead: Int, control: CoolingStatus? = nil) {
        self.t = t; self.groups = groups; self.fans = fans
        self.pressure = pressure; self.pressureSince = pressureSince
        self.speedLimit = speedLimit; self.sampleCostMicros = sampleCostMicros
        self.sensorsRead = sensorsRead; self.control = control
    }

    public func group(_ d: ThermalDomain) -> SensorGroup? {
        groups.first { $0.domain == d }
    }

    /// The single number worth putting in a status rail: the hottest die
    /// sensor anywhere, with the domain that owns it.
    ///
    /// Deliberately not "CPU temperature". During GPU-bound inference the CPU
    /// clusters are gated off and read 12–23 °C while the GPU sits at 82 °C, so
    /// a CPU-labelled headline would fall as the machine got hotter.
    public var hotspot: (domain: ThermalDomain, estimate: Estimate<Double>)? {
        let candidates = groups.filter { $0.domain.isDie }
            .compactMap { g -> (ThermalDomain, Estimate<Double>, Double)? in
                guard let v = g.hottest.value else { return nil }
                return (g.domain, g.hottest, v)
            }
        guard let best = candidates.max(by: { $0.2 < $1.2 }) else { return nil }
        return (best.0, best.1)
    }

    /// Every die group whose sensors are all gated off, so the UI can say
    /// "parked" instead of showing a suspiciously cold number.
    public var parkedDomains: [ThermalDomain] {
        groups.filter { $0.domain.isDie && $0.live.isEmpty && !$0.parked.isEmpty }
              .map(\.domain)
    }
}
