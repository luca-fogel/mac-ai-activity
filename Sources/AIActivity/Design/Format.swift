import Foundation
import Telemetry

/// Formatting, including the em-dash policy: a measurement is a number, and
/// the absence of one is "—". They must never be confusable.
enum Fmt {
    static let dash = "—"

    static func bytes(_ b: UInt64?) -> String {
        guard let b else { return dash }
        let g = Double(b) / 1_073_741_824
        if g >= 100 { return String(format: "%.0f GB", g) }
        if g >= 1   { return String(format: "%.1f GB", g) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    static func pct(_ v: Double?, decimals: Int = 0) -> String {
        guard let v else { return dash }
        return String(format: "%.\(decimals)f%%", v * 100)
    }

    static func hz(_ v: Double?) -> String {
        guard let v, v.isFinite else { return dash }
        return String(format: v < 1 ? "%.2f Hz" : "%.1f Hz", v)
    }

    static func secs(_ v: Double?) -> String {
        guard let v, v.isFinite else { return dash }
        if v < 1 { return String(format: "%.0f ms", v * 1000) }
        return String(format: "%.2f s", v)
    }

    static func tokens(_ n: Int?) -> String {
        guard let n else { return dash }
        return n.formatted(.number.grouping(.automatic))
    }

    static func watts(_ v: Double?) -> String {
        guard let v else { return dash }
        return String(format: "%.1f W", v)
    }

    static func rate(_ v: Double?) -> String {
        guard let v else { return dash }
        return String(format: "%.1f", v)
    }
}
