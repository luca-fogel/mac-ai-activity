import Foundation

/// The wire between the app and the privileged helper, and the safety rules
/// that the HELPER enforces.
///
/// Every rule in `FanGuard` lives on the privileged side. The app is a client
/// like any other and is not trusted: it cannot raise a ceiling, extend a lease
/// past the cap, or ask for an rpm outside what the hardware itself reports.
/// This is the difference between "the UI won't let you" and "it cannot happen".

public enum Cooling {
    /// Root-owned, group-writable by the installing user's primary group.
    public static let socketPath = "/var/run/aithermald.sock"
    public static let helperLabel = "com.foggylulu.aithermald"
    /// Bumped when the wire format changes. The app refuses to talk to a helper
    /// it does not recognise rather than guessing at semantics.
    public static let protocolVersion = 1
}

// MARK: - Requests

public struct CoolingRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable {
        /// Read-only. Always allowed.
        case status
        /// Take or renew a lease on one or more fans.
        case set
        /// Hand every fan straight back to the SMC.
        case auto
    }
    public var version: Int
    public var op: Op
    /// Per-fan requested rpm. A fan absent from this map is left alone.
    public var targets: [Int: Double]?
    /// How long this command stays valid without renewal. Clamped by the
    /// helper to `FanGuard.maxLeaseSeconds`.
    public var leaseSeconds: Double?

    public init(op: Op, targets: [Int: Double]? = nil, leaseSeconds: Double? = nil) {
        self.version = Cooling.protocolVersion
        self.op = op; self.targets = targets; self.leaseSeconds = leaseSeconds
    }
}

// MARK: - Status

/// Why the helper took control away from a client. Every one of these is a
/// safety action, so the reason is always carried to the UI verbatim.
public enum GuardTrip: String, Codable, Sendable {
    /// Hotspot exceeded the hard ceiling while a manual rpm was held.
    case overTemperature
    /// The OS reported serious or critical thermal pressure.
    case thermalPressure
    /// The client stopped renewing. Covers a crashed, killed or hung app.
    case leaseExpired
    /// The helper is shutting down.
    case helperExiting
    /// A fan stopped tracking its commanded rpm.
    case fanNotTracking

    public var explanation: String {
        switch self {
        case .overTemperature: return "hotspot passed the hard ceiling — fans returned to automatic"
        case .thermalPressure: return "the OS reported serious thermal pressure — fans returned to automatic"
        case .leaseExpired:    return "no renewal from the app — fans returned to automatic"
        case .helperExiting:   return "helper is stopping — fans returned to automatic"
        case .fanNotTracking:  return "a fan did not reach its commanded rpm — fans returned to automatic"
        }
    }
}

public struct CoolingStatus: Codable, Sendable, Equatable {
    public var version: Int
    public var helperVersion: String
    /// True while any fan is held at a commanded rpm.
    public var forcing: Bool
    /// What the helper has actually written, per fan. Not what was asked for:
    /// if a request was clamped, this is the clamped value.
    public var targets: [Int: Double]
    /// Seconds until the current lease lapses and everything returns to auto.
    public var leaseRemaining: Double?
    /// The last request that had to be clamped, and to what. Surfaced because
    /// silently honouring a different number than the one asked for is the kind
    /// of thing that makes an instrument untrustworthy.
    public var lastClamp: String?
    /// Set while a trip is in force. Manual control is refused until it clears.
    public var trip: GuardTrip?
    public var tripUntil: Double?
    public var hardCeilingC: Double
    /// Hardware's own rpm range, per fan, as the helper read it.
    public var limits: [Int: [Double]]
    /// The helper's own view of the hotspot, sampled independently of the app.
    public var hotspotC: Double?

    public init(version: Int = Cooling.protocolVersion,
                helperVersion: String, forcing: Bool, targets: [Int: Double],
                leaseRemaining: Double?, lastClamp: String?, trip: GuardTrip?,
                tripUntil: Double?, hardCeilingC: Double,
                limits: [Int: [Double]], hotspotC: Double?) {
        self.version = version; self.helperVersion = helperVersion
        self.forcing = forcing; self.targets = targets
        self.leaseRemaining = leaseRemaining; self.lastClamp = lastClamp
        self.trip = trip; self.tripUntil = tripUntil
        self.hardCeilingC = hardCeilingC; self.limits = limits
        self.hotspotC = hotspotC
    }
}

public struct CoolingResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: CoolingStatus?
    public init(ok: Bool, error: String? = nil, status: CoolingStatus? = nil) {
        self.ok = ok; self.error = error; self.status = status
    }
}

// MARK: - The guard

/// Every safety rule, as pure functions over values.
///
/// Pulled out of the daemon so the dangerous half of this feature can be
/// exercised in unit tests, on any machine, without a fan attached — the
/// alternative being to verify a thermal cutout by overheating a laptop.
public enum FanGuard {

