import SwiftUI
import Telemetry

/// Dark-only instrument palette.
///
/// Validated with the dataviz skill's validate_palette.js against the ACTUAL
/// surface (#121417), not the default. Do not change a hex without re-running
/// it. Two candidates were tested and rejected: violet #9085E9 (protan dE 1.9
/// vs blue) and magenta #D55181 (deutan dE 1.6 vs aqua).
enum T {

    // MARK: Surfaces
    static let plane        = Color(hex: 0x0B0D0F)
    static let surface      = Color(hex: 0x121417)   // the validated surface
    static let surfaceRaise = Color(hex: 0x171A1E)
    static let hairline     = Color(hex: 0x22262B)
    static let gridline     = Color(hex: 0x1B1F24)
    static let axis         = Color(hex: 0x2B3036)

    // MARK: Ink (measured contrast vs surface)
    static let inkPrimary   = Color(hex: 0xF2F4F6)   // 16.73:1
    static let inkSecondary = Color(hex: 0xA7B0B8)   //  8.39:1
    static let inkMuted     = Color(hex: 0x6B747C)   //  3.88:1 — labels, STALE values
    static let inkDisabled  = Color(hex: 0x454C53)   //  2.12:1 — em-dashes

    // MARK: Engine identity — IDENTITY CHROME ONLY, never a plot fill.
    // all-pairs CVD dE 8.4, normal-vision 19.8
    static let engineBionic  = Color(hex: 0x3987E5)
    static let engineLocalAI = Color(hex: 0x199E70)
    static let engineOllama  = Color(hex: 0xC98500)
    /// Jan. Added as a FOURTH categorical hue rather than shared, because Jan
    /// and Bionic are both llama.cpp holding multi-GB models and can be
    /// resident simultaneously, so they are the one pair that must never be
    /// confusable. Checked the same way as the other three: simulated under
    /// deuteranopia, protanopia and tritanopia, its worst-case CIELAB
    /// separation from all three existing hues is dE 25.4 — above the dE 15.7
    /// floor the surviving trio already sits at (green vs amber under
    /// tritanopia). L* 55 puts it in the same lightness band (56/58/61), so it
    /// carries no more visual weight than its neighbours.
    static let engineJan     = Color(hex: 0xAA6EAA)

    // MARK: Phase — PLOT AREAS ONLY.
    static let phasePrefill = Color(hex: 0xD95926)
    static let phaseDecode  = Color(hex: 0x3987E5)
    static let phaseCached  = Color(hex: 0x256ABF)
    static let phaseIdle    = Color(hex: 0x454C53)

    // MARK: Memory ramp — ORDINAL, one hue, light->dark = less reclaimable.
    // Validated monotone (dL >= 0.06). The same three FAIL as categorical
    // (dE 9.5), so they must never be presented as independent categories.
    static let memOther      = Color(hex: 0x6DA7EC)
    static let memCompressed = Color(hex: 0x3987E5)
    static let memWired      = Color(hex: 0x256ABF)

    // MARK: Status — fixed, never themed, never a series.
    static let good     = Color(hex: 0x0CA30C)
    static let warning  = Color(hex: 0xFAB219)
    static let serious  = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)

    // MARK: Chart ink
    static let areaWash: Double = 0.10
    static let nowCursor  = Color(hex: 0xF2F4F6).opacity(0.40)
    static let hatchStale = Color(hex: 0x6B747C).opacity(0.18)

    // MARK: Type
    static let hero    = Font.system(size: 40, weight: .semibold).monospacedDigit()
    static let metric  = Font.system(size: 22, weight: .semibold).monospacedDigit()
    static let metricS = Font.system(size: 15, weight: .medium).monospacedDigit()
    static let body    = Font.system(size: 12, weight: .regular)
    static let mono    = Font.system(size: 11, design: .monospaced)
    static let axisFnt = Font.system(size: 10, weight: .regular).monospacedDigit()

    // MARK: Spacing — 4pt grid
    static let gutter: CGFloat      = 12
    static let padPanel: CGFloat    = 14
    static let padSection: CGFloat  = 20
    static let laneSlot: CGFloat    = 26
    static let laneDense: CGFloat   = 62
    static let laneRug: CGFloat     = 12
    static let radiusPanel: CGFloat = 10
    static let radiusMark: CGFloat  = 3
    static let markGap: CGFloat     = 2
    static let lineW: CGFloat       = 2
    static let hairW: CGFloat       = 1
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

extension EngineID {
    /// Four categorical hues, and mlx-lm still shares yellow with Ollama. They
    /// never compete for it in practice: hue is earned by residency, and Ollama
    /// on this machine is embeddings-only and holds nothing, so it always
    /// renders muted.
    ///
    /// Jan is the one that could NOT share. It is llama.cpp, like Bionic, and
    /// both hold multi-GB models — so on a machine running both, a shared hue
    /// would put two heavyweight engines under one colour precisely when
    /// telling them apart matters most.
    var hue: Color {
        switch self {
        case .bionic:  return T.engineBionic
        case .localai: return T.engineLocalAI
        case .ollama:  return T.engineOllama
        case .mlxlm:   return T.engineOllama
        case .jan:     return T.engineJan
        }
    }
}

extension ThermalState {
    /// .nominal wears NO hue: "normal" is not good news, it is the absence of news.
    var tint: Color {
        switch self {
        case .nominal:  return T.inkMuted
        case .fair:     return T.warning
        case .serious:  return T.serious
        case .critical: return T.critical
        }
    }
}

extension MemoryPressure {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
    var tint: Color {
        switch self {
        case .nominal: return T.inkMuted
        case .warning: return T.warning
        case .critical: return T.critical
        }
    }
}
