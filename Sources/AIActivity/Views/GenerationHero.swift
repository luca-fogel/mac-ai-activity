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
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var taskLabel: String {
        if let s = hub.activeSlot {
            return "slot \(s.id)" + (s.idTask.map { " · id_task \($0)" } ?? "")
        }
        if let r = hub.busyOpaqueRuntime {
            return "\(r.backend ?? "MLX") · not instrumented"
        }
        return "idle"
    }

    private var marginalCaption: String? {
        if let p = hub.latestPower, p.onAC { return "AC — metering unavailable" }
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
