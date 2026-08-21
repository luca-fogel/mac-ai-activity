import SwiftUI
import Telemetry

/// Always visible. The handful of numbers you glance at, plus the honesty
/// instruments (measured rates and the observer-effect receipt).
struct StatusRail: View {
    @Environment(TelemetryHub.self) private var hub

    // The runtime actually doing the work -- NOT necessarily the one with an
    // HTTP API. Bionic can host llama.cpp and MLX at once, and only llama.cpp
    // exposes /slots.
    /// Whichever engine is actually working — not necessarily llama.cpp, and
    /// under Jan not necessarily the process that owns the port.
    private var working: RuntimeInfo? { hub.workingRuntime }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: T.padSection) {
                modelChip
                Divider().frame(height: 22)
                gpuTile
                memTile
                powerTile
                thermalTile
                fanTile
                Spacer(minLength: 8)
                jouleTile
            }
            HStack(spacing: 14) {
                rateChips
                Spacer(minLength: 8)
                observerReceipt
            }
            if let note = hub.unattributedActivity {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(T.warning)
                    Text(note).font(.system(size: 10)).foregroundStyle(T.warning)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, T.padSection)
        .padding(.vertical, 10)
        .background(T.surface)
        .onChange(of: working?.generation?.pid) { _, _ in refreshFacts() }
        .onAppear { refreshFacts() }
    }

    private var modelChip: some View {
        HStack(spacing: 7) {
            Circle()
                // The generating engine's own hue. Pinned to Bionic's blue, a
                // Jan generation lit up in another engine's colour.
                .fill(hub.isGenerating
                      ? (working?.engine.hue ?? EngineID.bionic.hue)
                      : T.inkDisabled)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(working?.modelName.map(shorten) ?? "no model resident")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(working == nil ? T.inkDisabled : T.inkPrimary)
                HStack(spacing: 5) {
                    if let b = working?.backend {
                        Chip(text: b, tint: working?.engine.hue ?? T.engineBionic)
                    }
                    if let q = working?.quantization { Chip(text: q) }
                    if let s = working?.speculativeType { Chip(text: "spec \(s)") }
                    Text(stateWord)
                        .font(.system(size: 10)).foregroundStyle(T.inkMuted)
                    if hub.residentRuntimes.count > 1 {
                        Text("· \(hub.residentRuntimes.count) models resident")
                            .font(.system(size: 10)).foregroundStyle(T.warning)
                            .help(hub.residentRuntimes
                                    .map { "\($0.backend ?? $0.engine.displayName): \(Fmt.bytes($0.residentBytes))" }
                                    .joined(separator: "\n"))
                    }
                }
            }
        }
        // Static facts live in a hover popover, not as tiles on the dashboard.
        // Computed only when the model identity changes -- rebuilding this
        // string on every render was pure waste at 10 Hz.
        .help(cachedFacts)
    }

    @State private var cachedFacts: String = ""

    /// "idle" alone implied this was the only model. It is not.
    /// Be explicit about WHY this model is the one on screen, because with
    /// several resident there is no single right answer.
    private var stateWord: String {
        if hub.isGenerating { return "generating" }
        if !hub.lastBusyAt.isEmpty { return "idle · last active" }
        return hub.residentRuntimes.count > 1 ? "idle · most recently started" : "idle"
    }

    private var staticFacts: String {
        guard let b = working else { return "No model resident." }
        var l: [String] = []
        if let m = b.modelName { l.append(m) }
        if let p = b.paramCount { l.append("\(p / 1_000_000_000) B parameters") }
        if let f = b.fileBytes { l.append(Fmt.bytes(f) + " on disk") }
        if let c = b.nCtxReported { l.append("n_ctx reported \(c) (model maximum)") }
        if let c = b.nCtxFitted { l.append("--fit-ctx \(c) (a fit target, not a ceiling)") }
        if let s = b.totalSlots { l.append("\(s) parallel slots") }
        if let m = b.loadMode { l.append("load mode \(m)") }
        l.append("endpoint \(b.endpoint)")
        return l.joined(separator: "\n")
    }

    private func refreshFacts() { cachedFacts = staticFacts }

    private var gpuTile: some View {
        MetricTile(label: "GPU",
                   value: Fmt.pct(hub.latestSystem?.gpuDevice),
                   tint: (hub.latestSystem?.gpuDevice ?? 0) > 0.5 ? T.inkPrimary : T.inkSecondary,
                   caption: Fmt.bytes(hub.latestSystem?.gpuInUseBytes) + " metal")
    }

    private var memTile: some View {
        let s = hub.latestSystem
        return MetricTile(
            label: "Memory",
            value: s.map { Fmt.bytes($0.memUsed) } ?? Fmt.dash,
            tint: (s?.pressure ?? .nominal) == .nominal ? T.inkPrimary : (s?.pressure.tint ?? T.inkPrimary),
            caption: s.map { "of \(Fmt.bytes($0.memTotal)) · \($0.pressure.label)" })
    }

    private var powerTile: some View {
        let p = hub.latestPower
        let held = p.map { $0.t - $0.lastRefreshedAt } ?? 0
        return MetricTile(
            label: "Power",
            value: p?.watts.value.map { Fmt.watts($0) } ?? Fmt.dash,
            tint: p?.watts.value == nil ? T.inkDisabled : T.inkPrimary,
            caption: powerCaption(p, held: held))
    }

    /// Only claim metering is unavailable when there is genuinely no number.
    private func powerCaption(_ p: PowerSample?, held: Double) -> String? {
        guard let p else { return nil }
        if p.watts.value == nil { return p.watts.confidence.reason }
        if let m = hub.marginalWatts { return String(format: "+%.1f W vs idle", m) }
        return "held \(String(format: "%.0f", max(0, held)))s" + (p.onAC ? " · on AC" : "")
    }

    /// The hotspot, NOT "CPU temperature".
    ///
    /// During GPU-bound inference — which is what local inference is — the CPU
    /// clusters are power-gated and their sensors read 12–23 °C while the GPU
    /// sits at 82 °C. A CPU-labelled headline would FALL as the machine got
    /// hotter, so this tile always says which domain it is quoting.
    private var thermalTile: some View {
        let th = hub.latestThermal
        let hot = th?.hotspot
        return MetricTile(
            label: "Hotspot",
            value: hot?.estimate.value.map { Fmt.celsius($0, decimals: 1) } ?? Fmt.dash,
            tint: hotTint(hot?.estimate.value),
            caption: hot.map { "\($0.domain.displayName) · \(th?.pressure.rawValue ?? "")" }
                ?? th.map { "no die sensor · \($0.pressure.rawValue)" }
                ?? "SMC not read yet")
        .help("""
        Hottest die sensor across the CPU and GPU clusters, from the SMC.
        Power-gated clusters are excluded rather than reported as cold.
        The battery sensor is a separate reading: \(hub.latestPower?.batteryTempC.map { String(format: "%.1f °C", $0) } ?? "—").
        """)
    }

    private func hotTint(_ c: Double?) -> Color {
        guard let c else { return T.inkDisabled }
        if c >= 95 { return T.critical }
        if c >= 85 { return T.serious }
        return T.inkPrimary
    }

    /// Fans earn a tile only because control exists: when the app is holding a
    /// fan, that fact has to be visible from every tab, not just the one with
    /// the slider on it.
    private var fanTile: some View {
        let th = hub.latestThermal
        let rpm = th?.fans.compactMap { $0.actualRPM }.max()
        let forced = th?.control?.forcing ?? false
        return MetricTile(
            label: "Fans",
            value: Fmt.rpm(rpm),
            tint: forced ? T.warning : T.inkPrimary,
            caption: forced
                ? "held by this app · lease \(th?.control?.leaseRemaining.map { String(format: "%.0fs", $0) } ?? "—")"
                : (th?.fans.isEmpty == false ? "SMC automatic" : nil))
    }

    /// The hero metric gets a permanent home so it is never off-screen.
    private var jouleTile: some View {
        VStack(alignment: .trailing, spacing: 1) {
            SectionLabel("Energy / token")
            EstimateView(estimate: hub.joulesPerToken, unit: "J/tok",
                         font: T.metric, decimals: 1, compact: true)
        }
    }

    private var rateChips: some View {
        let now = hub.now
        return HStack(spacing: 12) {
            LivenessChip(name: "sys",
                         liveness: hub.sources.liveness(.system, nil, now: now,
                                                        policy: .polled(expected: 0.5)))
            LivenessChip(name: "inf", liveness: hub.inferenceLiveness)
            LivenessChip(name: "pwr", liveness: powerLiveness)
        }
    }

    /// Power has two clocks, and conflating them was the bug.
    ///
    /// Our poll succeeds every 5 s, while AppleSmartBattery's values
    /// legitimately sit unchanged for far longer. Measuring the VALUE's age
    /// against the POLL's schedule produced a warning-coloured
    /// "pwr stale 44.5s" on a perfectly healthy collector. Held is the normal
    /// state here; stale means the value stopped moving for longer than this
    /// source has ever been observed to take.
    private var powerLiveness: Liveness {
        let p = hub.latestPower
        // On AC there is no number at all, so there is nothing to be stale
        // about — the honest report is the reason, not an age.
        if let p, p.watts.value == nil {
            return .absent(p.watts.confidence.reason ?? "power unavailable")
        }
        // Until the refresh cadence has been measured, 30 s is a documented
        // default rather than a claim; once measured, the source is held to its
        // own observed behaviour.
        let bound = hub.sources.valueRefreshBound(.power, nil) ?? 30
        return hub.sources.liveness(
            .power, nil, now: hub.now,
            policy: .heldValue(pollExpected: 5, refreshBound: bound),
            exists: p != nil,
            absentReason: "no power sample yet",
            valueChangedAt: p?.lastRefreshedAt)
    }

    private var observerReceipt: some View {
        let ms = hub.slotServerMillis
        let frac = min(1, ms / 60_000)
        return HStack(spacing: 6) {
            Image(systemName: "circle.dotted").font(.system(size: 9))
                .foregroundStyle(T.inkMuted)
            Text("self-cost \(hub.slotPollCount) polls/min · \(Fmt.pct(frac)) of server")
                .font(T.mono).foregroundStyle(frac > 0.2 ? T.warning : T.inkMuted)
        }
        .help("""
        Polling /slots occupies the server's decode loop. \
        Measured tok/s is depressed by roughly this fraction, and the \
        energy-per-token figure inherits the same bias.
        """)
    }

    private func shorten(_ s: String) -> String {
        s.replacingOccurrences(of: ".gguf", with: "")
    }
}
