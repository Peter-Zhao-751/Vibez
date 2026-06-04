//
//  OnboardingState.swift
//  Vibez
//
//  Step engine for the first-run / incomplete-setup onboarding flow.
//  The gate is pure live state — no "seen onboarding" flag: the flow
//  presents while a permission is missing or no Vibez ID is paired and
//  stops appearing the moment setup completes. Revoking a permission
//  later correctly brings it back with just the missing step. Design:
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
    case agentPick
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
        if !paired { steps.append(contentsOf: [.agentPick, .pluginInstall, .vibezId]) }
        if !steps.isEmpty { steps.insert(.welcome, at: 0) }
        steps.append(.finish)
        return steps
    }

    // MARK: - Lifecycle

    func refreshNotificationStatus() async {
        notificationStatus = await NotifyClient.notificationAuthorizationStatus()
    }

    /// Snapshot the step list for a fresh presentation and rewind.
    /// Call after refreshNotificationStatus() so the snapshot sees the
    /// real notification gate.
    func begin() {
        steps = Self.computeSteps(
            notificationsGranted: notificationsGranted,
            screenTimeAuthorized: screenTimeAuthorized,
            paired: paired
        )
        index = 0
    }

    /// Move forward, skipping any step whose gate got satisfied since
    /// the snapshot. finish is never satisfied, so this always lands.
    func advance() {
        var next = index + 1
        while next < steps.count - 1, isSatisfied(steps[next]) {
            next += 1
        }
        index = min(next, steps.count - 1)
    }

    /// Whether a step's gate is already met. Action steps (welcome,
    /// agent pick, plugin instructions, finish) are never "satisfied" —
    /// they're informational and always shown once snapshotted.
    private func isSatisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome, .agentPick, .pluginInstall, .finish:
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
