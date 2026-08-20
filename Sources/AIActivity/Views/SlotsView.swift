import SwiftUI
import Telemetry

struct SlotsView: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.gutter) {
                if let inf = hub.latestInference {
                    ForEach(inf.slots) { SlotCard(slot: $0) }
                } else {
                    Panel(title: "Slots") {
                        Text("No inference endpoint discovered yet.")
                            .font(T.body).foregroundStyle(T.inkDisabled)
                    }
                }
            }
            .padding(T.padSection)
        }
    }
}

/// The three slot states are rendered as incommensurable, not merely tinted.
/// A never-used slot shows em-dashes; an idle slot shows its FROZEN numbers in
/// muted ink on a hatch with an age badge; only a processing slot gets full ink.
struct SlotCard: View {
    let slot: SlotSample

    var body: some View {
        Panel(title: "Slot \(slot.id)", trailing: trailing) {
            switch slot.state {
            case .neverUsed:
                VStack(alignment: .leading, spacing: 6) {
                    Text("No request has run on this slot; llama-server exposes no counters for it.")
                        .font(T.body).foregroundStyle(T.inkMuted)
                    HStack(spacing: T.padSection) {
                        MetricTile(label: "Context", value: Fmt.dash, tint: T.inkDisabled)
                        MetricTile(label: "Decoded", value: Fmt.dash, tint: T.inkDisabled)
                        MetricTile(label: "TTFT", value: Fmt.dash, tint: T.inkDisabled)
                    }
                }
            case .idleWithHistory, .prefilling, .processing:
                VStack(alignment: .leading, spacing: 12) {
                    ContextCompositionBar(slot: slot)
                    HStack(alignment: .top, spacing: T.padSection) {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Decode rate")
                            EstimateView(estimate: slot.decodeTokensPerSecond,
                                         unit: "tok/s", font: T.metricS)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Time to first token")
                            EstimateView(estimate: slot.timeToFirstToken,
                                         unit: "s", font: T.metricS, decimals: 2)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Prompt cache reuse")
                            EstimateView(estimate: slot.cacheHitRate,
                                         unit: "%", font: T.metricS, scale: 100)
                        }
                        Spacer()
                    }
                    if let s = slot.sampler { SamplerGrid(params: s, live: slot.state.isBusy) }
                }
                .opacity(slot.state.isBusy ? 1 : 0.62)
                .background(alignment: .topLeading) {
                    if slot.state == .idleWithHistory {
                        Hatch(spacing: 8).stroke(T.hatchStale, lineWidth: 1)
                    }
                }
            }
        }
    }

    private var trailing: String {
        switch slot.state {
        case .neverUsed:       return "NEVER USED"
        case .idleWithHistory: return "IDLE · counters frozen" + (slot.idTask.map { " · last id_task \($0)" } ?? "")
        case .prefilling:      return "PREFILLING · computing the prompt" + (slot.idTask.map { " · id_task \($0)" } ?? "")
        case .processing:      return "DECODING" + (slot.idTask.map { " · id_task \($0)" } ?? "")
        }
    }
}

/// Answers "how much of this prompt did the model actually have to think
/// about?" — and keeps the two context denominators separate and named,
/// because neither is the allocated window.
struct ContextCompositionBar: View {
    let slot: SlotSample

    var body: some View {
        let c = slot.context
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Context")
                Spacer()
                Text("\(Fmt.tokens(c.tokens)) tokens").font(T.mono).foregroundStyle(T.inkSecondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let cached = Double(slot.nPromptTokensCache ?? 0)
                let computed = Double(slot.nPromptTokensProcessed ?? 0)
                let gen = Double(slot.nDecoded ?? 0)
                let total = max(cached + computed + gen, 1)
                HStack(spacing: T.markGap) {
                    seg(w * cached / total, T.phaseCached)
                    seg(w * computed / total, T.phasePrefill)
                    seg(w * gen / total, T.phaseDecode)
                }
            }
            .frame(height: 20)
            HStack(spacing: 14) {
                key("recalled from cache", Fmt.tokens(slot.nPromptTokensCache), T.phaseCached)
                key("computed at prefill", Fmt.tokens(slot.nPromptTokensProcessed), T.phasePrefill)
                key("generated", Fmt.tokens(slot.nDecoded), T.phaseDecode)
                Spacer()
            }
            Text("cached and computed freeze after prefill; generated grows live")
                .font(.system(size: 9)).foregroundStyle(T.inkMuted)

            // The falsified hypothesis, shown rather than hidden.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 14) {
                    denom("vs --fit-ctx \(Fmt.tokens(c.fitTarget))",
                          c.fractionOfFitTarget, warn: c.exceededFitTarget)
                    denom("vs n_ctx \(Fmt.tokens(c.modelMaximum)) (model max)",
                          c.fractionOfModelMaximum, warn: false)
                }
                if c.exceededFitTarget {
                    Text("⚠ the server exceeded its --fit-ctx target, so that flag is a fit hint, not a ceiling")
                        .font(.system(size: 9)).foregroundStyle(T.warning)
                }
                Text(c.allocatedWindow.confidence.reason ?? "")
                    .font(.system(size: 9)).foregroundStyle(T.inkDisabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func seg(_ w: CGFloat, _ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(c).frame(width: max(0, w))
    }

    private func key(_ name: String, _ v: String, _ c: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text("\(name) \(v)").font(.system(size: 10)).foregroundStyle(T.inkSecondary)
        }
    }

    private func denom(_ label: String, _ frac: Double?, warn: Bool) -> some View {
        HStack(spacing: 5) {
            Text(Fmt.pct(frac, decimals: 1))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(warn ? T.warning : T.inkPrimary)
            Text(label).font(.system(size: 10)).foregroundStyle(T.inkMuted)
        }
    }
}

/// The decode-time knobs actually in force. Free — same response as the
/// counters — and genuinely "how the model works".
struct SamplerGrid: View {
    let params: SamplerParams
    var live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Sampler")
                Spacer()
                if !params.extra.isEmpty {
                    Button(expanded ? "fewer" : "\(params.extra.count) more") { expanded.toggle() }
                        .buttonStyle(.plain).font(.system(size: 10))
                        .foregroundStyle(T.inkMuted)
                }
            }
            let cols = [GridItem(.adaptive(minimum: 118), spacing: 10)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 5) {
                cell("temp", params.temperature.map { String(format: "%.2f", $0) }, nonDefault: params.temperature != 1.0)
                cell("top_k", params.topK.map(String.init), nonDefault: params.topK != 40)
                cell("top_p", params.topP.map { String(format: "%.2f", $0) }, nonDefault: false)
                cell("min_p", params.minP.map { String(format: "%.2f", $0) }, nonDefault: false)
                cell("repeat", params.repeatPenalty.map { String(format: "%.2f", $0) }, nonDefault: params.repeatPenalty != 1.0)
                cell("n_predict", params.nPredict.map { $0 < 0 ? "∞" : String($0) }, nonDefault: false)
                if expanded {
                    ForEach(params.extra.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        cell(k, v, nonDefault: false)
                    }
                }
            }
            if !params.samplerChain.isEmpty {
                Text("chain: " + params.samplerChain.joined(separator: " → "))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(T.inkMuted)
            }
        }
    }

    private func cell(_ k: String, _ v: String?, nonDefault: Bool) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 10)).foregroundStyle(T.inkMuted)
            Text(v ?? Fmt.dash).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(v == nil ? T.inkDisabled : (live ? T.inkPrimary : T.inkMuted))
            if nonDefault { Text("▸").font(.system(size: 7)).foregroundStyle(T.warning) }
        }
    }
}
