import SwiftUI
import Telemetry

/// Diagnostics, one keystroke away rather than a tab competing with research
/// views. Also the one place the app states what it CANNOT measure — saying
/// where the boundary is beats hinting that a greyed-out dial might light up.
struct SourcesInspector: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.gutter) {
                observerPanel
                sourcesPanel
                notMeasurablePanel
            }
            .padding(T.padPanel)
        }
        .background(T.plane)
    }

    private var observerPanel: some View {
        Panel(title: "Observer cost") {
            VStack(alignment: .leading, spacing: 8) {
                row("collector", "~31 µs/tick · 0.03% of one core")
                row("/slots polls", "\(hub.slotPollCount) in the last minute")
                row("server time taken",
                    String(format: "%.1f s of the last 60 s (%.0f%%)",
                           hub.slotServerMillis / 1000,
                           min(100, hub.slotServerMillis / 600)))
                Divider()
                Text("""
                Polling /slots occupies llama-server's decode loop, so measured \
                tok/s is depressed by roughly that fraction — and the \
                energy-per-token figure inherits the same bias.
                """)
                .font(.system(size: 11)).foregroundStyle(T.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Picker("Cadence", selection: Binding(
                    get: { hub.cadence },
                    set: { hub.setCadence($0) })) {
                    Text("Adaptive (1 Hz)").tag(CadenceMode.adaptive)
                    Text("Minimum perturbation (0.2 Hz)").tag(CadenceMode.minimumPerturbation)
                    Text("System only (off)").tag(CadenceMode.systemOnly)
                }
                .pickerStyle(.radioGroup).font(.system(size: 11))
                .help("Reduces this app's polling. Does not change the server.")
            }
        }
    }

    private var sourcesPanel: some View {
        Panel(title: "Sources") {
            VStack(alignment: .leading, spacing: 10) {
                sourceRow("system", .system, nil, expected: 0.5)
                sourceRow("slots · bionic", .slots, .bionic, expected: 1.0)
                sourceRow("power", .power, nil, expected: 5.0)
                sourceRow("roster", .roster, nil, expected: 5.0)
            }
        }
    }

    private func sourceRow(_ name: String, _ kind: SourceKind,
                           _ engine: EngineID?, expected: Double) -> some View {
        let live = hub.sources.liveness(kind, engine, now: hub.now, expected: expected)
        return VStack(alignment: .leading, spacing: 3) {
            LivenessChip(name: name, liveness: live)
            HStack(spacing: 12) {
                Text("p50 \(Fmt.secs(hub.sources.latencyP50(kind, engine)))")
                Text("measured \(Fmt.hz(hub.sources.measuredHz(kind, engine)))")
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(T.inkMuted)
        }
    }

    private var notMeasurablePanel: some View {
        Panel(title: "Not measurable here") {
            VStack(alignment: .leading, spacing: 6) {
                bullet("GPU and ANE wattage", "requires root (powermetrics). This app runs unprivileged and does not estimate them.")
                bullet("Speculative accept rate", "/slots exposes the configuration only; there are no drafted/accepted counters and /metrics is disabled on this server.")
                bullet("Allocated context window", "n_ctx reports the model maximum and --fit-ctx is a fit target that the server was observed to exceed.")
                bullet("Power on AC", "battery amperage reflects charging current, not system load.")
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(T.inkMuted)
            Spacer()
            Text(v).font(T.mono).foregroundStyle(T.inkSecondary)
        }
    }

    private func bullet(_ title: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(T.inkSecondary)
            Text(why).font(.system(size: 10)).foregroundStyle(T.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
