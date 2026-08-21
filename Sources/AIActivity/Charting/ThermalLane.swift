import SwiftUI
import Telemetry

/// Die hotspot and fan rpm on one lane, with two different y-domains.
///
/// Two series share this lane because the QUESTION is a comparison — did the
/// fans respond to the heat, and how late — and that question dies the moment
/// they are drawn in separate boxes. They keep separate scales and separate
/// visual treatments (temperature is a filled trace, rpm a thin line) so
/// nobody can read one value off the other's axis.
///
/// Both are sampled at 1 Hz, an order of magnitude slower than the GPU lane
/// above them, so this is drawn as a step-held trace: a value is held until the
/// next sample rather than interpolated toward it, because the SMC reported
/// exactly one number for that whole second.
struct ThermalLane: View {
    var temps: Series<Double?>
    var fans: Series<Double?>
    var window: ClosedRange<Double>
    var axis: TimeAxis

    /// Fixed, not auto-scaled. A thermal lane whose axis moves cannot be read
    /// across a generation, and 30–100 °C covers everything this hardware does.
    private let tempDomain: ClosedRange<Double> = 30...100
    private let rpmDomain: ClosedRange<Double> = 0...6800

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { ctx, size in
            let rect = CGRect(origin: .zero, size: size)

            for c in [50.0, 75.0, 95.0] {
                var p = Path()
                let y = yFor(c, in: rect, domain: tempDomain)
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                // 95 °C is the helper's release ceiling, so it is drawn as an
                // axis-weight line rather than a gridline: it is a threshold
                // with behaviour attached, not a decoration.
                ctx.stroke(p, with: .color(c == 95 ? T.serious.opacity(0.45) : T.gridline),
                           lineWidth: 1)
                ctx.draw(Text("\(Int(c))°").font(T.axisFnt).foregroundStyle(T.inkMuted),
                         at: CGPoint(x: 14, y: y - 6))
            }

            let tw = temps.window(window)
            drawStep(ctx, rect: rect, times: tw.times, values: tw.values,
                     domain: tempDomain, tint: T.phasePrefill, fill: true, width: T.lineW)

            let fw = fans.window(window)
            drawStep(ctx, rect: rect, times: fw.times, values: fw.values,
                     domain: rpmDomain, tint: T.inkSecondary, fill: false, width: 1)
        }
        .frame(height: T.laneDense)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                LegendSwatch(tint: T.phasePrefill, label: "hotspot °C")
                LegendSwatch(tint: T.inkSecondary, label: "fan rpm")
            }
            .padding(.trailing, 4)
        }
    }

    private func yFor(_ v: Double, in rect: CGRect,
                      domain: ClosedRange<Double>) -> CGFloat {
        let span = max(domain.upperBound - domain.lowerBound, 1e-9)
        let f = min(1, max(0, (v - domain.lowerBound) / span))
        return rect.maxY - CGFloat(f) * rect.height
    }

    /// Step-and-hold, with real gaps preserved.
    ///
    /// A missing sample breaks the path instead of bridging it: the SMC going
    /// quiet for five seconds is information, and a straight line across it
    /// would be an invention.
    private func drawStep(_ ctx: GraphicsContext, rect: CGRect,
                          times: ArraySlice<Double>, values: ArraySlice<Double?>,
                          domain: ClosedRange<Double>, tint: Color,
                          fill: Bool, width: CGFloat) {
        guard times.count > 1 else { return }
        let span = max(window.upperBound - window.lowerBound, 1e-9)
        func x(_ t: Double) -> CGFloat {
            rect.minX + CGFloat((t - window.lowerBound) / span) * rect.width
        }

        var stroke = Path()
        var area = Path()
        var open = false
        var lastX: CGFloat = 0
        var lastY: CGFloat = 0

        for i in times.indices {
            guard let v = values[i] else {
                if open, fill {
                    area.addLine(to: CGPoint(x: lastX, y: rect.maxY))
                    area.closeSubpath()
                }
                open = false
                continue
            }
            let px = x(times[i])
            let py = yFor(v, in: rect, domain: domain)
            if !open {
                stroke.move(to: CGPoint(x: px, y: py))
                if fill { area.move(to: CGPoint(x: px, y: rect.maxY)); area.addLine(to: CGPoint(x: px, y: py)) }
                open = true
            } else {
                // Hold, then step. The horizontal segment is the second during
                // which this was the only number available.
                stroke.addLine(to: CGPoint(x: px, y: lastY))
                stroke.addLine(to: CGPoint(x: px, y: py))
                if fill {
                    area.addLine(to: CGPoint(x: px, y: lastY))
                    area.addLine(to: CGPoint(x: px, y: py))
                }
            }
            lastX = px; lastY = py
        }
        if open, fill {
            area.addLine(to: CGPoint(x: lastX, y: rect.maxY))
            area.closeSubpath()
            ctx.fill(area, with: .color(tint.opacity(T.areaWash)))
        }
        ctx.stroke(stroke, with: .color(tint),
                   style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }
}

struct LegendSwatch: View {
    let tint: Color
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 8, height: 2)
            Text(label).font(.system(size: 9)).foregroundStyle(T.inkMuted)
        }
    }
}
