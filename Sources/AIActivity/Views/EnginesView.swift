import SwiftUI
import Telemetry

struct EnginesView: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.gutter) {
                WhereTheWorkIs()
                Panel(title: "Engines", trailing: "\(hub.roster.count) discovered") {
                    VStack(spacing: 0) {
                        headerRow
                        Hairline()
                        ForEach(hub.roster) { r in
                            EngineRow(info: r, proc: procFor(r))
                            Hairline()
                        }
                        if hub.roster.isEmpty {
                            Text("No inference runtime found running as this user.")
                                .font(T.body).foregroundStyle(T.inkDisabled)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
            .padding(T.padSection)
        }
    }

    private func procFor(_ r: RuntimeInfo) -> ProcSample? {
        hub.latestSystem?.procs.first { $0.engine == r.engine }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("ENGINE").frame(width: 130, alignment: .leading)
            Text("MODEL").frame(minWidth: 150, alignment: .leading)
            Text("WIRED").frame(width: 90, alignment: .trailing)
                .help("mlock'd weights — should be close to the GGUF size")
            Text("FOOTPRINT").frame(width: 90, alignment: .trailing)
                .help("what the process actually costs the system")
            Text("CPU").frame(width: 70, alignment: .trailing)
            Text("ENDPOINT").frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium)).kerning(0.5)
        .foregroundStyle(T.inkMuted)
        .padding(.vertical, 6)
    }
}

/// Hue is EARNED by residency: an engine holding nothing renders entirely
/// muted with a hollow ring. On a typical screen exactly one engine wears
/// colour, which answers "which of these is actually burning resources"
/// better than any amount of layout.
struct EngineRow: View {
    let info: RuntimeInfo
    let proc: ProcSample?

    private var resident: Bool { info.residentBytes > 1_000_000_000 }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                if resident {
                    RoundedRectangle(cornerRadius: 2).fill(info.engine.hue)
                        .frame(width: 9, height: 9)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(T.inkDisabled, lineWidth: 1.2)
                        .frame(width: 9, height: 9)
                }
                Text(info.engine.displayName)
                    .font(.system(size: 12, weight: resident ? .semibold : .regular))
                    .foregroundStyle(resident ? T.inkPrimary : T.inkMuted)
            }
            .frame(width: 130, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.modelName?.replacingOccurrences(of: ".gguf", with: "") ?? "nothing resident")
                    .font(.system(size: 11)).foregroundStyle(resident ? T.inkSecondary : T.inkDisabled)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let b = info.backend {
                        Text(b).font(.system(size: 9)).foregroundStyle(T.inkMuted)
                    }
                    if !info.exposesTokenTelemetry {
                        Text("· no per-token telemetry")
                            .font(.system(size: 9)).foregroundStyle(T.warning)
                    }
                    if info.busy { Chip(text: "generating", tint: T.good) }
                }
            }
            .frame(minWidth: 150, alignment: .leading)

            Text(proc.map { Fmt.bytes($0.wired) } ?? Fmt.dash)
                .font(T.mono).foregroundStyle(resident ? T.inkPrimary : T.inkDisabled)
                .frame(width: 90, alignment: .trailing)

            Text(proc.map { Fmt.bytes($0.footprint) } ?? Fmt.dash)
                .font(T.mono).foregroundStyle(resident ? T.inkSecondary : T.inkDisabled)
                .frame(width: 90, alignment: .trailing)
                .help(proc.map { "RSS \(Fmt.bytes($0.rss)) — includes mapped file pages, larger than the real cost" } ?? "")

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Text(proc.map { Fmt.pct($0.cpuFraction, decimals: 1) } ?? Fmt.dash)
                    .font(T.mono).foregroundStyle(T.inkPrimary)
                // A near-zero CPU during generation is a real measurement, not
                // staleness. Say so inline so it can't be misread.
                if let p = proc, p.cpuFraction < 0.05, resident {
                    Chip(text: "on GPU")
                }
            }
            .frame(width: 70, alignment: .trailing)

            Text(info.endpoint).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(T.inkMuted)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

/// A CPU column reading 0.2% next to a GPU at 94% looks like a bug. It isn't —
/// so make it the teaching moment rather than hiding it.
struct WhereTheWorkIs: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        Panel(title: "Where the work is",
              trailing: hub.isGenerating ? "generating" : "idle") {
            VStack(alignment: .leading, spacing: 8) {
                meter("GPU device", hub.latestSystem?.gpuDevice, tint: T.phaseDecode)
                meter("CPU (backend process)", cpu, tint: T.memOther)
                HStack(alignment: .top, spacing: 8) {
                    Text("ANE").font(.system(size: 11)).foregroundStyle(T.inkMuted)
                        .frame(width: 140, alignment: .leading)
                    Text("— not measurable without root, and llama.cpp does not use the ANE for GGUF inference")
                        .font(.system(size: 11)).foregroundStyle(T.inkDisabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hub.isGenerating {
                    Text("llama.cpp blocks on a Metal command-buffer wait, so the CPU thread sleeps while the GPU works. Near-zero CPU during generation is correct, not a broken reading.")
                        .font(.system(size: 11)).foregroundStyle(T.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var cpu: Double? {
        hub.latestSystem?.procs.first { $0.engine == .bionic }?.cpuFraction
    }

    private func meter(_ label: String, _ v: Double?, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(T.inkSecondary)
                .frame(width: 140, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(T.gridline)
                    Rectangle().fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, v ?? 0))))
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 10)
            Text(Fmt.pct(v, decimals: 1)).font(T.mono)
                .foregroundStyle(v == nil ? T.inkDisabled : T.inkPrimary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}
