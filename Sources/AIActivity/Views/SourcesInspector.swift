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
                row("SMC sweep",
                    hub.latestThermal.map {
                        String(format: "%.1f ms wall · ~0.9 ms CPU · %d sensors",
                               $0.sampleCostMicros / 1000, $0.sensorsRead)
                    } ?? Fmt.dash)
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

                if hub.roster.contains(where: { $0.engine == .jan }) {
                    Text("""
                    Jan is exempt. It runs its models at verbosity 3 and pipes \
                    their output to a log, so llama.cpp's own token counters and \
                    timings are read from a file instead of from the decode loop. \
                    Jan's instances are polled only while a request is actually in \
                    a slot, and an idle Jan is not polled at all.
                    """)
                    .font(.system(size: 11)).foregroundStyle(T.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

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
                              policy: .slots(for: r.engine),
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
                sourceRow("thermal · SMC", .thermal, nil,
                          policy: .polled(expected: 1.0),
                          exists: hub.latestThermal != nil,
                          absentReason: "SMC not read yet")
                // Push, so its quiet is idleness rather than a fault. Judged
                // under eventDriven for exactly that reason.
                sourceRow("predictions · bionic", .predictions, .bionic,
                          policy: .eventDriven(quietAfter: 300),
                          exists: true,
                          absentReason: "no prediction seen yet")
                // Jan's receipts come from llama.cpp's own print_timing lines
                // in Jan's log. Push, like Bionic's, but they cost nothing and
                // carry an exact TTFT rather than a bracketed one.
                if hub.roster.contains(where: { $0.engine == .jan }) {
                    sourceRow("predictions · jan", .predictions, .jan,
                              policy: .eventDriven(quietAfter: 300),
                              exists: true,
                              absentReason: "no generation seen yet")
                }
            }
        }
    }

    /// One row per ENGINE, not per runtime.
    ///
    /// The roster is a list of runtimes and Jan contributes several -- a router
    /// row, a row per loaded instance, and a row per model it could load -- but
    /// they all share one /slots source keyed by engine. Iterating runtimes
    /// printed four identical "slots · jan" rows reporting the same liveness.
    /// Where an engine has several rows, the one that actually carries token
    /// telemetry is the one that describes the source.
    private var instrumentableRuntimes: [RuntimeInfo] {
        let rs = hub.roster.filter { $0.engine != .ollama && $0.engine != .localai }
        var byEngine: [EngineID: RuntimeInfo] = [:]
        for r in rs {
            if let existing = byEngine[r.engine] {
                // Prefer a runtime that reports, then one that is reachable.
                let better = (r.exposesTokenTelemetry && !existing.exposesTokenTelemetry)
                    || (r.exposesTokenTelemetry == existing.exposesTokenTelemetry
                        && r.reachable && !existing.reachable)
                if better { byEngine[r.engine] = r }
            } else {
                byEngine[r.engine] = r
            }
        }
        return byEngine.values.sorted { $0.engine.rawValue < $1.engine.rawValue }
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
                bullet("Allocated context window — except under Jan", "n_ctx normally reports the model maximum, and --fit-ctx is a fit target the server was observed to exceed by 6%. Jan is the exception: it launches every model with auto-fit OFF, so --ctx-size is a real allocation divided evenly across --parallel slots, and /slots reports that same number. VERIFIED — a Jan child launched --ctx-size 8192 --parallel 2 reported n_ctx 4096 while announcing n_ctx_train 262144, so allocation and maximum are both stated and 64x apart. Where the flags pin it down, this app shows the one true ratio instead of the caveat.")
                bullet("Prometheus counters under Jan", "Jan starts llama-server without --metrics, on the router and on every model instance, so /metrics answers 501. Those counters would have given exact per-request token totals with no polling at all; nothing this app does can enable them.")
                bullet("Anything about a Jan model that is not loaded", "the router would load a model on demand to answer a question about it — a GET naming an unloaded model was MEASURED spawning a child server and reading the weights from disk. So unloaded models are listed from the router's catalogue, which needs no model name, and are never probed. An observer that can cause a 3 GB read is not an observer.")
                bullet("Which client drove a Jan generation", "the router's log records the model, the slot and the timings but carries no caller identity, so a generation started by Jan's own chat window, by another app, or by this one are indistinguishable. Same limitation as LM Studio's diagnostics stream.")
                bullet("Power on AC", "battery amperage reflects charging current, not system load.")
                bullet("CPU throttle percentage", "IOPMCopyCPUPowerStatus returns kIOReturnNotFound on Apple Silicon and pmset -g therm records nothing, so the Intel-era CPU_Speed_Limit does not exist here. The app reports the OS thermal-pressure ladder, which is real, instead of inventing a percentage.")
                bullet("Which sensor is which, from the hardware", "neither the SMC keyspace nor IOHIDEventSystem's names identify a sensor's cluster on M2 Max — the names available are PMU-level (tdie0…tdie10, TP0s). The CPU/GPU map in this app was established by load response and 67 further plausible T* sensors remain unattributed, so they are listed but never headlined.")
                bullet("A quiet manual fan setting", "the SMC accepts no forced target below 2317 rpm, while its own loop stops the fans entirely when cool. Manual control can only ever be louder than automatic at idle.")
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
