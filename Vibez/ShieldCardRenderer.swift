//
//  ShieldCardRenderer.swift
//  Vibez
//
//  Renders the shield card to a UIImage on the host side and saves
//  the PNG into the App Group container. The extension just loads
//  the cached PNG and slots it into ShieldConfiguration.icon — no
//  ImageRenderer or MainActor work in the extension, which sidesteps
//  the assumeIsolated trap we hit in the previous attempt.
//
//  Visual mirrors BlockedOverlay within ShieldConfiguration's fixed
//  layout: mascot + "BLOCKING IN PROGRESS" eyebrow + title + body.
//  No animations, no countdown — the icon is rasterized once per
//  state update. The Claude card draws the real Clawd sprite (the
//  resting frame, same art as the home screen) since 2026-06-09.
//

import SwiftUI
import UIKit

@MainActor
func renderShieldCardPNG(state: ShieldState) -> Data? {
    let renderer = ImageRenderer(content: ShieldCardView(state: state))
    renderer.scale = UIScreen.main.scale
    renderer.proposedSize = ProposedViewSize(width: 400, height: 400)
    return renderer.uiImage?.pngData()
}

/// Rasterizes a catalog asset for the Codex communication-notification
/// avatar. Forces the light-appearance variant: the rendered PNG is a
/// fixed image (it can't adapt when the system flips appearance), and
/// the periwinkle-tile variant of the blue pixel-Z reads as "blue" on
/// both light and dark banner material.
///
/// iOS masks every comm-notification avatar to a CIRCLE with no square
/// option, so the tile is drawn INSCRIBED in that circle on a
/// transparent canvas — the mask has nothing to clip and the visible
/// shape stays a rounded square, like a regular app icon. Side 280 in
/// a 400 canvas (half-diagonal 198 < radius 200) keeps the corners
/// inside the mask, and 280 = 2.8× the SVG's 100-unit grid keeps the
/// pixel-art edges on exact pixel boundaries.
@MainActor
func renderNotificationIconPNG(assetName: String) -> Data? {
    let traits = UITraitCollection(userInterfaceStyle: .light)
    guard let image = UIImage(named: assetName, in: nil, compatibleWith: traits)
    else { return nil }
    let size = CGSize(width: 400, height: 400)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format)
        .image { _ in
            image.draw(in: CGRect(x: 60, y: 60, width: 280, height: 280))
        }
        .pngData()
}

// MARK: - SwiftUI

private enum ShieldCardTheme {
    static let bgDark    = Color(red: 0.047, green: 0.051, blue: 0.071)
    static let bgLight   = Color(red: 0.984, green: 0.973, blue: 0.957)
    static let fgOnDark  = Color.white
    static let fgOnLight = Color.black
    static let fgMuteOnDark  = Color.white.opacity(0.65)
    static let fgMuteOnLight = Color.black.opacity(0.55)

    /// Per-agent accent: vivid blue behind the Codex logo, the official
    /// Claude orange (#d97757 — the Clawd sprite body color, same as
    /// Theme.claudeOrange) for everything else (claude/both/none).
    static func accent(_ agent: ShieldState.Agent) -> Color {
        switch agent {
        case .codex: Color(red: 0.29, green: 0.48, blue: 1.00)
        default:     Color(red: 0.851, green: 0.467, blue: 0.341)
        }
    }
}

/// Square image carrying just the mascot — iOS renders it as the
/// `ShieldConfiguration.icon`, which is a small slot (~100pt) in the
/// system's layout. Title and body text live in the surrounding
/// `title` / `subtitle` slots that iOS lays out itself.
private struct ShieldCardView: View {
    let state: ShieldState

    private var accent: Color { ShieldCardTheme.accent(state.agent) }

    var body: some View {
        ZStack {
            // Soft circular accent glow behind the mascot — gives the
            // icon a deliberate "branded" feel even at small sizes.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.28), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )

            ShieldCardMascot(agent: state.agent, size: 280)
        }
        .frame(width: 400, height: 400)
    }
}

/// Codex renders the logo asset; everything else renders Clawd, the
/// sprite critter. Mirrors BlockedOverlay's per-message mascot pick.
private struct ShieldCardMascot: View {
    let agent: ShieldState.Agent
    var size: CGFloat = 110

    var body: some View {
        switch agent {
        case .codex:
            Image("codex")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .claude, .both, .none:
            // The sprite critter is wide and low (3:2), unlike the square
            // Codex logo; drawing it slightly wider than the square slot
            // (280 → 300) keeps its visual weight matched to the glow.
            ClawdRestingSprite(critterWidth: size * 15 / 14)
        }
    }
}

/// The resting-sprite Clawd — the real `clawd-resting` frame (the same
/// eyeless art the home hero plays through ClawdTheater) with the
/// open-pose eyes drawn on top, cropped to the critter's opaque box.
/// Shared by the shield card (host-side rasterization, below) and the
/// recent-trigger badge (Components.swift's StaticClaudeBadgeMascot) —
/// both render the new sprite, so the old hand-traced ClaudeBodyShape
/// vector is gone everywhere (2026-06-09).
struct ClawdRestingSprite: View {
    /// Width the critter itself (not the padded sprite cell) renders at.
    var critterWidth: CGFloat = 300

    /// clawd-resting cell geometry (see SpriteSheetView.swift) and the
    /// critter's opaque bounding box, measured from the asset.
    private static let cell = CGSize(width: 330, height: 226)
    private static let critterBox = CGRect(x: 88, y: 128, width: 144, height: 96)
    /// Open-pose eyes in cell coordinates — mirrors ClawdTheater's
    /// eyeBoxes (the resting art ships eyeless; expressions draw on top).
    private static let eyeBoxes = [
        CGRect(x: 124, y: 140, width: 12, height: 12),
        CGRect(x: 184, y: 140, width: 12, height: 12),
    ]

    var body: some View {
        let k = critterWidth / Self.critterBox.width
        ZStack(alignment: .topLeading) {
            Image("clawd-resting")
                .resizable()
                .interpolation(.none) // nearest-neighbor keeps the pixel art crisp
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
        // Crop the padded cell down to the critter: shift the cell so the
        // critter's box lands at the origin, window to the box, clip.
        .offset(x: -Self.critterBox.minX * k, y: -Self.critterBox.minY * k)
        .frame(width: Self.critterBox.width * k, height: Self.critterBox.height * k, alignment: .topLeading)
        .clipped()
    }
}

#Preview("Claude · needs input") {
    ShieldCardView(state: ShieldState(
        agent: .claude,
        title: "Needs you — Plan plugin distribution",
        body: "Should I bump the minor version before publishing, or roll the patch and ship a follow-up?",
        expiresAt: nil,
        dark: true
    ))
}

#Preview("Codex · light") {
    ShieldCardView(state: ShieldState(
        agent: .codex,
        title: "Wire up SSE handler",
        body: "Need confirmation before I rip out the polling fallback.",
        expiresAt: nil,
        dark: false
    ))
}
