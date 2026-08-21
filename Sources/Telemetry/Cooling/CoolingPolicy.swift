import Foundation

/// What the user asked the fans to do. Evaluated app-side into a single rpm per
/// tick; the helper then clamps and polices whatever comes out of here.
public enum CoolingPolicy: Sendable, Equatable, Codable {
    /// Hands off. The SMC's own loop decides everything.
    case system
    /// Hold one rpm, whatever the temperature.
    case fixed(rpm: Double)
    /// Map die hotspot onto rpm.
    case curve(CoolingCurve)
    /// The reason this app has fan control at all.
    ///
    /// A die takes several seconds to heat and a fan takes several seconds to
    /// spin up, so a reactive curve is always chasing. Local inference is the
    /// rare workload whose start is KNOWN — the app can see a generation begin —
    /// so the fans can be spun up on the request rather than on the heat.
    case boostWhileGenerating(BoostSettings)

    public var isForcing: Bool { self != .system }

    public var label: String {
        switch self {
        case .system: return "Automatic"
        case .fixed(let r): return String(format: "Fixed %.0f rpm", r)
        case .curve: return "Temperature curve"
        case .boostWhileGenerating: return "Boost while generating"
        }
    }
}

/// Piecewise-linear temperature → rpm.
public struct CoolingCurve: Sendable, Equatable, Codable {
    /// At or below this, the fan sits at `minRPM`.
    public var quietBelowC: Double
    /// At or above this, the fan sits at `maxRPM`.
    public var fullAboveC: Double
    public var minRPM: Double
    public var maxRPM: Double

    public init(quietBelowC: Double = 55, fullAboveC: Double = 85,
                minRPM: Double = 2400, maxRPM: Double = 6000) {
        self.quietBelowC = quietBelowC; self.fullAboveC = fullAboveC
        self.minRPM = minRPM; self.maxRPM = maxRPM
    }

    /// nil when there is no temperature to evaluate against.
    ///
    /// This is the one place where a missing measurement could silently become
    /// a fan speed, so it returns nil and the caller falls back to automatic —
    /// never to a number invented from a default.
    public func rpm(forHotspot c: Double?) -> Double? {
        guard let c else { return nil }
        guard fullAboveC > quietBelowC else { return maxRPM }
        if c <= quietBelowC { return minRPM }
        if c >= fullAboveC { return maxRPM }
        let f = (c - quietBelowC) / (fullAboveC - quietBelowC)
        return minRPM + f * (maxRPM - minRPM)
    }
}

public struct BoostSettings: Sendable, Equatable, Codable {
    /// rpm to hold while a generation is in flight.
    public var generatingRPM: Double
    /// Keep boosting for this long after work stops, so a burst of short
    /// requests does not become a fan sawtooth — and because the die keeps
    /// dumping heat into the case after the GPU goes quiet.
    public var trailingSeconds: Double
    /// While idle, either hand back to the SMC (nil) or hold a quiet floor.
    public var idleRPM: Double?
    /// Regardless of policy, never sit below the curve when it asks for more.
    /// Belt and braces: the boost is a floor, not a cap.
    public var curve: CoolingCurve?

    public init(generatingRPM: Double = 4200, trailingSeconds: Double = 20,
                idleRPM: Double? = nil, curve: CoolingCurve? = CoolingCurve()) {
        self.generatingRPM = generatingRPM; self.trailingSeconds = trailingSeconds
        self.idleRPM = idleRPM; self.curve = curve
    }
}

/// Everything the policy is evaluated against, gathered by the caller.
public struct CoolingInput: Sendable {
    public var hotspotC: Double?
    public var generating: Bool
    /// When work last stopped, for the trailing window.
    public var lastGeneratingAt: Instant?
    public var now: Instant

    public init(hotspotC: Double?, generating: Bool,
                lastGeneratingAt: Instant?, now: Instant) {
        self.hotspotC = hotspotC; self.generating = generating
        self.lastGeneratingAt = lastGeneratingAt; self.now = now
    }
}

extension CoolingPolicy {

    /// The rpm this policy wants right now, or nil for "let the SMC decide".
    ///
    /// Pure, so the interesting cases — boost trailing off, a curve with no
    /// temperature to read, a boost that must not undercut its own curve — are
    /// unit-tested rather than observed by listening to a laptop.
    public func desiredRPM(_ i: CoolingInput) -> Double? {
        switch self {
        case .system:
            return nil
        case .fixed(let rpm):
            return rpm
        case .curve(let c):
            return c.rpm(forHotspot: i.hotspotC)
        case .boostWhileGenerating(let s):
            let boosting = i.generating
                || (i.lastGeneratingAt.map { i.now - $0 <= s.trailingSeconds } ?? false)
            let curveRPM = s.curve?.rpm(forHotspot: i.hotspotC)
            if boosting {
                // The boost is a FLOOR. If the curve wants more air than the
                // boost, the hotter answer wins — otherwise a boost setting
                // chosen for comfort would cap cooling during a long run.
                return max(s.generatingRPM, curveRPM ?? 0)
            }
            guard let idle = s.idleRPM else {
                // No idle floor asked for: hand back to the SMC entirely rather
                // than holding the curve's idle value, so a quiet machine is
                // quiet by default.
                return curveRPM.flatMap { _ in nil }
            }
            return max(idle, curveRPM ?? 0)
        }
    }
}
