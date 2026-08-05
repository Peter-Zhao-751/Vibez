import SwiftUI
import VibezSessionKit

/// The agent identity chip on every tile — the SAME art the iOS app uses,
/// on a white plate:
///
/// - Claude: the Clawd resting sprite (the "little crab"), an exact port of
///   `ClawdRestingSprite` from `Vibez/ShieldCardRenderer.swift` — same cell,
///   same critter crop, same drawn-on eye boxes, nearest-neighbor scaling.
/// - Codex: `assets/agents/Codex.png` (the blue pixel-Z art).
/// - Cursor: `assets/agents/Cursor.png` (yes, it exists — assets/agents/).
///
/// All three ship as transparent-background art, so every chip sits on the
/// same white rounded plate.
struct AgentChip: View {
    let agent: AgentTag

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.white)
            mark
        }
        .frame(width: 15, height: 15)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private var mark: some View {
        switch agent {
        case .claude:
            ClawdChip(critterWidth: 13)
        case .codex:
            brandImage(Self.codexArt, fallbackGlyph: "◆", fallbackColor: HUDTheme.chip(.codex))
        case .cursor:
            brandImage(Self.cursorArt, fallbackGlyph: "▲", fallbackColor: HUDTheme.chip(.cursor))
        }
    }

    @ViewBuilder
    private func brandImage(_ image: NSImage?, fallbackGlyph: String, fallbackColor: Color) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable().scaledToFit()
                .frame(width: 12, height: 12)
        } else {
            // Resource missing (odd bundle layout): the old glyph, never a blank chip.
            Text(fallbackGlyph).font(.system(size: 8, weight: .bold)).foregroundStyle(fallbackColor)
        }
    }

    private static let codexArt: NSImage? = Bundle.module.image(forResource: "agent-codex")
    private static let cursorArt: NSImage? = Bundle.module.image(forResource: "agent-cursor")
}

/// Chip-sized Clawd: the real `clawd-resting` frame with the open-pose eyes
/// drawn on top, cropped to the critter's opaque box — constants copied
/// verbatim from `ClawdRestingSprite` (Vibez/ShieldCardRenderer.swift), which
/// is the single source of truth for this pose. Keep them in sync.
struct ClawdChip: View {
    var critterWidth: CGFloat = 11

    private static let cell = CGSize(width: 330, height: 226)
    private static let critterBox = CGRect(x: 88, y: 128, width: 144, height: 96)
    private static let eyeBoxes = [
        CGRect(x: 124, y: 140, width: 12, height: 12),
        CGRect(x: 184, y: 140, width: 12, height: 12),
    ]

    private static let sprite: NSImage? = Bundle.module.image(forResource: "clawd-resting")

    var body: some View {
        if let sprite = Self.sprite {
            let k = critterWidth / Self.critterBox.width
            ZStack(alignment: .topLeading) {
                Image(nsImage: sprite)
                    .resizable()
                    .interpolation(.none)     // nearest-neighbor keeps the pixel art crisp
                    .frame(width: Self.cell.width * k, height: Self.cell.height * k)
                ForEach(0..<Self.eyeBoxes.count, id: \.self) { i in
                    let box = Self.eyeBoxes[i]
                    Rectangle()
                        .fill(.black)
                        .frame(width: box.width * k, height: box.height * k)
                        .offset(x: box.minX * k, y: box.minY * k)
                }
            }
            .frame(width: Self.cell.width * k, height: Self.cell.height * k, alignment: .topLeading)
            .offset(x: -Self.critterBox.minX * k, y: -Self.critterBox.minY * k)
            .frame(width: Self.critterBox.width * k, height: Self.critterBox.height * k,
                   alignment: .topLeading)
            .clipped()
        } else {
            Text("✳").font(.system(size: 8, weight: .bold))
                .foregroundStyle(HUDTheme.chip(.claude))
        }
    }
}
