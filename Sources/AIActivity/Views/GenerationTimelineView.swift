import SwiftUI
import Telemetry

/// The centrepiece: one shared time axis, stacked small multiples.
///
/// Resources are LANES here rather than a separate tab. The entire research
/// payoff is seeing the prefill GPU spike aligned in time with the gap in
/// token output — splitting them across tabs would make that comparison
/// impossible by construction.
struct GenerationTimelineView: View {
    @Environment(TelemetryHub.self) private var hub
    @State private var windowSeconds: Double = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.gutter) {
                header
                GeometryReader { geo in
                    let w = max(120, geo.size.width - 96)
                    lanes(width: w)
                }
                .frame(minHeight: 460)
            }
            .padding(T.padSection)
        }
    }

    private var now: Double { (hub.latestSystem?.t.s ?? hub.now.s) }
    private var window: ClosedRange<Double> { (now - windowSeconds)...now }

    private var header: some View {
        HStack(alignment: .top, spacing: T.gutter) {
            GenerationHero()
            Spacer(minLength: 0)
            Picker("", selection: $windowSeconds) {
                Text("60s").tag(60.0); Text("3m").tag(180.0); Text("5m").tag(300.0)
            }
            .pickerStyle(.segmented).frame(width: 150)
        }
    }

    @ViewBuilder
    private func lanes(width: CGFloat) -> some View {
        let axis = TimeAxis(window: window, width: width)
        let gpuWin = hub.gpuSeries.window(window)

        VStack(alignment: .leading, spacing: 10) {
            lane("Token output", trailing: rateLabel) {
                SparseTrack(points: tokenPoints, axis: axis,
                            domain: 0...max(10, tokenMax * 1.25),
                            tint: T.phaseDecode, height: 54)
            }
            lane("GPU", trailing: Fmt.pct(hub.latestSystem?.gpuDevice)) {
                TraceLane(columns: TraceCache.columns(
                            times: gpuWin.times, values: gpuWin.values,
                            window: window, width: Int(width)),
                          domain: 0...1, tint: T.phaseDecode, height: T.laneDense,
                          staleFromFraction: nil)
            }
            lane("Memory", trailing: memoryTrailing) {
                MemoryLane(sample: hub.latestSystem)
            }
            lane("Power", trailing: powerTrailing) {
                PowerLane(series: hub.wattSeries, window: window, axis: axis)
            }
            lane("Sources", trailing: nil) {
                SampleRug(rows: rugRows, axis: axis)
            }
            axisRuler(axis)
        }
    }

    @ViewBuilder
    private func lane<C: View>(_ title: String, trailing: String?,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(title)
                Spacer()
                if let trailing {
                    Text(trailing).font(T.mono).foregroundStyle(T.inkSecondary)
                }
            }
            content().padding(.leading, 2)
        }
        .padding(.horizontal, T.padPanel).padding(.vertical, 8)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: T.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: T.radiusPanel, style: .continuous)
                    .strokeBorder(T.hairline, lineWidth: T.hairW))
    }

    private func axisRuler(_ axis: TimeAxis) -> some View {
        Canvas { ctx, size in
            for tick in axis.ticks(every: windowSeconds / 4) {
                ctx.draw(Text(tick.label).font(T.axisFnt).foregroundStyle(T.inkMuted),
                         at: CGPoint(x: min(size.width - 12, max(12, tick.x)), y: 6))
            }
        }
        .frame(height: 14)
        .padding(.horizontal, T.padPanel)
    }

    // MARK: - Derived series

    /// The sparse track: one point per actual /slots response, carrying the
    /// real gap since the previous one.
    private var tokenPoints: [SparseTrack.Point] {
        let w = hub.rateSeries.window(window)
        var out: [SparseTrack.Point] = []
        out.reserveCapacity(w.times.count)
        var prev: Double?
        for i in w.times.indices {
            let t = w.times[i]
            out.append(SparseTrack.Point(
                id: i, t: t,
                value: w.values.indices.contains(i) ? w.values[i] : nil,
                gapBefore: prev.map { t - $0 } ?? 1))
            prev = t
        }
        return out
    }

    private var tokenMax: Double {
        tokenPoints.compactMap(\.value).max() ?? 10
    }

    private var rateLabel: String {
        guard let s = hub.activeSlot else { return "idle" }
        guard let v = s.decodeTokensPerSecond.value else {
            return s.decodeTokensPerSecond.confidence.reason ?? Fmt.dash
        }
        return String(format: "%.1f tok/s emitted", v)
            + (s.speculative ? " · speculative" : "")
    }

    private var memoryTrailing: String {
        guard let s = hub.latestSystem else { return Fmt.dash }
        return "\(Fmt.bytes(s.memUsed)) of \(Fmt.bytes(s.memTotal)) · \(s.pressure.label)"
    }

    private var powerTrailing: String {
        guard let p = hub.latestPower else { return Fmt.dash }
        guard let w = p.watts.value else { return p.watts.confidence.reason ?? Fmt.dash }
        let age = p.t - p.lastRefreshedAt
        return String(format: "%.1f W · held %.0fs", w, age)
    }

    private var rugRows: [SampleRug.Row] {
        let now = hub.now
        return [
            SampleRug.Row(id: "sys", label: "sys",
                          times: hub.sysTimes,
                          liveness: hub.sources.liveness(.system, nil, now: now, expected: 0.5),
                          hz: hub.sources.measuredHz(.system, nil)),
            SampleRug.Row(id: "inf", label: "inf",
                          times: hub.rateSeries.times,
                          liveness: hub.sources.liveness(.slots, .bionic, now: now, expected: 1.0),
                          hz: hub.sources.measuredHz(.slots, .bionic)),
            SampleRug.Row(id: "pwr", label: "pwr",
                          times: hub.wattSeries.times,
                          liveness: hub.sources.liveness(.power, nil, now: now, expected: 5),
                          hz: hub.sources.measuredHz(.power, nil)),
        ]
    }
}

