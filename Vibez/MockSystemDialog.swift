//
//  MockSystemDialog.swift
//  Vibez
//
//  A practice-tap replica of the iOS system permission alert. The
//  confirm button is live: tapping it fires the REAL system prompt
//  (onConfirm), which appears in the same screen region — the user
//  rehearses the exact motion they're about to repeat. Tapping the
//  mock's "Don't Allow" never proceeds; it wiggles the dialog and
//  surfaces a one-line reason the permission matters.
//
//  Visuals deliberately copy the system alert (270pt width, SF sizes,
//  hairline separators, system-blue buttons) instead of the app theme,
//  so the rehearsal matches what iOS is about to show. Dialog copy is
//  duplicated from the live dialogs — re-verify on a real device when
//  bumping the iOS target.
//

import SwiftUI

struct MockSystemDialog: View {
    let title: String
    let message: String
    let cancelLabel: String
    let confirmLabel: String
    /// Shown under the dialog after a "Don't Allow" tap.
    let denyHint: String
    let onConfirm: () -> Void

    @State private var denyShake = 0
    @State private var showDenyHint = false
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 14) {
            alertCard
                .shake(trigger: denyShake, amount: 5, duration: 0.5)

            // Always-rendered hint row (opacity-only show) so the
            // dialog doesn't jump when the hint appears.
            Text(denyHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .opacity(showDenyHint ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: showDenyHint)
                .accessibilityHidden(!showDenyHint)
        }
    }

    private var alertCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 19)

            Divider()

            HStack(spacing: 0) {
                Button {
                    denyShake &+= 1
                    showDenyHint = true
                } label: {
                    Text(cancelLabel)
                        .font(.system(size: 17))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }

                Divider()
                    .frame(height: 44)

                Button(action: onConfirm) {
                    Text(confirmLabel)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .overlay(pulseRing)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(uiColor: .systemBlue))
        }
        .frame(width: 270)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    /// Soft repeating pulse around the confirm button — the "tap me"
    /// affordance from the approved design (option A).
    private var pulseRing: some View {
        RoundedRectangle(cornerRadius: 9)
            .stroke(
                Color(uiColor: .systemBlue).opacity(pulsing ? 0 : 0.55),
                lineWidth: 2
            )
            .padding(5)
            .scaleEffect(pulsing ? 1.1 : 0.96)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.6).repeatForever(autoreverses: false)
                ) {
                    pulsing = true
                }
            }
            .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("Mock notification dialog") {
    ZStack {
        Color.black.ignoresSafeArea()
        MockSystemDialog(
            title: "“Vibez” Would Like to Send You Notifications",
            message: "Notifications may include alerts, sounds, and icon badges. These can be configured in Settings.",
            cancelLabel: "Don’t Allow",
            confirmLabel: "Allow",
            denyHint: "You’ll want Allow — without it, Vibez can’t ping you when your agent needs you.",
            onConfirm: {}
        )
    }
    .preferredColorScheme(.dark)
}
#endif
