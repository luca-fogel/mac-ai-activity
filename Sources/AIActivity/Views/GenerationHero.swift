import SwiftUI
import Telemetry

/// The hero figure. Makes the Timeline's headline question "what did that
/// generation cost?" rather than "what is the GPU doing?".
///
/// It is a ratio of two quantities sampled at different rates with different
/// confidence, so it never appears as a bare number: it always shows its two
/// inputs and its own uncertainty.
struct GenerationHero: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        Panel(title: "This generation", trailing: taskLabel) {
            HStack(alignment: .top, spacing: T.padSection) {
                VStack(alignment: .leading, spacing: 2) {
                    EstimateView(estimate: hub.joulesPerToken, unit: "J / token",
                                 font: T.hero, decimals: 1, compact: true)
                    Text(hub.unattributedActivity
                         ?? hub.joulesPerToken.confidence.reason
                         ?? "system draw ÷ emitted tok/s")
                        .font(.system(size: 10)).foregroundStyle(T.inkMuted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 230, alignment: .leading)
                }
                Divider().frame(height: 54)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: T.padSection) {
                        MetricTile(label: "System draw",
                                   value: hub.latestPower?.watts.value.map { Fmt.watts($0) } ?? Fmt.dash,
                                   tint: hub.latestPower?.watts.value == nil ? T.inkDisabled : T.inkPrimary,
                                   caption: marginalCaption)
                        MetricTile(label: "Emitted",
                                   value: hub.activeSlot?.decodeTokensPerSecond.value
                                       .map { String(format: "%.1f tok/s", $0) } ?? Fmt.dash,
                                   tint: hub.activeSlot == nil ? T.inkDisabled : T.inkPrimary,
                                   caption: hub.activeSlot?.speculative == true
                                       ? "speculative — acceptance not observable" : nil)
                        MetricTile(label: "Decoded",
                                   value: Fmt.tokens(hub.activeSlot?.nDecoded),
                                   tint: hub.activeSlot == nil ? T.inkDisabled : T.inkPrimary,
                                   caption: ttftCaption)
                    }
                    if let p = lastReceipt { receiptRow(p) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The engine's own receipt for the last COMPLETED prediction.
    ///
    /// Shown only when there is no live slot to report, because that is exactly
    /// when it is the best available answer — and deliberately in a different
    /// visual register from the live tiles above: dimmer ink, its own heading,
    /// its provenance spelled out. An average over a finished generation and an
    /// instantaneous rate are not the same quantity, and must not be able to be
    /// mistaken for one another at a glance.
    private var lastReceipt: PredictionSample? {
        hub.activeSlot == nil ? hub.lastPrediction : nil
    }

    private func receiptRow(_ p: PredictionSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 8)).foregroundStyle(T.inkMuted)
                Text("last completed prediction · reported by the engine")
                    .font(.system(size: 9)).foregroundStyle(T.inkMuted)
            }
            HStack(spacing: T.padSection) {
                receiptField("avg rate", p.tokensPerSecond.value
                    .map { String(format: "%.1f tok/s", $0) })
                receiptField("TTFT", p.timeToFirstToken.value
                    .map { String(format: "%.2f s", $0) })
                receiptField("predicted", p.predictedTokens.map { "\($0) tok" })
                receiptField("prompt", p.promptTokens.map { "\($0) tok" })
                receiptField("stop", p.stopReason)
            }
            Text(p.source + (p.draftAccepted.value
                .map { String(format: " · speculative accept %.0f%%", $0 * 100) } ?? ""))
                .font(.system(size: 9)).foregroundStyle(T.inkMuted)
        }
        .padding(.top, 2)
    }

    private func receiptField(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 8)).foregroundStyle(T.inkMuted)
            Text(value ?? Fmt.dash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(value == nil ? T.inkDisabled : T.inkSecondary)
        }
    }

    private var taskLabel: String {
        if let s = hub.activeSlot {
            return "slot \(s.id)" + (s.idTask.map { " · id_task \($0)" } ?? "")
        }
        if let r = hub.busyOpaqueRuntime {
            return "\(r.backend ?? "MLX") · per-prediction only"
        }
        return "idle"
    }

    private var marginalCaption: String? {
        if let p = hub.latestPower, p.watts.value == nil { return p.watts.confidence.reason }
        guard let floor = hub.idleWattsFloor else { return nil }
        guard let m = hub.marginalWatts else {
            return String(format: "idle floor %.1f W", floor)
        }
        return String(format: "%.1f W floor + %.1f W inference", floor, m)
    }

    private var ttftCaption: String? {
        guard let iv = hub.activeSlot?.timeToFirstToken.interval else { return nil }
        return String(format: "TTFT %.1f–%.1f s", iv.lo, iv.hi)
    }
}
