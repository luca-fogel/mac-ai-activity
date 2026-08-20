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

    /// One row per source that could report, derived from the roster rather
    /// than hardcoded: a fixed "slots · bionic" row showed a permanent error
    /// whenever llama.cpp was not the engine in use.
    private var sourcesPanel: some View {
        Panel(title: "Sources") {
            VStack(alignment: .leading, spacing: 10) {
                sourceRow("system", .system, nil, policy: .polled(expected: 0.5))
                ForEach(instrumentableRuntimes, id: \.id) { r in
                    sourceRow("slots · \(r.engine.rawValue)", .slots, r.engine,
                              policy: .polled(expected: 1.0),
                              exists: r.exposesTokenTelemetry,
                              absentReason: r.telemetryGap)
                }
                sourceRow("power", .power, nil,
                          policy: .heldValue(
                              pollExpected: 5,
                              refreshBound: hub.sources.valueRefreshBound(.power, nil) ?? 30),
                          exists: hub.latestPower != nil,
                          absentReason: "no power sample yet",
                          valueChangedAt: hub.latestPower?.lastRefreshedAt)
                sourceRow("roster", .roster, nil, policy: .polled(expected: 5.0))
                // Push, so its quiet is idleness rather than a fault. Judged
                // under eventDriven for exactly that reason.
                sourceRow("predictions · bionic", .predictions, .bionic,
                          policy: .eventDriven(quietAfter: 300),
                          exists: true,
                          absentReason: "no prediction seen yet")
            }
        }
    }

    private var instrumentableRuntimes: [RuntimeInfo] {
        let rs = hub.roster.filter { $0.engine != .ollama && $0.engine != .localai }
        return rs.isEmpty ? [] : rs
    }

    private func sourceRow(_ name: String, _ kind: SourceKind,
                           _ engine: EngineID?,
                           policy: FreshnessPolicy,
                           exists: Bool = true,
                           absentReason: String? = nil,
                           valueChangedAt: Instant? = nil) -> some View {
        let live = hub.sources.liveness(kind, engine, now: hub.now, policy: policy,
                                        exists: exists, absentReason: absentReason,
                                        valueChangedAt: valueChangedAt)
        return VStack(alignment: .leading, spacing: 3) {
            LivenessChip(name: name, liveness: live)
            HStack(spacing: 12) {
                Text("p50 \(Fmt.secs(hub.sources.latencyP50(kind, engine)))")
                Text("measured \(Fmt.hz(hub.sources.measuredHz(kind, engine)))")
                if case .heldValue = policy,
                   let b = hub.sources.valueRefreshBound(kind, engine) {
                    Text(String(format: "value refresh \u{2264}%.0fs observed", b / 3))
                }
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(T.inkMuted)
        }
    }

    private var notMeasurablePanel: some View {
        Panel(title: "Not measurable here") {
            VStack(alignment: .leading, spacing: 6) {
                bullet("GPU and ANE wattage", "requires root (powermetrics). This app runs unprivileged and does not estimate them.")
                bullet("Speculative accept rate on llama.cpp", "/slots exposes the configuration only; there are no drafted/accepted counters and /metrics is disabled on this server. LM Studio DOES report accepted/rejected draft tokens per prediction, so this is measurable there whenever a draft model is in use.")
                bullet("Live token rate on MLX", "LM Studio emits one stats object at the END of each prediction and nothing during decode, so an exact retrospective figure is available and an instantaneous one does not exist. This app shows the former and refuses to interpolate the latter.")
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
