//
//  OnboardingFlow.swift
//  Vibez
//
//  Container for the onboarding pages: forward-only ZStack transitions,
//  progress dots, the Skip affordance, and the scenePhase re-check that
//  catches Settings-app round-trips (remediation paths). Presented as a
//  fullScreenCover by ContentView (launch gate) and SettingsView
//  (Tutorial replay).
//

import SwiftUI

struct OnboardingFlow: View {
    @Bindable var state: OnboardingState
    @Bindable var manager: ScreenTimeManager
    @Bindable var registrar: PushTokenRegistrar
    /// Skip — bail out without finishing (flow returns next launch).
    let onDismiss: () -> Void
    /// Done on the finish page — the only completion exit. ContentView
    /// uses the distinction to arm the big toggle after a real
    /// walkthrough completion (never after a Skip).
    let onFinish: () -> Void

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var theme: Theme { Theme.make() }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()

            if let step = state.current {
                stepView(for: step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            VStack {
                HStack {
                    Spacer()
                    // The finish page's CTA is Done — no Skip needed.
                    if state.current != .finish {
                        Button("Skip for now", action: onDismiss)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.fgMute)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)

                Spacer()

                progressDots
                    .padding(.bottom, 20)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Returning from the Settings app (remediation path): re-read
            // every gate and hop past the current step if it's now met.
            Task {
                await state.refreshNotificationStatus()
                manager.refreshAuthorizationStatus()
                if state.currentStepSatisfied {
                    advance()
                }
            }
        }
        // Live-verify a permission step the moment it becomes current:
        // the step list is a snapshot from begin(), so if the gate read
        // was stale (or the permission was granted outside the flow),
        // re-read it and skip forward instead of asking the user for
        // something they already gave — "Allow notifications" must never
        // show when notifications are already on.
        .task(id: state.current) {
            guard let step = state.current else { return }
            switch step {
            case .notifications: await state.refreshNotificationStatus()
            case .screenTime: manager.refreshAuthorizationStatus()
            case .welcome, .pluginInstall, .vibezId, .finish: return
            }
            // Re-check the step is still current (a concurrent scenePhase
            // recheck may have advanced past it already) before skipping.
            if state.current == step, state.currentStepSatisfied {
                advance()
            }
        }
        .preferredColorScheme(
            (AppearancePref(rawValue: appearanceRaw) ?? .system).colorScheme
        )
    }

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(theme: theme, onContinue: advance)
        case .notifications:
            OnboardingNotificationsStep(theme: theme, state: state, onAdvance: advanceAfterPermissionGrant)
        case .screenTime:
            OnboardingScreenTimeStep(theme: theme, manager: manager, onAdvance: advanceAfterPermissionGrant)
        case .pluginInstall:
            OnboardingPluginStep(theme: theme, onAdvance: advance)
        case .vibezId:
            OnboardingVibezIdStep(theme: theme, registrar: registrar, onAdvance: advance)
        case .finish:
            OnboardingFinishStep(theme: theme, onDone: onFinish)
        }
    }

    private func advance() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            state.advance()
        }
    }

    /// Grant-driven advance for the permission steps. Idempotent so it
    /// can't compound with the scenePhase / `.task` recheck into a
    /// double hop that skips the plugin-install page — see
    /// OnboardingState.advanceIfCurrentStepSatisfied().
    private func advanceAfterPermissionGrant() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            state.advanceIfCurrentStepSatisfied()
        }
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(Array(state.steps.enumerated()), id: \.offset) { i, _ in
                Capsule()
                    .fill(i == state.index ? theme.accent : theme.bgChip)
                    .frame(width: i == state.index ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.index)
    }
}

#if DEBUG
#Preview("Full flow · dark") {
    OnboardingFlow(
        state: .previewState(),
        manager: ScreenTimeManager.previewManager(armed: false, authState: .notDetermined),
        registrar: PushTokenRegistrar.previewRegistrar(vibezId: "", state: .idle),
        onDismiss: {},
        onFinish: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Tutorial replay (all set up)") {
    OnboardingFlow(
        state: .previewState(steps: [.finish]),
        manager: ScreenTimeManager.previewManager(armed: true),
        registrar: PushTokenRegistrar.previewRegistrar(),
        onDismiss: {},
        onFinish: {}
    )
    .preferredColorScheme(.dark)
}
#endif
