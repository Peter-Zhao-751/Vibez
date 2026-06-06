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
//  state update.
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

// MARK: - SwiftUI

private enum ShieldCardTheme {
    static let bgDark    = Color(red: 0.047, green: 0.051, blue: 0.071)
    static let bgLight   = Color(red: 0.984, green: 0.973, blue: 0.957)
    static let fgOnDark  = Color.white
    static let fgOnLight = Color.black
    static let fgMuteOnDark  = Color.white.opacity(0.65)
    static let fgMuteOnLight = Color.black.opacity(0.55)

    /// Per-agent accent: vivid blue behind the Codex logo, Claude
    /// orange for everything else (claude/both/none).
    static func accent(_ agent: ShieldState.Agent) -> Color {
        switch agent {
        case .codex: Color(red: 0.29, green: 0.48, blue: 1.00)
        default:     Color(red: 0.95, green: 0.45, blue: 0.20)
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

/// Codex renders the logo asset; everything else renders the Claude
/// pixel critter. Mirrors BlockedOverlay's per-message mascot pick.
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
            ShieldCardClaudePixel(size: size)
        }
    }
}

/// Static, frame-accurate copy of `Vibez/Mascots.swift`'s `ClaudeMascot`
/// in the neutral "open eyes" pose. Geometry copied verbatim from
/// `ClaudeBodyShape.path(in:)` and `ClaudeEyes.eye(at:scale:)` — same
/// 100×90 viewBox, same rectangular body parts (main body, two side
/// wings, four feet) and rectangular eyes. The shadow band and
/// breathing animation are intentionally dropped for the still icon.
private struct ShieldCardClaudePixel: View {
    let size: CGFloat
    private static let eyeColor = Color(red: 0.102, green: 0.055, blue: 0.031)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ClaudeBodyShape()
                .fill(ShieldCardTheme.accent(.claude))
            ClaudeEyesShape()
                .fill(Self.eyeColor)
        }
        .frame(width: size, height: size * 0.9)
    }
}

private struct ClaudeEyesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 100
        var p = Path()
        // Two rectangular eyes in the open/neutral pose
        p.addRect(CGRect(x: 22 * s, y: 28 * s, width: 12 * s, height: 14 * s))
        p.addRect(CGRect(x: 66 * s, y: 28 * s, width: 12 * s, height: 14 * s))
        return p
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
