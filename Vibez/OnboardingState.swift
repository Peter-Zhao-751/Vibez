//
//  OnboardingState.swift
//  Vibez
//
//  Step engine for the first-run / incomplete-setup onboarding flow.
//  The gate reads live state (notif status + FC auth + Vibez ID),
//  hardened by "vibez.onboardingCompleted": a completed install only
//  re-presents on a DEFINITE failure (unpaired, or an explicit
//  .denied — see hasDefiniteFailure), never on a cold-launch
//  .notDetermined race. Revoking a permission later still brings the
//  flow back with just the missing step. Design:
//  docs/superpowers/specs/2026-06-04-onboarding-design.md.
//

import Foundation
import UserNotifications

/// One page of the onboarding flow. Raw values double as stable ids
/// for SwiftUI transitions.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case notifications
    case screenTime
    case pluginInstall
    case vibezId
    case finish

    var id: String { rawValue }
}

@Observable
final class OnboardingState: Identifiable {
    /// Lets SettingsView present the tutorial via fullScreenCover(item:).
    nonisolated let id = UUID()

    /// The step list for the current presentation. Frozen at begin()
    /// so a permission granted mid-flow doesn't yank pages out from
    /// under the transition; steps satisfied behind the user's back
    /// (a Settings-app round-trip) auto-skip when they become current
    /// — see advance().
    private(set) var steps: [OnboardingStep] = []
    private(set) var index = 0

    /// Latest notification permission, refreshed async — the only gate
    /// that can't be read synchronously.
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    private let manager: ScreenTimeManager
    private let registrar: PushTokenRegistrar

    init(manager: ScreenTimeManager, registrar: PushTokenRegistrar) {
        self.manager = manager
        self.registrar = registrar
    }

    // MARK: - Gates

    var notificationsGranted: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    var screenTimeAuthorized: Bool {
        #if DEBUG
        // Sim verification seam: Family Controls can never reach
        // .authorized on a simulator (stage-2 consent needs a device
        // passcode), which would wall off every step after Screen Time.
        // `xcrun simctl launch ... -vibez.debug.fakeScreenTimeAuth YES`
        // fakes the gate; NSArgumentDomain never persists.
        if UserDefaults.standard.bool(forKey: "vibez.debug.fakeScreenTimeAuth") {
            return true
        }
        #endif
        return manager.authState == .authorized
    }

    /// Empty-only on purpose: a stored ID with a registration *error*
    /// stays the home setup card's job (it has the retry affordance) —
    /// onboarding shouldn't take over the whole screen for a transient
    /// server failure.
    var paired: Bool { !registrar.vibezId.isEmpty }

    var needsOnboarding: Bool {
        !notificationsGranted || !screenTimeAuthorized || !paired
    }

    /// A failure that is definitely real — not the cold-launch race.
    /// Pairing is a synchronous UserDefaults read, and `.denied` only
    /// comes back when the system actually answered; Family Controls'
    /// `.notDetermined` is ambiguity, not evidence (its daemon can
    /// report that for a beat after process start even when granted).
    /// The launch gate uses this to keep completed installs from
    /// re-presenting — or even waiting on a settle pass — over a
    /// stale read.
    var hasDefiniteFailure: Bool {
        !paired
            || notificationStatus == .denied
            || manager.authState == .denied
    }

    var current: OnboardingStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    /// Whether the current step's gate got satisfied externally (e.g.
    /// permission flipped in the Settings app). The flow checks this on
    /// scenePhase-active and advances with animation if true.
    var currentStepSatisfied: Bool {
        current.map(isSatisfied) ?? false
    }

    // MARK: - Step computation

    /// Pure mapping from gate state to step list. Welcome fronts the
    /// flow only when there's setup to do; finish always closes it —
    /// a fully-set-up Tutorial replay is just [finish].
    static func computeSteps(
        notificationsGranted: Bool,
        screenTimeAuthorized: Bool,
        paired: Bool
    ) -> [OnboardingStep] {
        var steps: [OnboardingStep] = []
        if !notificationsGranted { steps.append(.notifications) }
        if !screenTimeAuthorized { steps.append(.screenTime) }
        if !paired { steps.append(contentsOf: [.pluginInstall, .vibezId]) }
        if !steps.isEmpty { steps.insert(.welcome, at: 0) }
        steps.append(.finish)
        return steps
    }

