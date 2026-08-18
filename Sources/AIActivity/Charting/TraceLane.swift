import SwiftUI

/// A dense trace: filled area plus stroke, drawn in a Canvas.
///
/// Canvas rather than Swift Charts. At 10 Hz x 300 s x ~10 series, Swift Charts
/// would materialize ~30k marks/sec and re-run plot layout on every change;
/// its comfortable interactive ceiling is low thousands of marks updating
/// slowly. This is the wrong data model for a scrolling oscilloscope, not a
/// tuning problem.
struct TraceLane: View {
    var columns: [Column]
    var domain: ClosedRange<Double>
    var tint: Color
    var height: CGFloat
    /// Drawn only up to the last real sample; the remainder is hatched.
    var staleFromFraction: Double?

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { ctx, size in
            let rect = CGRect(origin: .zero, size: size)

            // Gridlines: hairline, SOLID, one step off surface. Never dashed.
            for f in [0.0, 0.5, 1.0] {
                var p = Path()
                let y = rect.maxY - CGFloat(f) * rect.height
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(f == 0 ? T.axis : T.gridline), lineWidth: 1)
            }

            guard !columns.isEmpty else { return }
            let (stroke, fill) = TraceCache.paths(columns, rect: rect, domain: domain)
            ctx.fill(fill, with: .color(tint.opacity(T.areaWash)))
            ctx.stroke(stroke, with: .color(tint),
                       style: StrokeStyle(lineWidth: T.lineW, lineCap: .round, lineJoin: .round))

            if let f = staleFromFraction, f < 1 {
                let x = rect.width * CGFloat(f)
                let stale = CGRect(x: x, y: 0, width: rect.width - x, height: rect.height)
                ctx.stroke(Hatch(spacing: 6).path(in: stale),
                           with: .color(T.hatchStale), lineWidth: 1)
            }
        }
        .frame(height: height)
    }
}

/// The sparse inference track.
///
/// Step bars whose WIDTH is the real inter-sample gap, with a dot marking each
/// actual sample. A smooth dense line here would imply 10 Hz fidelity the
/// source cannot provide — /slots costs 100-450 ms per call and cannot be
/// polled faster than ~1 Hz.
struct SparseTrack: View {
    struct Point: Identifiable {
        var id: Int
        var t: Double
        var value: Double?
        var gapBefore: Double
    }
    var points: [Point]
    var axis: TimeAxis
    var domain: ClosedRange<Double>
    var tint: Color
    var height: CGFloat
    /// A gap wider than this is drawn as a break, never interpolated across.
    var expectedInterval: Double = 1.0

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            var base = Path()
            base.move(to: CGPoint(x: 0, y: rect.maxY))
            base.addLine(to: CGPoint(x: size.width, y: rect.maxY))
            ctx.stroke(base, with: .color(T.axis), lineWidth: 1)

            let span = max(domain.upperBound - domain.lowerBound, 1e-9)
            func y(_ v: Double) -> CGFloat {
                rect.maxY - CGFloat((v - domain.lowerBound) / span) * rect.height
            }

            for p in points {
                let x1 = axis.x(p.t)
                let x0 = max(0, axis.x(p.t - min(p.gapBefore, expectedInterval * 3)))
                let missed = p.gapBefore > expectedInterval * 1.8

                if missed {
                    // Dotted marker: a poll was missed. NOT zero, not bridged.
                    var d = Path()
                    d.move(to: CGPoint(x: x0, y: rect.midY))
                    d.addLine(to: CGPoint(x: x1, y: rect.midY))
                    ctx.stroke(d, with: .color(T.inkDisabled),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                guard let v = p.value else { continue }
                let top = y(v)
                let bar = CGRect(x: x0 + T.markGap, y: top,
                                 width: max(2, x1 - x0 - T.markGap), height: rect.maxY - top)
                ctx.fill(Path(roundedRect: bar, cornerRadius: 1.5),
                         with: .color(tint.opacity(0.55)))
                // The dot IS the measurement; the bar is only its extent in time.
                let r: CGFloat = 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: x1 - r, y: top - r, width: r * 2, height: r * 2)),
                         with: .color(tint))
            }
        }
        .frame(height: height)
    }
}

/// Per-source poll ticks. Makes the rate hierarchy — and the observer effect —
/// visible: every `inf` tick is a moment the server stopped decoding for us.
struct SampleRug: View {
    struct Row: Identifiable {
        var id: String
        var label: String
        var times: [Double]
        var liveness: Liveness
        var hz: Double?
    }
    var rows: [Row]
    var axis: TimeAxis

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.label).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(T.inkMuted).frame(width: 30, alignment: .leading)
                    Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                        if case .dark(let reason) = row.liveness {
                            var p = Path()
                            p.move(to: CGPoint(x: 0, y: size.height / 2))
                            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                            ctx.stroke(p, with: .color(T.critical.opacity(0.5)),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            ctx.draw(Text(reason).font(.system(size: 8))
                                        .foregroundStyle(T.critical),
                                     at: CGPoint(x: 4, y: size.height / 2), anchor: .leading)
                            return
                        }
                        for t in row.times {
                            let x = axis.x(t)
                            guard x >= 0, x <= size.width else { continue }
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: 1))
                            p.addLine(to: CGPoint(x: x, y: size.height - 1))
                            ctx.stroke(p, with: .color(T.inkSecondary.opacity(0.75)), lineWidth: 1)
                        }
                    }
                    .frame(height: 9)
                    Text(row.hz.map { Fmt.hz($0) } ?? Fmt.dash)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(T.inkMuted).frame(width: 58, alignment: .trailing)
                }
            }
        }
    }
}