/// Memory as an ORDINAL one-hue ramp: wired | compressed | other | free.
/// Validated monotone. The same three hues FAIL as a categorical set, so they
/// must never be presented as independent categories.
struct MemoryLane: View {
    var sample: SystemSample?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let s = sample {
                GeometryReader { geo in
                    let total = Double(s.memTotal)
                    let w = geo.size.width
                    let other = max(0, Double(s.memUsed) - Double(s.memWired) - Double(s.memCompressed))
                    HStack(spacing: T.markGap) {
                        bar(CGFloat(Double(s.memWired) / total) * w, T.memWired)
                        bar(CGFloat(Double(s.memCompressed) / total) * w, T.memCompressed)
                        bar(CGFloat(other / total) * w, T.memOther)
                        Rectangle().fill(T.gridline)
                            .frame(width: max(0, w - CGFloat(Double(s.memUsed) / total) * w))
                    }
                }
                .frame(height: 22)
                HStack(spacing: 14) {
                    legend("wired", Fmt.bytes(s.memWired), T.memWired)
                    legend("compressed", Fmt.bytes(s.memCompressed), T.memCompressed,
                           warn: Double(s.memCompressed) / Double(s.memTotal) > 0.10)
                    legend("other", Fmt.bytes(s.memUsed &- min(s.memUsed, s.memWired &+ s.memCompressed)), T.memOther)
                    legend("free", Fmt.bytes(s.memTotal &- min(s.memTotal, s.memUsed)), T.gridline)
                    Spacer()
                    // File cache is NOT counted as used: a 20-46 GB mmap'd GGUF
                    // in the page cache is reclaimable.
                    Text("page cache \(Fmt.bytes(s.memFileBacked)) · not counted as used")
                        .font(.system(size: 9)).foregroundStyle(T.inkMuted)
                }
            } else {
                Text(Fmt.dash).font(T.metricS).foregroundStyle(T.inkDisabled)
            }
        }
    }

    private func bar(_ w: CGFloat, _ c: Color) -> some View {
        Rectangle().fill(c).frame(width: max(0, w))
    }

    private func legend(_ name: String, _ value: String, _ c: Color, warn: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
                .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(warn ? T.warning : .clear, lineWidth: 1.5))
            Text("\(name) \(value)").font(.system(size: 10))
                .foregroundStyle(warn ? T.warning : T.inkSecondary)
        }
    }
}

/// Power as a step-hold staircase with a dot per real read.
///
/// AppleSmartBattery refreshes only every few seconds; a smooth curve through
/// those points would be a fabrication. The flat segments are HELD, and they
/// look held.
struct PowerLane: View {
    var series: Series<Double?>
    var window: ClosedRange<Double>
    var axis: TimeAxis

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            var base = Path()
            base.move(to: CGPoint(x: 0, y: rect.maxY))
            base.addLine(to: CGPoint(x: size.width, y: rect.maxY))
            ctx.stroke(base, with: .color(T.axis), lineWidth: 1)

            let win = series.window(window)
            var pts: [(Double, Double)] = []
            for i in win.times.indices where win.values.indices.contains(i) {
                if let w = win.values[i] { pts.append((win.times[i], w)) }
            }
            guard !pts.isEmpty else {
                let reason = "no power reading in this window"
                ctx.draw(Text(reason).font(.system(size: 10)).foregroundStyle(T.inkDisabled),
                         at: CGPoint(x: 6, y: rect.midY), anchor: .leading)
                return
            }
            let hi = max(60, (pts.map(\.1).max() ?? 60) * 1.15)
            func y(_ v: Double) -> CGFloat { rect.maxY - CGFloat(v / hi) * rect.height }

            var stair = Path()
            stair.move(to: CGPoint(x: axis.x(pts[0].0), y: y(pts[0].1)))
            for i in 1..<pts.count {
                stair.addLine(to: CGPoint(x: axis.x(pts[i].0), y: y(pts[i - 1].1)))
                stair.addLine(to: CGPoint(x: axis.x(pts[i].0), y: y(pts[i].1)))
            }
            stair.addLine(to: CGPoint(x: size.width, y: y(pts[pts.count - 1].1)))
            ctx.stroke(stair, with: .color(T.engineLocalAI),
                       style: StrokeStyle(lineWidth: T.lineW, lineJoin: .miter))

            for p in pts {
                let x = axis.x(p.0)
                guard x >= 0, x <= size.width else { continue }
                let r: CGFloat = 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y(p.1) - r, width: r * 2, height: r * 2)),
                         with: .color(T.engineLocalAI))
            }
        }
        .frame(height: 44)
    }
}
