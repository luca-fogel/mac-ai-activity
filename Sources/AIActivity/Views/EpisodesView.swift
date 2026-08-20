import SwiftUI
import Telemetry

/// Recent generations, newest first.
///
/// This is the surface that makes MLX and llama.cpp comparable. Tokens are only
/// available from llama.cpp, so the token and J/token columns show an em-dash
/// for MLX — but duration, GPU shape and integrated energy are observable for
/// both, which is enough to compare backends on the thing that matters.
struct EpisodesView: View {
    @Environment(TelemetryHub.self) private var hub

    var body: some View {
        // Establishes the observation dependency: episodes themselves are
        // @ObservationIgnored so they cannot trigger 10 Hz invalidation.
        let _ = hub.revision
        return Panel(title: "Recent generations",
              trailing: hub.episodes.isEmpty ? "none yet" : "\(hub.episodes.count) in memory") {
            VStack(spacing: 0) {
                header
                Hairline()
                if let cur = hub.currentEpisode {
                    row(cur, live: true)
                    Hairline()
                }
                ForEach(hub.episodes.prefix(6)) { e in
                    row(e, live: false)
                    Hairline()
                }
                if hub.episodes.isEmpty && hub.currentEpisode == nil {
                    // Two different situations, and they must not share a label.
                    if let p = hub.unenvelopedPrediction {
                        Text(unenvelopedNote(p))
                            .font(T.body).foregroundStyle(T.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 10)
                    } else {
                        Text("Send a prompt to either backend and it will appear here.")
                            .font(T.body).foregroundStyle(T.inkDisabled)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("BACKEND").frame(width: 74, alignment: .leading)
            Text("MODEL").frame(minWidth: 120, alignment: .leading)
            Text("DURATION").frame(width: 76, alignment: .trailing)
            Text("PREFILL").frame(width: 66, alignment: .trailing)
            Text("PEAK GPU").frame(width: 74, alignment: .trailing)
            Text("ENERGY").frame(width: 76, alignment: .trailing)
            Text("TOKENS").frame(width: 62, alignment: .trailing)
            Text("J / TOKEN").frame(width: 78, alignment: .trailing)
            // Labelled "reported" throughout: these come from the engine, not
            // from this app's sampling, and the distinction is the point.
            Text("REPORTED TOK/S").frame(width: 74, alignment: .trailing)
            Text("REPORTED TTFT").frame(width: 66, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium)).kerning(0.5)
        .foregroundStyle(T.inkMuted)
        .padding(.vertical, 6)
    }

    private func row(_ e: Episode, live: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                if live {
                    Circle().fill(T.good).frame(width: 5, height: 5)
                }
                Text(e.backend).font(.system(size: 11, weight: live ? .semibold : .regular))
                    .foregroundStyle(live ? T.inkPrimary : T.inkSecondary)
            }
            .frame(width: 74, alignment: .leading)

            Text(e.model.replacingOccurrences(of: ".gguf", with: ""))
                .font(.system(size: 11)).foregroundStyle(T.inkSecondary)
                .frame(minWidth: 120, alignment: .leading).lineLimit(1)

            mono(e.duration.map { String(format: "%.1f s", $0) } ?? "running", 76)
            mono(e.prefillSeconds.map { String(format: "%.1f s", $0) } ?? Fmt.dash, 66)
            mono(Fmt.pct(e.peakGPU), 74)
            mono(e.energy.value.map { String(format: "%.0f J", $0) } ?? Fmt.dash, 76)
            mono(e.tokens.map(String.init) ?? Fmt.dash, 62)
                .help(e.reportedBy.map { "token count reported by the engine via \($0)" }
                      ?? "from the slot counters")
            mono(e.joulesPerToken.value.map { String(format: "%.1f", $0) } ?? Fmt.dash, 78)
                .help(e.joulesPerToken.confidence.reason ?? "integrated power ÷ tokens")
            // The engine's own average, kept in its own column so it can never
            // be mistaken for the sampled rate. Exact, and only knowable after
            // the generation ended — which is why MLX has this and no live rate.
            mono(e.reportedTokensPerSecond.map { String(format: "%.1f", $0) } ?? Fmt.dash, 74)
                .help(e.reportedBy.map { "average over the whole prediction, reported by the engine via \($0)" }
                      ?? "no engine-reported rate for this generation")
            mono(e.reportedTTFT.map { String(format: "%.2f s", $0) } ?? Fmt.dash, 66)
                .help(e.reportedTTFT == nil
                      ? "no engine-reported TTFT"
                      : "exact: the engine was the client, so this is not a bounded interval")
        }
        .padding(.vertical, 7)
    }

    /// Says what happened AND why there is no row for it, rather than implying
    /// nothing ran.
    private func unenvelopedNote(_ p: PredictionSample) -> String {
        let d = p.totalSeconds.map { String(format: "%.1f s", $0) } ?? "under a second"
        let tok = p.predictedTokens.map { "\($0) tokens" } ?? "an unknown number of tokens"
        return """
        \(p.modelIdentifier) completed a prediction (\(tok) in \(d)), reported by the engine. \
        It finished between two roster polls, which happen every 5 s, so no GPU or power \
        envelope was captured for it — energy per token needs an interval this app actually \
        observed, and inventing one would be worse than leaving it out.
        """
    }

    private func mono(_ s: String, _ w: CGFloat) -> some View {
        Text(s).font(T.mono)
            .foregroundStyle(s == Fmt.dash ? T.inkDisabled : T.inkPrimary)
            .frame(width: w, alignment: .trailing)
    }
}

/// Prefill vs decode as bands on the shared time axis.
///
/// This is the comparison the whole app exists for: the prefill band sits under
/// a saturated GPU with NO token output, and the decode band under a lower,
/// choppier GPU with steady output. Two visually distinct regimes on one axis.
struct PhaseBandLane: View {
    var episodes: [Episode]
    var current: Episode?
    var axis: TimeAxis
    var window: ClosedRange<Double>

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let all = episodes + (current.map { [$0] } ?? [])
            for e in all {
                let s = e.start.s
                let end = e.end?.s ?? window.upperBound
                guard end >= window.lowerBound, s <= window.upperBound else { continue }
                let x0 = max(0, axis.x(max(s, window.lowerBound)))
                let x1 = min(size.width, axis.x(min(end, window.upperBound)))
                guard x1 > x0 else { continue }

                // Prefill band, when the boundary was observable.
                if let p = e.prefillEnded?.s {
                    let xp = min(size.width, axis.x(min(p, window.upperBound)))
                    if xp > x0 {
                        ctx.fill(Path(CGRect(x: x0, y: 2, width: xp - x0, height: size.height - 4)),
                                 with: .color(T.phasePrefill.opacity(0.30)))
                        if xp - x0 > 46 {
                            ctx.draw(Text("prefill").font(.system(size: 9))
                                        .foregroundStyle(T.phasePrefill),
                                     at: CGPoint(x: x0 + 5, y: size.height / 2), anchor: .leading)
                        }
                    }
                    if x1 > xp {
                        ctx.fill(Path(CGRect(x: xp, y: 2, width: x1 - xp, height: size.height - 4)),
                                 with: .color(T.phaseDecode.opacity(0.28)))
                        if x1 - xp > 44 {
                            ctx.draw(Text("decode").font(.system(size: 9))
                                        .foregroundStyle(T.phaseDecode),
                                     at: CGPoint(x: xp + 5, y: size.height / 2), anchor: .leading)
                        }
                    }
                } else {
                    // No observable phase boundary (MLX): one neutral band, and
                    // say so rather than implying we resolved the phases.
                    ctx.fill(Path(CGRect(x: x0, y: 2, width: x1 - x0, height: size.height - 4)),
                             with: .color(T.inkMuted.opacity(0.22)))
                    if x1 - x0 > 118 {
                        ctx.draw(Text("\(e.backend) · phases not observable")
                                    .font(.system(size: 9)).foregroundStyle(T.inkSecondary),
                                 at: CGPoint(x: x0 + 5, y: size.height / 2), anchor: .leading)
                    }
                }
                // Episode boundary rule.
                var b = Path()
                b.move(to: CGPoint(x: x0, y: 0)); b.addLine(to: CGPoint(x: x0, y: size.height))
                ctx.stroke(b, with: .color(T.inkSecondary.opacity(0.5)), lineWidth: 1)
            }
        }
        .frame(height: 22)
    }
}
