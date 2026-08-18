import SwiftUI
import Telemetry

/// EVERY numeric in the app goes through here. Nothing renders a raw Double.
///
/// Confidence maps to ink weight, decoration and caption — never to hue.
/// Hue is already fully spent on phase and status, and a "low-confidence
/// orange" would collide with prefill.
struct EstimateView: View {
    let estimate: Estimate<Double>
    var unit: String = ""
    var font: Font = T.metric
    var decimals: Int = 1
    var scale: Double = 1
    /// In tight chrome, show the em-dash and move the reason to a tooltip.
    /// The reason still has to be reachable — it just must not dominate.
    var compact: Bool = false

    var body: some View {
        switch estimate.confidence {
        case .unavailable(let reason):
            if compact {
                Text(Fmt.dash).font(font).foregroundStyle(T.inkDisabled).help(reason)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.dash).font(font).foregroundStyle(T.inkDisabled)
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(T.inkDisabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .low, .high:
            if let iv = estimate.interval {
                // A bound, not a point. Never show a midpoint.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(fmt(iv.lo)).font(font).foregroundStyle(T.inkPrimary)
                        Text("–").font(font).foregroundStyle(T.inkMuted)
                        Text(fmt(iv.hi) + unitSuffix).font(font).foregroundStyle(T.inkPrimary)
                    }
                    Text("bounded by the poll interval")
                        .font(.system(size: 10)).foregroundStyle(T.inkMuted)
                }
            } else if let v = estimate.value {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        if isLow { Text("~").font(font).foregroundStyle(T.inkSecondary) }
                        Text(fmt(v)).font(font).foregroundStyle(T.inkPrimary)
                            .contentTransition(.numericText())
                        if !unit.isEmpty {
                            Text(unit).font(.system(size: 11)).foregroundStyle(T.inkSecondary)
                        }
                        if isLow, let u = estimate.uncertainty {
                            Text("±\(fmt(u))").font(.system(size: 11))
                                .foregroundStyle(T.inkSecondary)
                        }
                    }
                    if isLow {
                        Text("n=\(estimate.sampleCount) · low confidence")
                            .font(.system(size: 10)).foregroundStyle(T.inkMuted)
                    }
                }
            } else {
                Text(Fmt.dash).font(font).foregroundStyle(T.inkDisabled)
            }
        }
    }

    private var isLow: Bool { estimate.confidence == .low }
    private var unitSuffix: String { unit.isEmpty ? "" : " " + unit }
    private func fmt(_ v: Double) -> String { String(format: "%.\(decimals)f", v * scale) }
}

/// A labelled number that does not jitter as digits change.
struct MetricTile: View {
    let label: String
    let value: String
    var tint: Color = T.inkPrimary
    var caption: String?
    var font: Font = T.metricS

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(label)
            Text(value).font(font).foregroundStyle(tint)
                .monospacedDigit()
            if let caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(T.inkMuted)
            }
        }
    }
}

/// Small state pill. Always ships a word, never colour alone — warning and
/// serious measure dE 13.6 apart, below the categorical floor.
struct Chip: View {
    let text: String
    var tint: Color = T.inkMuted
    var filled: Bool = false
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(filled ? T.plane : tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(filled ? tint : tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

/// Renders the liveness state so that dark, stale, held and live can never be
/// mistaken for one another.
struct LivenessChip: View {
    let name: String
    let liveness: Liveness

    var body: some View {
        HStack(spacing: 5) {
            switch liveness {
            case .live(let hz, let jitter):
                Circle().fill(T.good).frame(width: 5, height: 5)
                Text("\(name) \(Fmt.hz(hz))").font(T.mono).foregroundStyle(T.inkSecondary)
                if jitter > 0.01 {
                    Text("±\(String(format: "%.1f", jitter))")
                        .font(.system(size: 9)).foregroundStyle(T.inkMuted)
                }
            case .held(let age):
                Circle().strokeBorder(T.inkSecondary, lineWidth: 1).frame(width: 5, height: 5)
                Text("\(name) held \(String(format: "%.1f", age))s")
                    .font(T.mono).foregroundStyle(T.inkSecondary)
            case .stale(let age):
                Circle().strokeBorder(T.warning, lineWidth: 1).frame(width: 5, height: 5)
                Text("\(name) stale \(String(format: "%.1f", age))s")
                    .font(T.mono).foregroundStyle(T.warning)
            case .dark(let reason):
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(T.critical)
                Text("\(name) \(reason)").font(T.mono).foregroundStyle(T.critical)
                    .lineLimit(1)
            }
        }
    }
}
