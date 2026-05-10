//
//  Components.swift
//  Vibez
//
//  Building blocks for the main screen: WARP-style pill toggle, top bar,
//  blocked-app card, recent-trigger row.
//

import SwiftUI
import UIKit

// MARK: - BlockerKnob (waveform inside the pill toggle)
//
// ON  → silent: a single flat baseline.
// OFF → noisy: three vertical bars rising and falling at different
//       periods, like an audio meter being "chaotic" because nothing's
//       blocking the doom-scroll yet.

struct BlockerKnob: View {
    let listening: Bool
    let size: CGFloat
    let stroke: Color

    var body: some View {
        if listening {
            silentBaseline
        } else {
            chaoticBars
        }
    }

    private var silentBaseline: some View {
        Canvas { ctx, sz in
            var path = Path()
            path.move(to: CGPoint(x: sz.width * 0.22, y: sz.height * 0.5))
            path.addLine(to: CGPoint(x: sz.width * 0.78, y: sz.height * 0.5))
            ctx.stroke(
                path,
                with: .color(stroke),
                style: StrokeStyle(lineWidth: sz.width * 0.04, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }

    private var chaoticBars: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, sz in
                let t = context.date.timeIntervalSinceReferenceDate
                let lineWidth = sz.width * 0.05
                // Three bars, each at a different x and oscillating with
                // a different period so they look uncorrelated.
                let bars: [(cx: CGFloat, period: Double, phase: Double, amp: CGFloat)] = [
                    (cx: 0.30, period: 1.4, phase: 0.0, amp: 0.20),
                    (cx: 0.50, period: 1.6, phase: 0.7, amp: 0.28),
                    (cx: 0.70, period: 1.2, phase: 1.4, amp: 0.18),
                ]
                for bar in bars {
                    let p = (t / bar.period + bar.phase) * 2 * .pi
                    // |sin| keeps the amplitude in [0, 1]; scaling by
                    // 0.5 + 0.5*|sin| makes the minimum a non-zero
                    // resting amplitude so the bar never collapses.
                    let amp = bar.amp * sz.height * (0.5 + 0.5 * abs(sin(p)))
                    let x = bar.cx * sz.width
                    let mid = sz.height * 0.5
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: mid - amp))
                    path.addLine(to: CGPoint(x: x, y: mid + amp))
                    ctx.stroke(
                        path,
                        with: .color(stroke),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Big WARP-style toggle

struct BigToggle: View {
    @Binding var enabled: Bool
    let agent: Agent
    let theme: Theme

    private let pillW: CGFloat = 250
    private let pillH: CGFloat = 132
    private let knobSize: CGFloat = 116

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                enabled.toggle()
            }
            if (!enabled){
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }else{
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        } label: {
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(enabled ? AnyShapeStyle(theme.pillGradient) : AnyShapeStyle(theme.pillOff))
                    .overlay(
                        // Inner shadow when off, soft top highlight when on.
                        Capsule()
                            .stroke(.white.opacity(enabled ? 0.18 : 0), lineWidth: 1)
                            .blendMode(.overlay)
                    )
                    .shadow(color: enabled ? theme.accentDeep.opacity(0.55) : .clear,
                            radius: enabled ? 18 : 0, x: 0, y: 12)
                    .frame(width: pillW, height: pillH)

                // OFF / ON labels
                ZStack {
                    Text("OFF")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(enabled ? .clear : theme.fgFaint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 30)
                    Text("ON")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(enabled ? .white.opacity(0.9) : .clear)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 30)
                }
                .frame(width: pillW, height: pillH)

                // Knob (sliding circle with waveform inside)
                Circle()
                    .fill(theme.knobBg)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 6)
                    .overlay(
                        Circle().stroke(.black.opacity(0.04), lineWidth: 1)
                    )
                    .overlay(
                        BlockerKnob(
                            listening: enabled,
                            size: 92,
                            stroke: theme.fg
                        )
                    )
                    .padding(.leading, knobX)
            }
            .frame(width: pillW, height: pillH)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(enabled ? "Disable Vibez" : "Enable Vibez")
    }

    private var knobX: CGFloat {
        enabled ? (pillW - knobSize - 8) : 8
    }
}

// MARK: - Wordmark
//
// Italic "vibe" + a chunky pixel-art "Z" tinted with the agent accent.
// The Z is a 6×6 grid of 10×10 cells in a 60×56 viewBox: top row of
// six cells, a four-step diagonal, bottom row of six cells.

