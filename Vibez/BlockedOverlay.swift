//
//  BlockedOverlay.swift
//  Vibez
//
//  Full-screen overlay shown when an agent has pinged the user.
//  Animates in, dismisses on tap. When given a `message` it shows the
//  push text verbatim; otherwise falls back to placeholder copy.
//

import SwiftUI

struct BlockedOverlay: View {
    let theme: Theme
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
    /// When false, the Dismiss button is hidden — the only ways out
    /// of the overlay are replying in Claude/Codex (which sends a
    /// `shield:off` push) or letting the countdown expire. Defaults
    /// to true so previews and any other call sites get the standard
    /// behavior without opting in.
    var allowDismiss: Bool = true
    let onDismiss: () -> Void
    /// Fired exactly once when the countdown reaches 0. Parent is
    /// expected to pop this overlay off the queue.
    let onExpire: () -> Void

    @Environment(\.colorScheme) private var colorScheme
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
        // glance. Fall back to the placeholder only when there's no
        // message at all.
        guard let msg = message else { return "Your agent needs you." }
        return msg.displayTitle
    }

    /// nil hides the body row. The placeholder is for the no-message
    /// preview path only — a real push with an empty body used to fall
    /// into it too, showing fabricated text with a fake timestamp.
    private var bodyText: String? {
        if let msg = message {
            return msg.body.isEmpty ? nil : msg.body
        }
        return "Permission requested · 0:42 ago"
    }

    private var isCodexMessage: Bool {
        message?.agent == .codex
    }

    /// Per-message accent: Codex pings go periwinkle; everything else
    /// (Claude, untagged) keeps the app's Claude orange. Colors the
    /// radial glow + the "BLOCKING IN PROGRESS" eyebrow only.
    private var accentColor: Color {
        isCodexMessage ? Theme.codexBlue : theme.accent
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.bg
                .overlay(
                    RadialGradient(
                        colors: [accentColor.opacity(colorScheme == .dark ? 0.28 : 0.20), .clear],
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
                    Image("codex")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .padding(.bottom, 18)
                } else {
                    ClaudeMascot(listening: true, size: 130)
                        .padding(.bottom, 18)
                }

                Text("BLOCKING IN PROGRESS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(accentColor)
                    .padding(.bottom, 10)

                Text(.init(titleText))
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.fg)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 32)
                    .padding(.bottom, bodyText == nil ? 18 : 8)

                if let bodyText {
                    Text(.init(bodyText))
                        .font(.system(size: 14))
                        .foregroundStyle(theme.fgMute)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 18)
                }

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

                // Trigger-less overlays (untagged pings — no countdown, so
                // no auto-expiry either) always get Dismiss: with the button
                // hidden they'd be stuck until app relaunch. The setting
                // means "make me reply to the agent", and an untagged ping
                // has no agent to reply to. (Design call 2026-06-09.)
                if allowDismiss || expiresAt == nil {
                    Button(action: onDismiss) {
                        Text("Dismiss")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.fgMute)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 28)
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        theme.fgMute.opacity(colorScheme == .dark ? 0.35 : 0.30),
                                        lineWidth: 1.2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

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
        theme: Theme.make(),
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
        theme: Theme.make(),
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
        theme: Theme.make(),
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

#Preview("Codex ping · logo + periwinkle · dark") {
    // Codex pushes ("cx" tag) render the Codex logo + periwinkle accent
    // on this overlay; the rest of the app stays Claude-themed.
    BlockedOverlay(
        theme: Theme.make(),
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

#Preview("No dismiss · forced wait · dark") {
    BlockedOverlay(
        theme: Theme.make(),
        message: previewMessage(
            title: "Ship the Q4 changelog",
            body: "Want me to bundle the design-system entries under a single section, or keep them split out?"
        ),
        expiresAt: Date().addingTimeInterval(11 * 60 + 47),
        stackDepth: 1,
        allowDismiss: false,
        onDismiss: {},
        onExpire: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Untagged ping · no countdown · light") {
    BlockedOverlay(
        theme: Theme.make(),
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
