import SwiftUI
import VibezSessionKit

/// The agent identity chip on every tile — real brand marks, not glyph text.
///
/// Claude: the app-icon look — WHITE rounded square, orange spark. Drawn as a
/// vector (no asterisk asset exists in the repo, and a shape stays crisp at
/// any scale) in the standardized Claude orange #d97757.
/// Codex: the codex logo the iOS app ships (`codex.imageset`), white on the
/// codex-blue square.
/// Cursor: has no mark in this codebase — renders the Claude chip, mirroring
/// the iOS convention where unknown/`cu` agents fall back to the Claude theme.
struct AgentChip: View {
    let agent: AgentTag

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(background)
            mark
        }
        .frame(width: 15, height: 15)
    }

    private var background: Color {
        agent == .codex ? HUDTheme.chip(.codex) : .white
    }

    @ViewBuilder private var mark: some View {
        if agent == .codex {
            if let logo = Self.codexLogo {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 10, height: 10)
            } else {
                // Resource missing (odd bundle layout): the old glyph, never a blank chip.
                Text("◆").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
        } else {
            ClaudeSpark()
                .fill(HUDTheme.chip(.claude))
                .frame(width: 11, height: 11)
        }
    }

    private static let codexLogo: NSImage? = Bundle.module.image(forResource: "codex-logo")
}

/// The Claude spark: ten tapered rays radiating from center, alternating two
/// lengths — an approximation of the Anthropic mark that reads correctly at
/// chip size.
struct ClaudeSpark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let long = min(rect.width, rect.height) / 2
        let short = long * 0.72
        let halfWidth = long * 0.13

        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let len = i.isMultiple(of: 2) ? long : short
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let normal = CGPoint(x: -dir.y, y: dir.x)
            let tip = CGPoint(x: c.x + dir.x * len, y: c.y + dir.y * len)
            // A tapered ray: a thin triangle from a base chord through the
            // center region out to the tip.
            p.move(to: CGPoint(x: c.x + normal.x * halfWidth, y: c.y + normal.y * halfWidth))
            p.addLine(to: CGPoint(x: c.x - normal.x * halfWidth, y: c.y - normal.y * halfWidth))
            p.addLine(to: tip)
            p.closeSubpath()
        }
        return p
    }
}
