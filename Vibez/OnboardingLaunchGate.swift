//
//  OnboardingLaunchGate.swift
//  Vibez
//
//  ContentView's cold-launch onboarding plumbing, extracted into a
//  modifier: decides once per launch whether the OnboardingFlow cover
//  needs to present, owns the flow's state + presentation, and arms
//  the big toggle after a completed (not skipped) walkthrough. All
//  gating *logic* stays in OnboardingState — this is just the
//  presentation shell. SettingsView's Tutorial replay presents the
//  same OnboardingFlow through its own item-based cover.
//

import SwiftUI

struct OnboardingLaunchGate: ViewModifier {
    private let manager: ScreenTimeManager
    private let registrar: PushTokenRegistrar
    @State private var onboarding: OnboardingState
    @State private var presented = false
    /// Set when the user finishes the walkthrough (or a launch check
    /// finds setup already complete). A completed install never shows
    /// onboarding off a single failing cold-launch read — Family
    /// Controls can spuriously report .notDetermined right after
    /// process start, which used to flash the flow at fully-set-up
    /// users. Genuine revocations still re-present after the
    /// settle-recheck confirms them.
    @AppStorage("vibez.onboardingCompleted") private var onboardingCompleted = false

    init(manager: ScreenTimeManager, registrar: PushTokenRegistrar) {
        self.manager = manager
        self.registrar = registrar
        _onboarding = State(
            initialValue: OnboardingState(manager: manager, registrar: registrar)
        )
    }

    private static var isRunningInPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    func body(content: Content) -> some View {
        content
            .task {
                // Onboarding owns the system permission prompts — each
                // is requested from its practice-tap step. This launch
                // check only decides whether the flow needs to present.
                // .task runs once per view lifetime, so this is a cold-
                // launch gate — backgrounding doesn't re-present a skipped
                // flow. Previews construct seeded singletons but the sim's
                // notification status is still notDetermined; don't let the
                // cover bury every existing home-screen preview.
                guard !Self.isRunningInPreviews else { return }
                #if DEBUG
                // Sim verification seam: home-screen states that only
                // exist while setup is incomplete (the pairing card)
                // are otherwise buried under this cover on launch.
                // `xcrun simctl launch ... -vibez.debug.skipOnboarding YES`
                if UserDefaults.standard.bool(forKey: "vibez.debug.skipOnboarding") {
                    return
                }
                #endif
                await onboarding.refreshNotificationStatus()
                guard onboarding.needsOnboarding else {
                    // Everything granted + paired — mark complete so future
                    // launches take the settled path (also self-heals
                    // installs that finished setup before the flag existed).
                    onboardingCompleted = true
                    return
                }
                if onboardingCompleted {
                    // A completed install re-presents ONLY on a definite
                    // failure (unpaired, or an explicit .denied) — never
                    // on ambiguity. Family Controls can read
                    // .notDetermined for a beat after cold launch even
                    // when granted; presenting (or stalling in a settle
                    // poll) on that read is exactly the "onboarding
                    // flashes at a fully-set-up user on the next launch"
                    // bug. A real revocation reads .denied and still
                    // re-presents; anything ambiguous keeps the home
                    // screen (Settings → Tutorial stays the manual path).
                    guard onboarding.hasDefiniteFailure else { return }
                } else if onboarding.paired && onboarding.notificationsGranted {
                    // Never-completed install with Screen Time as the ONLY
                    // failing gate — the one unreliable read. Let it settle
                    // for up to ~2s before trusting the failure. Genuine
                    // first runs fail multiple reliable gates and skip the
                    // wait entirely.
                    await onboarding.settleAndRecheck()
                    guard onboarding.needsOnboarding else {
                        onboardingCompleted = true
                        return
                    }
                }
                onboarding.begin()
                presented = true
            }
            .fullScreenCover(isPresented: $presented) {
                OnboardingFlow(
                    state: onboarding,
                    manager: manager,
                    registrar: registrar,
                    onDismiss: { presented = false },
                    onFinish: {
                        onboardingCompleted = true
                        presented = false
                        // Completed the walkthrough (not skipped): flip the
                        // big toggle on for them, in the same beat as the
                        // dismissal — the flip plays while the cover slides
                        // away, so the home screen is revealed with the
                        // toggle on (or finishing its animation), not
                        // flipping a second later. No-ops when already
                        // armed (Tutorial-after-revoke replays through
                        // this same path).
                        guard !manager.armed else { return }
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            manager.setArmed(true)
                        }
                    }
                )
            }
    }
}

extension View {
    /// Present the onboarding walkthrough over this view on cold launch
    /// while setup is incomplete. See OnboardingLaunchGate.
    func onboardingLaunchGate(
        manager: ScreenTimeManager,
        registrar: PushTokenRegistrar
    ) -> some View {
        modifier(OnboardingLaunchGate(manager: manager, registrar: registrar))
    }
}
