//
//  ShieldCard.swift
//  VibezShield
//
//  Self-contained model + SwiftUI view rendered to UIImage and slotted
//  into ShieldConfiguration.icon. Mirrors BlockedOverlay's aesthetic
//  within the constraints of the Shield Configuration API: no
//  animations, no live countdown, no interactivity. The image is
//  rasterized once per `configuration(shielding:)` call.
//

import SwiftUI
import os

extension Logger {
    static let shieldExt = Logger(subsystem: "vibezlol.Vibez.Shield", category: "Extension")
}

enum Agent: String {
    case claude, codex, both, none
}

struct ShieldState {
    let agent: Agent
    let title: String?
    let body: String?
    let expiresAt: Date?
    let dark: Bool

    /// Reads the latest snapshot from the shared App Group defaults.
    /// Returns nil when state is missing or older than the 24h
    /// cutoff — callers fall back to `ShieldState.fallback`.
    nonisolated static func read() -> ShieldState? {
        let group = UserDefaults(suiteName: "group.vibezlol.Vibez")
        guard let dict = group?.dictionary(forKey: "shieldState"),
              let agentRaw = dict["agent"] as? String,
              let agent = Agent(rawValue: agentRaw),
              let updatedAt = dict["updatedAt"] as? Double
        else {
            Logger.shieldExt.info("ShieldState: missing or malformed; using fallback")
            return nil
        }

        let age = Date().timeIntervalSince1970 - updatedAt
        guard age < 60 * 60 * 24 else {
            Logger.shieldExt.info("ShieldState: stale (\(Int(age))s); using fallback")
            return nil
        }

        return ShieldState(
            agent: agent,
            title: dict["title"] as? String,
            body: dict["body"] as? String,
            expiresAt: (dict["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
            dark: (dict["dark"] as? Bool) ?? true
        )
    }

    nonisolated static let fallback = ShieldState(
        agent: .none,
        title: nil,
        body: nil,
        expiresAt: nil,
        dark: true
    )

    /// Accent color used by ShieldCard and ShieldConfiguration's
    /// primary button. Claude orange / Codex blue / Vibez orange for
    /// the generic case.
    nonisolated var accentUIColor: UIColor {
        ShieldTheme.accentUIColor(agent)
    }
}

import UIKit

/// Frozen render of the Claude/Codex/Both mascot. No TimelineView,
/// no breathing, no eye blinks — the shield card is a still image.
/// Codex case uses the bundled `Codex` asset (added to
/// VibezShield/Assets.xcassets in Task 7).
struct StaticMascot: View {
    let agent: Agent
    var size: CGFloat = 110

    var body: some View {
        switch agent {
        case .codex:
            Image("Codex")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .claude, .both, .none:
            ClaudePixelMascot(size: size)
        }
    }
}

/// Static copy of the Claude pixel critter (mid-blink, mid-breath
/// pose). Path data copied verbatim from Vibez/Mascots.swift around
/// the existing `ClaudeMascot` body, with TimelineView stripped.
struct ClaudePixelMascot: View {
    let size: CGFloat
    // viewBox dimensions match the source SVG.
    private let viewBoxWidth: CGFloat = 64
    private let viewBoxHeight: CGFloat = 64

    var body: some View {
        Canvas { context, canvasSize in
            let unit = canvasSize.width / viewBoxWidth
            // Body (rounded square, accent fill).
            let bodyRect = CGRect(
                x: 8 * unit, y: 14 * unit,
                width: 48 * unit, height: 44 * unit
            )
            context.fill(
                Path(roundedRect: bodyRect, cornerRadius: 10 * unit),
                with: .color(ShieldTheme.accent(.claude))
            )
            // Eyes (two black ovals at neutral position).
            let eyeY = 30 * unit
            for ex in [20.0, 44.0] {
                let eye = CGRect(
                    x: (ex - 4) * unit, y: eyeY - 4 * unit,
                    width: 8 * unit, height: 8 * unit
                )
                context.fill(
                    Path(ellipseIn: eye),
                    with: .color(.black)
                )
            }
            // Mouth (small smile).
            var mouth = Path()
            mouth.move(to: CGPoint(x: 26 * unit, y: 44 * unit))
            mouth.addQuadCurve(
                to: CGPoint(x: 38 * unit, y: 44 * unit),
                control: CGPoint(x: 32 * unit, y: 50 * unit)
            )
            context.stroke(
                mouth,
                with: .color(.black),
                lineWidth: 2 * unit
            )
        }
        .frame(width: size, height: size)
    }
}

private enum ShieldTheme {
    static let bgDark    = Color(red: 0.047, green: 0.051, blue: 0.071)  // #0C0D12
    static let bgLight   = Color(red: 0.984, green: 0.973, blue: 0.957)  // #FBF8F4
    static let fgOnDark  = Color.white
    static let fgOnLight = Color.black
    static let fgMuteOnDark  = Color.white.opacity(0.65)
    static let fgMuteOnLight = Color.black.opacity(0.55)

    static func accent(_ agent: Agent) -> Color {
        switch agent {
        case .codex: return Color(red: 0.29, green: 0.48, blue: 1.00)
        default:     return Color(red: 0.95, green: 0.45, blue: 0.20)
        }
    }

    static func accentUIColor(_ agent: Agent) -> UIColor {
        switch agent {
        case .codex: return UIColor(red: 0.29, green: 0.48, blue: 1.00, alpha: 1.0)
        default:     return UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)
        }
    }
}

struct ShieldCard: View {
    let state: ShieldState

    private var bg: Color    { state.dark ? ShieldTheme.bgDark : ShieldTheme.bgLight }
    private var fg: Color    { state.dark ? ShieldTheme.fgOnDark : ShieldTheme.fgOnLight }
    private var fgMute: Color {
        state.dark ? ShieldTheme.fgMuteOnDark : ShieldTheme.fgMuteOnLight
    }
    private var accent: Color { ShieldTheme.accent(state.agent) }

    private var titleText: String {
        state.title ?? "Stay focused"
    }

    private var bodyText: String {
        state.body ?? "Tap Close to return to your phone. Your agent is waiting."
    }

    var body: some View {
        ZStack(alignment: .top) {
            bg
                .overlay(
                    RadialGradient(
                        colors: [accent.opacity(state.dark ? 0.28 : 0.20), .clear],
                        center: UnitPoint(x: 0.5, y: 0.30),
                        startRadius: 0,
                        endRadius: 320
                    )
                )

            VStack(spacing: 0) {
                Spacer().frame(height: 56)

                StaticMascot(agent: state.agent, size: 110)
                    .padding(.bottom, 18)

                Text("BLOCKING IN PROGRESS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(accent)
                    .padding(.bottom, 10)

                Text(titleText)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(fg)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)

                Text(bodyText)
                    .font(.system(size: 13))
                    .foregroundStyle(fgMute)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .padding(.horizontal, 32)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 360, height: 540)
    }
}

#Preview("Claude · needs input") {
    ShieldCard(state: ShieldState(
        agent: .claude,
        title: "Needs you — Plan plugin distribution",
        body: "Should I bump the minor version before publishing, or roll the patch and ship a follow-up?",
        expiresAt: nil,
        dark: true
    ))
}

#Preview("Codex · light") {
    ShieldCard(state: ShieldState(
        agent: .codex,
        title: "Wire up SSE handler",
        body: "Need confirmation before I rip out the polling fallback.",
        expiresAt: nil,
        dark: false
    ))
}

#Preview("Fallback") {
    ShieldCard(state: .fallback)
}
