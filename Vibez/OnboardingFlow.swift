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
    let onDismiss: () -> Void

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.agent") private var agentRaw = Agent.claude.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private var agent: Agent { Agent(rawValue: agentRaw) ?? .claude }
    private var theme: Theme { Theme.make(agent: agent) }

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
        .animation(.easeInOut(duration: 0.4), value: agent)
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
        .preferredColorScheme(
            (AppearancePref(rawValue: appearanceRaw) ?? .system).colorScheme
        )
    }

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(theme: theme, agent: agent, onContinue: advance)
        case .notifications:
            OnboardingNotificationsStep(theme: theme, state: state, onAdvance: advance)
        case .screenTime:
            OnboardingScreenTimeStep(theme: theme, manager: manager, onAdvance: advance)
        case .agentPick:
            OnboardingAgentPickStep(theme: theme, agentRaw: $agentRaw, onAdvance: advance)
        case .pluginInstall:
            OnboardingPluginStep(theme: theme, agent: agent, onAdvance: advance)
        case .vibezId:
            OnboardingVibezIdStep(theme: theme, registrar: registrar, onAdvance: advance)
        case .finish:
            OnboardingFinishStep(theme: theme, agent: agent, onDone: onDismiss)
        }
    }

    private func advance() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            state.advance()
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
        onDismiss: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Tutorial replay (all set up)") {
    OnboardingFlow(
        state: .previewState(steps: [.finish]),
        manager: ScreenTimeManager.previewManager(armed: true),
        registrar: PushTokenRegistrar.previewRegistrar(),
        onDismiss: {}
    )
    .preferredColorScheme(.dark)
}
#endif
