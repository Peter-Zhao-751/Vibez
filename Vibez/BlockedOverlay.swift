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
    let onDismiss: () -> Void

    @State private var appeared = false

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
                    .foregroundStyle(theme.accent)
                    .padding(.bottom, 10)

                Text(titleText)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(theme.fg)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)

                Text(bodyText)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.fgMute)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)

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
