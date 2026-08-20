import SwiftUI

/// Hairline-ruled rectangle on a plane. Deliberately NOT GroupBox/Form/List —
/// those read as settings; this reads as instrumentation.
struct Panel<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title { SectionLabel(title) }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing).font(T.mono).foregroundStyle(T.inkMuted)
                    }
                }
            }
            content
        }
        .padding(T.padPanel)
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: T.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: T.radiusPanel, style: .continuous)
                .strokeBorder(T.hairline, lineWidth: T.hairW))
    }
}

/// 11pt uppercase tracked muted caps. This single treatment is most of what
/// makes a panel read as an instrument rather than a form.
struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(T.inkMuted)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(T.hairline).frame(height: T.hairW) }
}

/// 45-degree hatching, used wherever a region is stale, held, or absent.
struct Hatch: Shape {
    var spacing: CGFloat = 5
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = -r.height
        while x < r.width {
            p.move(to: CGPoint(x: r.minX + x, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + x + r.height, y: r.minY))
            x += spacing
        }
        return p
    }
}
