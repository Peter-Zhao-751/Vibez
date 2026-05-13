//
//  BlockedOverlay.swift
//  Vibez
//
//  Full-screen overlay shown when an agent has pinged the user.
//  Animates in, dismisses on tap. When given a `message` it shows the
//  ntfy text verbatim; otherwise falls back to agent-themed copy.
//

import SwiftUI

struct BlockedOverlay: View {
    let agent: Agent
    let theme: Theme
    let dark: Bool
    var message: NtfyMessage?
    /// Source of truth for the visible countdown. Reads from
    /// `ScreenTimeManager.pendingTriggers[sid].expiresAt` so the timer
    /// shown to the user is the same clock as the actual shield
    /// lifetime. nil for untagged pings (no backing trigger) — those
    /// render without a countdown and only dismiss via the button.
    var expiresAt: Date?
    /// Total number of overlays in the queue (including this one).
    /// When > 1 a "+N more" pill appears in the corner so the user
    /// understands that dismissing this one will reveal another.
    let stackDepth: Int
    let onDismiss: () -> Void
    /// Fired exactly once when the countdown reaches 0. Parent is
    /// expected to pop this overlay off the queue.
    let onExpire: () -> Void

    @State private var appeared = false
    @State private var fired = false

    private func formatRemaining(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func remainingSeconds(now: Date) -> Int {
        guard let expiresAt else { return 0 }
        return max(0, Int(expiresAt.timeIntervalSince(now)))
    }

    private var titleText: String {
        // displayTitle already prepends the event label ("Done — …",
        // "Needs you — …") so the user sees what Claude wants at a
        // glance. Fall back to the agent-themed placeholder only when
        // there's no message at all.
        guard let msg = message else { return "\(agent.label) needs you." }
        return msg.displayTitle
    }

    private var bodyText: String {
        if let msg = message, !msg.body.isEmpty { return msg.body }
        return "Permission requested · 0:42 ago"
    }

    private var isCodexMessage: Bool {
        message?.agent == .codex
    }

    private var gradientColor: Color {
        isCodexMessage ? Theme.codexBlue : theme.accent
    }

    var body: some View {
        ZStack(alignment: .top) {
            (dark ? Color(hex: 0x0c0d12) : Color(hex: 0xfbf8f4))
                .overlay(
                    RadialGradient(
                        colors: [gradientColor.opacity(dark ? 0.28 : 0.20), .clear],
                        center: UnitPoint(x: 0.5, y: 0.30),
                        startRadius: 0,
                        endRadius: 520
                    )
                )
                .ignoresSafeArea()

            if stackDepth > 1 {
                HStack {
                    Spacer()
                    Text("+\(stackDepth - 1) more")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(theme.fgMute)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(theme.fgMute.opacity(0.10))
                        )
                        .padding(.trailing, 18)
                        .padding(.top, 14)
                }
            }

            VStack(spacing: 0) {
                Spacer().frame(height: 100)

                if isCodexMessage {
                    Image("Codex")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .padding(.bottom, 18)
                } else {
                    MascotForAgent(
                        agent: agent,
                        listening: true,
                        size: agent == .both ? 110 : 130
                    )
                    .padding(.bottom, 18)
                }

                Text("BLOCKING IN PROGRESS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(gradientColor)
                    .padding(.bottom, 10)

                Text(.init(titleText))
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.fg)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)

                Text(.init(bodyText))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.fgMute)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 18)

                if expiresAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = remainingSeconds(now: context.date)
                        Text(formatRemaining(remaining))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.fgMute)
                            .padding(.bottom, 6)
                            .onChange(of: remaining) { _, new in
                                if new == 0 && !fired {
                                    fired = true
                                    onExpire()
                                }
                            }
                    }
                }

//                Button {
//                    onDismiss()
//                } label: {
//                    Text("Open \(agent.label) →")
//                        .font(.system(size: 15, weight: .semibold))
//                        .foregroundStyle(theme.onAccent)
//                        .padding(.horizontal, 28)
//                        .padding(.vertical, 14)
//                        .background(
//                            RoundedRectangle(cornerRadius: 14)
//                                .fill(theme.accent)
//                        )
//                        .shadow(color: theme.accentDeep.opacity(0.55), radius: 14, x: 0, y: 8)
//                }
//                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.fgMute)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .scaleEffect(appeared ? 1 : 0.97)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
    }
}