struct VibezWordmark: View {
    let theme: Theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text("vibe")
                .font(.system(size: 44, weight: .black))
                .italic()
                .tracking(-2.2)
                .foregroundStyle(theme.fg)
                .padding(.trailing, -10) // pull the Z slightly into the 'e'
            PixelZShape()
                .fill(theme.accent)
                .frame(width: 32, height: 30)
                .padding(.bottom, 6) // sit on the same baseline as 'vibe'
        }
        .fixedSize() // don't let Spacer in TopBar squash it
    }
}

private struct PixelZShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sx = rect.width / 60
        let sy = rect.height / 56
        let cells: [(CGFloat, CGFloat)] = [
            // top bar
            (0, 0), (10, 0), (20, 0), (30, 0), (40, 0), (50, 0),
            // diagonal stroke
            (40, 10), (30, 20), (20, 30), (10, 40),
            // bottom bar
            (0, 46), (10, 46), (20, 46), (30, 46), (40, 46), (50, 46),
        ]
        for (x, y) in cells {
            p.addRect(CGRect(x: x * sx, y: y * sy, width: 10 * sx, height: 10 * sy))
        }
        return p
    }
}

// MARK: - Top bar

struct TopBar: View {
    let isDark: Bool
    let theme: Theme
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VibezWordmark(theme: theme)
            Spacer()
            ChipIconButton(
                systemName: "gearshape",
                theme: theme,
                accessibilityLabel: "Open settings",
                action: onOpenSettings
            )
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

struct ChipIconButton: View {
    let systemName: String
    let theme: Theme
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.fg)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.bgChip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let listening: Bool
    let theme: Theme

    var body: some View {
        Text(listening ? "● LISTENING" : "○ STANDBY")
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .tracking(2.4)
            .foregroundStyle(listening ? theme.accent : theme.fgFaint)
    }
}

// MARK: - Blocking apps panel

struct BlockedAppCard: View {
    let app: BlockedApp
    let enabled: Bool
    let theme: Theme

    var body: some View {
        VStack(spacing: 4) {
            Text(app.glyph)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(theme.fgMute.opacity(enabled ? 0.55 : 1))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.bgChip)
                )
            Text(app.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? theme.accent : theme.fgMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(enabled ? theme.accent.opacity(0.08) : theme.bgChip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(enabled ? theme.accent.opacity(0.2) : theme.hairline, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.3), value: enabled)
    }
}

struct BlockedApp: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let glyph: String

    static let demoSet: [BlockedApp] = [
        .init(name: "Instagram", glyph: "IG"),
        .init(name: "TikTok", glyph: "TT"),
        .init(name: "X", glyph: "X"),
        .init(name: "YouTube", glyph: "YT"),
    ]
}

struct BlockingPanel: View {
    let apps: [BlockedApp]
    let enabled: Bool
    let theme: Theme

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Blocking")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.fg)
                Spacer()
                Text("\(apps.count) apps")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fgMute)
            }
            HStack(spacing: 8) {
                ForEach(apps) { app in
                    BlockedAppCard(app: app, enabled: enabled, theme: theme)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Recent triggers

struct TriggerEvent: Identifiable {
    enum Source { case claude, codex }
    let id = UUID()
    let time: String
    let source: Source
    let label: String
    let duration: String

    static let demoSet: [TriggerEvent] = [
        .init(time: "2m ago",  source: .claude, label: "Claude Code asked for bash permission", duration: "4m 12s"),
        .init(time: "18m ago", source: .codex,  label: "Codex finished running tests",          duration: "1m 30s"),
        .init(time: "47m ago", source: .claude, label: "Claude paused — manual intervention",   duration: "6m 04s"),
    ]
}

struct TriggerRow: View {
    let event: TriggerEvent
    let theme: Theme

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(event.source == .codex ? Theme.codexBlue : Theme.claudeOrange)
                Text(event.source == .codex ? "cx" : "cc")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(event.time) · blocked \(event.duration)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.fgMute)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.hairline, lineWidth: 1)
        )
    }
}

struct RecentTriggersSection: View {
    let events: [TriggerEvent]
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent triggers")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.fg)
                Spacer()
                Text("today")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fgMute)
            }
            VStack(spacing: 6) {
                ForEach(events) { event in
                    TriggerRow(event: event, theme: theme)
                }
            }
        }
    }
}

// MARK: - Glow

struct AccentGlow: View {
    let theme: Theme
    let dark: Bool

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [theme.accent.opacity(dark ? 0.20 : 0.14), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 320
                )
            )
            .frame(height: 360)
            .offset(y: -120)
            .allowsHitTesting(false)
    }
}
