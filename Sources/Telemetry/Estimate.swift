import Foundation

/// How much a derived number should be believed.
///
/// A research instrument that cannot say "I don't know" is not a research
/// instrument. Every derived metric in this app carries one of these.
public enum Confidence: Sendable, Equatable {
    /// Enough samples, low scatter. Render plainly.
    case high
    /// Usable but noisy or under-sampled. Render with ~ and ±.
    case low
    /// Not measurable, with the reason the user should see on screen.
    case unavailable(String)

    public var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var reason: String? {
        if case .unavailable(let r) = self { return r }
        return nil
    }
}

/// A closed range of plausible values, used where a point estimate would lie.
///
/// TTFT is the motivating case: we are not the client, so we can only bound it
/// by the poll interval. Publishing the midpoint would invent precision.
public struct Interval: Sendable, Equatable {
    public var lo: Double
    public var hi: Double
    public init(lo: Double, hi: Double) { self.lo = lo; self.hi = hi }
    public var width: Double { hi - lo }
    public var midpoint: Double { (lo + hi) / 2 }
}

/// A measured quantity plus everything needed to judge it.
///
/// `value == nil` and `confidence == .unavailable` travel together: the absence
/// of a measurement is itself information and must never be rendered as 0.
public struct Estimate<T: Sendable>: Sendable {
    public var value: T?
    public var uncertainty: T?
    public var sampleCount: Int
    public var confidence: Confidence
    /// Set instead of `value` when the honest answer is a range, not a point.
    public var interval: Interval?

    public init(value: T?,
                uncertainty: T? = nil,
                sampleCount: Int = 1,
                confidence: Confidence = .high,
                interval: Interval? = nil) {
        self.value = value
        self.uncertainty = uncertainty
        self.sampleCount = sampleCount
        self.confidence = confidence
        self.interval = interval
    }

    public static func unavailable(_ reason: String) -> Estimate<T> {
        Estimate(value: nil, sampleCount: 0, confidence: .unavailable(reason))
    }

    public static func high(_ v: T, n: Int = 1) -> Estimate<T> {
        Estimate(value: v, sampleCount: n, confidence: .high)
    }

    public static func low(_ v: T, uncertainty: T? = nil, n: Int) -> Estimate<T> {
        Estimate(value: v, uncertainty: uncertainty, sampleCount: n, confidence: .low)
    }

    public static func bounded(_ i: Interval, n: Int = 1) -> Estimate<T> {
        Estimate(value: nil, sampleCount: n, confidence: .low, interval: i)
    }
}