    /// A manual rpm is never honoured for longer than this without renewal.
    /// 60 s is chosen so that an app crash costs at most one minute of a fan
    /// held at the wrong speed.
    public static let maxLeaseSeconds: Double = 60
    public static let minLeaseSeconds: Double = 1
    /// Default hard ceiling on the die hotspot. Apple Silicon self-throttles
    /// well before damage, so this is a "stop being clever" line, not a rescue:
    /// above it, the SMC's own loop is better informed than any policy here.
    public static let defaultCeilingC: Double = 95
    /// After a trip, manual control stays refused for this long AND until the
    /// hotspot has fallen clear of the ceiling by `tripHysteresisC`.
    public static let tripCooldownSeconds: Double = 60
    public static let tripHysteresisC: Double = 5

    public struct Limits: Sendable, Equatable {
        public var minRPM: Double
        public var maxRPM: Double
        public init(minRPM: Double, maxRPM: Double) {
            self.minRPM = minRPM; self.maxRPM = maxRPM
        }
    }

    /// Clamps a requested rpm to what the hardware says it can do.
    ///
    /// Returns the value to write plus, when it differs, a human-readable note.
    /// A clamp is never silent: an instrument that quietly does something other
    /// than what it was told is worse than one that refuses.
    public static func clamp(_ requested: Double, to limits: Limits)
        -> (rpm: Double, note: String?) {
        guard limits.maxRPM > limits.minRPM else {
            return (limits.minRPM, "hardware reported no usable rpm range")
        }
        if requested.isNaN {
            return (limits.minRPM, "requested rpm was not a number")
        }
        if requested < limits.minRPM {
            return (limits.minRPM,
                    String(format: "%.0f rpm is below the hardware minimum %.0f", requested, limits.minRPM))
        }
        if requested > limits.maxRPM {
            return (limits.maxRPM,
                    String(format: "%.0f rpm is above the hardware maximum %.0f", requested, limits.maxRPM))
        }
        return (requested, nil)
    }

    public static func clampLease(_ requested: Double?) -> Double {
        let v = requested ?? 15
        if !v.isFinite { return minLeaseSeconds }
        return min(maxLeaseSeconds, max(minLeaseSeconds, v))
    }

    /// Everything the decision needs, gathered by the caller.
    public struct Conditions: Sendable {
        public var hotspotC: Double?
        public var pressure: ThermalState
        public var ceilingC: Double
        /// nil = nothing is being held right now.
        public var leaseExpiresAt: Double?
        public var now: Double
        /// A fan commanded but not reaching its rpm, sustained past the
        /// spin-up allowance.
        public var fanStuckSince: Double?
        public var tripUntil: Double?
        public var currentTrip: GuardTrip?

        public init(hotspotC: Double?, pressure: ThermalState,
                    ceilingC: Double = FanGuard.defaultCeilingC,
                    leaseExpiresAt: Double?, now: Double,
                    fanStuckSince: Double? = nil,
                    tripUntil: Double? = nil, currentTrip: GuardTrip? = nil) {
            self.hotspotC = hotspotC; self.pressure = pressure
            self.ceilingC = ceilingC; self.leaseExpiresAt = leaseExpiresAt
            self.now = now; self.fanStuckSince = fanStuckSince
            self.tripUntil = tripUntil; self.currentTrip = currentTrip
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Keep holding the commanded rpm.
        case hold
        /// Write mode 0 to every fan and record why.
        case release(GuardTrip)
        /// Nothing is held; nothing to do.
        case idle
    }

    /// The deadman. Evaluated by the helper on its own clock, against its own
    /// temperature reading — never against a number supplied by a client.
    ///
    /// Order is not arbitrary. Temperature outranks the lease because a hot
    /// machine must be released even if the app is perfectly healthy and still
    /// renewing; the lease outranks fan tracking because an expired lease means
    /// nobody is watching, which is the worse state to be in.
    public static func evaluate(_ c: Conditions) -> Decision {
        guard let expires = c.leaseExpiresAt else { return .idle }

        if let h = c.hotspotC, h >= c.ceilingC { return .release(.overTemperature) }
        if c.pressure == .serious || c.pressure == .critical {
            return .release(.thermalPressure)
        }
        if c.now >= expires { return .release(.leaseExpired) }
        // Spin-up is not a fault. A fan given 8 s and still not tracking is.
        if let stuck = c.fanStuckSince, c.now - stuck > 8 {
            return .release(.fanNotTracking)
        }
        return .hold
    }

    /// Whether a NEW manual request may be accepted. Separate from `evaluate`
    /// on purpose: releasing control and refusing to hand it back are different
    /// decisions, and conflating them is how a cutout becomes a flap.
    public static func admits(_ c: Conditions) -> (allowed: Bool, reason: String?) {
        if let until = c.tripUntil, c.now < until {
            let trip = c.currentTrip?.explanation ?? "recent safety trip"
            return (false, String(format: "%@ — retry in %.0fs", trip, until - c.now))
        }
        if let h = c.hotspotC, h >= c.ceilingC - tripHysteresisC {
            return (false, String(format: "hotspot %.0f °C is within %.0f °C of the ceiling",
                                  h, tripHysteresisC))
        }
        if c.pressure == .serious || c.pressure == .critical {
            return (false, "OS reports \(c.pressure.rawValue) thermal pressure")
        }
        return (true, nil)
    }
}
