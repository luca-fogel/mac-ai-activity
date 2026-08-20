import Foundation
import SwiftUI

/// One horizontal pixel of a trace.
struct Column {
    var lo: Float = 0
    var hi: Float = 0
    var present: Bool = false
}

/// Reduces a ring buffer to at most one column per pixel.
///
/// min/max per column, NOT mean: a mean would erase a one-sample GPU spike,
/// which is a correctness bug rather than a performance trade-off. 3,000
/// samples across a ~900 px panel becomes ~900 columns, i.e. one path of
/// ~1,800 points, and appending a sample touches only the last column.
///
/// `present == false` marks a pixel with no underlying sample. The renderer
/// breaks the path there instead of bridging it — this is the mechanism that
/// makes "a gap is a gap" true at the pixel level.
enum TraceCache {

    /// Takes slices so the caller can hand in just the visible window.
    static func columns(times: ArraySlice<Double>, values: ArraySlice<Double?>,
                        window: ClosedRange<Double>, width: Int) -> [Column] {
        guard width > 0, !times.isEmpty else { return [] }
        var cols = [Column](repeating: Column(), count: width)
        let span = max(window.upperBound - window.lowerBound, 1e-6)

        for i in times.indices where values.indices.contains(i) {
            guard let v = values[i] else { continue }
            let t = times[i]
            guard t >= window.lowerBound, t <= window.upperBound else { continue }
            let frac = (t - window.lowerBound) / span
            let x = min(width - 1, max(0, Int(frac * Double(width))))
            let f = Float(v)
            if cols[x].present {
                cols[x].lo = min(cols[x].lo, f)
                cols[x].hi = max(cols[x].hi, f)
            } else {
                cols[x] = Column(lo: f, hi: f, present: true)
            }
        }
        return cols
    }

    /// Builds a stroke path plus a fill path, breaking both at absent columns.
    static func paths(_ cols: [Column], rect: CGRect,
                      domain: ClosedRange<Double>) -> (stroke: Path, fill: Path) {
        var stroke = Path(), fill = Path()
        let lo = domain.lowerBound, hi = domain.upperBound
        let span = max(hi - lo, 1e-9)
        func y(_ v: Float) -> CGFloat {
            rect.maxY - CGFloat((Double(v) - lo) / span) * rect.height
        }

        var run: [Int] = []
        func flush() {
            guard run.count >= 1 else { run.removeAll(); return }
            let first = run[0]
            stroke.move(to: CGPoint(x: rect.minX + CGFloat(first) + 0.5, y: y(cols[first].hi)))
            for i in run { stroke.addLine(to: CGPoint(x: rect.minX + CGFloat(i) + 0.5, y: y(cols[i].hi))) }
            fill.move(to: CGPoint(x: rect.minX + CGFloat(first) + 0.5, y: rect.maxY))
            for i in run { fill.addLine(to: CGPoint(x: rect.minX + CGFloat(i) + 0.5, y: y(cols[i].hi))) }
            if let last = run.last {
                fill.addLine(to: CGPoint(x: rect.minX + CGFloat(last) + 0.5, y: rect.maxY))
                fill.closeSubpath()
            }
            run.removeAll()
        }

        for i in cols.indices {
            if cols[i].present { run.append(i) } else { flush() }
        }
        flush()
        return (stroke, fill)
    }
}

/// Shared x-mapping so every lane in the stack agrees on where "now" is.
struct TimeAxis {
    var window: ClosedRange<Double>
    var width: CGFloat

    func x(_ t: Double) -> CGFloat {
        let span = max(window.upperBound - window.lowerBound, 1e-6)
        return CGFloat((t - window.lowerBound) / span) * width
    }

    /// Ticks every 15 s, computed only when the window or width changes.
    func ticks(every step: Double = 15) -> [(x: CGFloat, label: String)] {
        var out: [(CGFloat, String)] = []
        let end = window.upperBound
        var t = end
        while t >= window.lowerBound {
            let secondsAgo = end - t
            out.append((x(t), secondsAgo < 0.5 ? "now" : "-\(Int(secondsAgo))s"))
            t -= step
        }
        return out.reversed()
    }
}
