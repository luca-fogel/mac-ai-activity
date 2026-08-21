import SwiftUI
import Telemetry

/// The menu bar is already crowded (QwenMenu and LLMMenu both live there, and
/// items get squeezed out by front-app menus), and LLMMenu already owns "GB
/// held". So: a glyph when idle, and tok/s — a number that exists nowhere else
/// on this Mac — only while generating.
struct MenuBarLabel: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: glyph)
            if let v = hub.activeSlot?.decodeTokensPerSecond.value {
                Text(String(format: "%.0f", v))
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private var glyph: String {
        if hub.roster.contains(where: { $0.residentBytes > 1_000_000_000 }) {
            return hub.isGenerating ? "cpu.fill" : "cpu"
        }
        return "cpu"
    }
}

struct MenuBarReadout: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The engine that is actually working. Pinned to Bionic, the menu
            // bar read "No model resident" through every Jan generation.
            Text(hub.workingRuntime?.modelName?
                    .replacingOccurrences(of: ".gguf", with: "") ?? "No model resident")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: T.padSection) {
                MetricTile(label: "tok/s",
                           value: hub.activeSlot?.decodeTokensPerSecond.value
                               .map { String(format: "%.1f", $0) } ?? Fmt.dash)
                MetricTile(label: "GPU", value: Fmt.pct(hub.latestSystem?.gpuDevice))
                MetricTile(label: "J/tok",
                           value: hub.joulesPerToken.value.map { String(format: "%.1f", $0) } ?? Fmt.dash)
            }
            Divider()
            Button("Open AI Activity") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(.plain).font(.system(size: 11))
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(T.inkMuted)
        }
        .padding(14)
        .frame(width: 260)
    }
}
