//
//  MockSystemDialog.swift
//  Vibez
//
//  A practice-tap replica of the iOS system permission alert. The
//  confirm button is live: tapping it fires the REAL system prompt
//  (onConfirm), which appears in the same screen region — the user
//  rehearses the exact motion they're about to repeat. Tapping any
//  other button never proceeds; it wiggles the dialog and surfaces a
//  one-line reason the permission matters.
//
//  Visuals deliberately copy the iOS 26 system alert (left-aligned
//  title/body, side-by-side capsule buttons, ~306pt card) instead of
//  the app theme, so the rehearsal matches what iOS is about to show.
//  Button ORDER and prominence are per-dialog — notifications puts
//  Allow right; Screen Time puts Continue LEFT with a prominent blue
//  Don't Allow on the right (verified against the live iOS 26.4
//  dialogs in the simulator on 2026-06-04; re-verify when bumping the
//  iOS target).
//

import SwiftUI

struct MockSystemDialog: View {
    struct DialogButton {
        let label: String
        /// Blue-filled capsule (iOS 26 "prominent" style).
        var prominent = false
        /// The practice-tap target: pulses, and fires onConfirm.
        var isConfirm = false
    }

    let title: String
    let message: String
    /// Rendered left-to-right, matching the real dialog's order.
    let buttons: [DialogButton]
    /// Shown under the dialog after tapping a non-confirm button.
    let denyHint: String
    let onConfirm: () -> Void

    @State private var denyShake = 0
    @State private var showDenyHint = false

    var body: some View {
        VStack(spacing: 14) {
            alertCard
                .shake(trigger: denyShake, amount: 5, duration: 0.5)

            // Deny hint sits below the card; see offset note at the
            // bottom of this view — the whole stack rides together.

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
        // The real iOS alert centers slightly higher than this page's
        // content zone (the headline block pushes the zone's midpoint
        // down). Lift the replica so the real prompt lands ON it —
        // measured against the live dialog on the 26.4 sim.
        .offset(y: -30)
    }

    private var alertCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    buttonView(button)
                }
            }
            .padding(.top, 16)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 316)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
    }

    @ViewBuilder
    private func buttonView(_ button: DialogButton) -> some View {
        Button {
            if button.isConfirm {
                onConfirm()
            } else {
                denyShake &+= 1
                showDenyHint = true
            }
        } label: {
            Text(button.label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    button.prominent ? Color.white : Color.primary
                )
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    Capsule().fill(
                        button.prominent
                            ? Color(uiColor: .systemBlue)
                            : Color.primary.opacity(0.06)
                    )
                )
                .overlay {
                    if button.isConfirm {
                        pulseRing
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Soft repeating pulse around the confirm button — the "tap me"
    /// affordance from the approved design (option A). Driven by
    /// TimelineView, NOT a repeatForever withAnimation: the previous
    /// version animated layout (padding) forever, which kept the
    /// button's subtree perpetually re-laying-out — UIKit swallowed
    /// real touches on the moving control until an unrelated state
    /// change (the deny shake) interrupted the animation, so Continue
    /// only "started working" after a Don't Allow tap. A timeline
    /// redraw is pure drawing: no transactions to leak, no layout to
    /// animate, and the shape inset expands uniformly on every side.
    private var pulseRing: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6
            let eased = 1 - pow(1 - phase, 2)   // easeOut
            Capsule()
                .inset(by: CGFloat(-1 - 7 * eased))
                .stroke(
                    Color(uiColor: .systemBlue).opacity(0.55 * (1 - eased)),
                    lineWidth: 2
                )
        }
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("Notifications dialog") {
    ZStack {
        Color.black.ignoresSafeArea()
        MockSystemDialog(
            title: "“Vibez” Would Like to Send You Notifications",
            message: "Notifications may include alerts, sounds, and icon badges. These can be configured in Settings.",
            buttons: [
                .init(label: "Don’t Allow"),
                .init(label: "Allow", isConfirm: true),
            ],
            denyHint: "You’ll want Allow — without it, Vibez can’t ping you when your agent needs you.",
            onConfirm: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Screen Time dialog") {
    ZStack {
        Color.black.ignoresSafeArea()
        MockSystemDialog(
            title: "“Vibez” Would Like to Access Screen Time",
            message: "Providing “Vibez” access to Screen Time may allow it to see your activity data, restrict content, and limit the usage of apps and websites.",
            buttons: [
                .init(label: "Continue", isConfirm: true),
                .init(label: "Don’t Allow", prominent: true),
            ],
            denyHint: "You’ll want Continue — Screen Time access is the mechanism that blocks your distracting apps.",
            onConfirm: {}
        )
    }
    .preferredColorScheme(.dark)
}
#endif
