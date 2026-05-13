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
                            .font(.system(size: 38, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.fg)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.easeInOut(duration: 0.18), value: remaining)
                            .padding(.bottom, 16)
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.fgMute)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 28)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    theme.fgMute.opacity(dark ? 0.35 : 0.30),
                                    lineWidth: 1.2
                                )
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Previews

private func previewMessage(
    title: String = "Plan plugin distribution",
    body: String = "Should I bump the minor version before publishing, or roll the patch and ship a follow-up?",
    event: VibezEvent? = .needsInput,
    agent: VibezAgent? = .claude,
    sessionId: String? = "preview-session"
) -> NtfyMessage {
    var msg = NtfyMessage(
        id: UUID().uuidString,
        title: title,
        body: body,
        receivedAt: Date()
    )
    msg.event = event
    msg.agent = agent
    msg.sessionId = sessionId
    msg.shield = .on
    return msg
}

#Preview("Needs input · 14:32 · dark") {
    BlockedOverlay(
        agent: .claude,
        theme: Theme.make(agent: .claude, dark: true),
        dark: true,
        message: previewMessage(),
        expiresAt: Date().addingTimeInterval(14 * 60 + 32),
        stackDepth: 1,
        onDismiss: {},
        onExpire: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Done · 28s · light") {
    BlockedOverlay(
        agent: .claude,
        theme: Theme.make(agent: .claude, dark: false),
        dark: false,
        message: previewMessage(
            title: "Refactor blocking panel",
            body: "Wrapped the panel in a lazy stack and trimmed the unused gradient. Tests pass.",
            event: .done
        ),
        expiresAt: Date().addingTimeInterval(28),
        stackDepth: 1,
        onDismiss: {},
        onExpire: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Stack of 3 · dark") {
    BlockedOverlay(
        agent: .claude,
        theme: Theme.make(agent: .claude, dark: true),
        dark: true,
        message: previewMessage(
            title: "Investigate WebSocket disconnects",
            body: "Reconnect logic is dropping the second frame on iOS 17 — want me to add a retry guard?"
        ),
        expiresAt: Date().addingTimeInterval(9 * 60 + 4),
        stackDepth: 3,
        onDismiss: {},
        onExpire: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Codex · needs input · dark") {
    BlockedOverlay(
        agent: .codex,
        theme: Theme.make(agent: .codex, dark: true),
        dark: true,
        message: previewMessage(
            title: "Wire up SSE handler",
            body: "Need confirmation before I rip out the polling fallback.",
            agent: .codex
        ),
        expiresAt: Date().addingTimeInterval(7 * 60 + 12),
        stackDepth: 2,
        onDismiss: {},
        onExpire: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Untagged ping · no countdown · light") {
    BlockedOverlay(
        agent: .claude,
        theme: Theme.make(agent: .claude, dark: false),
        dark: false,
        message: previewMessage(
            title: "Vibez",
            body: "Test push from a curl ping — no Vibez control tags.",
            event: nil,
            agent: nil,
            sessionId: nil
        ),
        expiresAt: nil,
        stackDepth: 1,
        onDismiss: {},
        onExpire: {}
    )
    .preferredColorScheme(.light)
}