    // MARK: - Lifecycle

    func refreshNotificationStatus() async {
        notificationStatus = await NotifyClient.notificationAuthorizationStatus()
    }

    /// Family Controls' authorizationStatus can read .notDetermined for
    /// a beat after cold launch even when access was granted (the
    /// daemon connection settles asynchronously). When a failing gate
    /// might be that race, poll for up to ~2s before trusting it —
    /// returns as soon as every gate passes.
    func settleAndRecheck() async {
        for _ in 0..<10 {
            manager.refreshAuthorizationStatus()
            if !needsOnboarding { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        manager.refreshAuthorizationStatus()
        await refreshNotificationStatus()
    }

    /// Snapshot the step list for a fresh presentation and rewind.
    /// Call after refreshNotificationStatus() so the snapshot sees the
    /// real notification gate. Pass `startingAt` to deep-link into a
    /// specific step (the setup card's "Show me how" opens straight at
    /// pluginInstall); a step absent from the snapshot falls back to
    /// the front.
    func begin(startingAt step: OnboardingStep? = nil) {
        steps = Self.computeSteps(
            notificationsGranted: notificationsGranted,
            screenTimeAuthorized: screenTimeAuthorized,
            paired: paired
        )
        index = step.flatMap { steps.firstIndex(of: $0) } ?? 0
    }

    /// Move forward, skipping any step whose gate got satisfied since
    /// the snapshot. finish is never satisfied, so this always lands.
    /// RAW: callers that represent an explicit user CTA (welcome's
    /// Get Started, the plugin page's "I have my Vibez ID", the Vibez
    /// ID page's Continue) use this — leaving an *action* step is the
    /// user's decision. Gate-driven callers (a permission grant, a
    /// Settings round-trip) must use advanceIfCurrentStepSatisfied()
    /// instead so they can't hop past an action step.
    func advance() {
        var next = index + 1
        while next < steps.count - 1, isSatisfied(steps[next]) {
            next += 1
        }
        index = min(next, steps.count - 1)
    }

    /// Advance past the current step ONLY if its own gate is already
    /// satisfied — the idempotent primitive for every "a permission
    /// flipped, move on" trigger.
    ///
    /// Why this exists: a single Screen Time grant fires TWO advance
    /// triggers — the step's in-flow onAdvance AND the scenePhase
    /// `.active` recheck (Family Controls' authorization sheet flips
    /// scenePhase; the notification alert does not, which is why only
    /// Screen Time hit this). With a raw advance() the second trigger
    /// carried the flow from the gate-less pluginInstall action step
    /// straight on to the Vibez ID page, skipping "Install the plugin"
    /// entirely. Routing grant-driven advances through here makes them
    /// idempotent: once the flow lands on an action step (never
    /// "satisfied"), repeat calls no-op.
    func advanceIfCurrentStepSatisfied() {
        guard let step = current, isSatisfied(step) else { return }
        advance()
    }

    /// Whether a step's gate is already met. Action steps (welcome,
    /// plugin instructions, finish) are never "satisfied" — they're
    /// informational and always shown once snapshotted.
    private func isSatisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome, .pluginInstall, .finish:
            false
        case .notifications:
            notificationsGranted
        case .screenTime:
            screenTimeAuthorized
        case .vibezId:
            paired
        }
    }
}

#if DEBUG
extension OnboardingState {
    /// Yields a state pinned to a given step list, bypassing the live
    /// gates. Used by OnboardingFlow previews. Same-file access writes
    /// through the otherwise-private(set) fields.
    static func previewState(
        steps: [OnboardingStep] = OnboardingStep.allCases,
        index: Int = 0
    ) -> OnboardingState {
        let s = OnboardingState(
            manager: ScreenTimeManager.previewManager(armed: false),
            registrar: PushTokenRegistrar.previewRegistrar()
        )
        s.steps = steps
        s.index = index
        return s
    }
}
#endif
