# Vibez Onboarding Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First-run / incomplete-setup onboarding flow with practice-tap mock Apple permission dialogs, plugin-install + Vibez ID pairing steps, and a Settings Tutorial replay — gated purely on live state, per the approved spec at `docs/superpowers/specs/2026-06-04-onboarding-design.md`.

**Architecture:** A `fullScreenCover` over the home screen driven by an `@Observable OnboardingState` step engine. Steps are computed from live gates (notification status, Family Controls auth, Vibez ID presence), snapshotted at presentation, forward-only with auto-skip of steps satisfied mid-flow. The same engine backs the launch gate (ContentView) and the Settings Tutorial replay.

**Tech Stack:** SwiftUI (iOS 26.4 SDK), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (assume MainActor everywhere; `nonisolated` only deliberately). Project uses `PBXFileSystemSynchronizedRootGroup` — dropping a `.swift` into `Vibez/` auto-builds it.

**Verification note (no TDD here):** `Vibez.xcodeproj` has **no app test target** (verified — zero `XCTest`/`.xctest` references in the pbxproj). Repo convention is compile checks + `#Preview` blocks + simulator/device verification. Each task therefore ends with a compile check instead of a unit test run; previews are included per codebase convention. `OnboardingState.computeSteps` is still a pure static function so a future test target can cover it trivially.

**Dirty-tree warning:** The working tree already has uncommitted modifications to `ContentView.swift`, `SettingsView.swift`, `NotifyClient.swift`, `ScreenTimeManager.swift`, and `CLAUDE.md` that predate this feature. Commit **new files only** as you go. For the modified shared files, STOP at Task 8 and ask Peter how to handle the pre-existing changes before committing them.

**Compile check command** (used by several tasks; Firebase packages are already resolved so incremental builds are quick):

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez -sdk iphonesimulator26.4 \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

---

### Task 1: Permission-status readers (NotifyClient + ScreenTimeManager)

**Files:**
- Modify: `Vibez/NotifyClient.swift` (after `requestAuthorization()`, ~line 323)
- Modify: `Vibez/ScreenTimeManager.swift` (in the `// MARK: - Authorization` section, after `requestAuthorization()`, ~line 222)

- [ ] **Step 1: Add notification status reader to NotifyClient**

In `Vibez/NotifyClient.swift`, directly below the existing `static func requestAuthorization()` (inside the same `// MARK: - Permissions` section):

```swift
    /// Current notification permission, read fresh from the system.
    /// OnboardingState gates the notifications step on this —
    /// requestAuthorization() above deliberately swallows the grant
    /// result, so callers re-read the status through here after asking.
    static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current()
            .notificationSettings()
            .authorizationStatus
    }
```

- [ ] **Step 2: Add public Family Controls re-sync to ScreenTimeManager**

In `Vibez/ScreenTimeManager.swift`, directly below `requestAuthorization()`:

```swift
    /// Re-reads the live Family Controls status. Public hook for
    /// onboarding's scenePhase refresh — a grant made in the Settings
    /// app doesn't update `authState` until something re-syncs it.
    func refreshAuthorizationStatus() {
        syncAuthState()
    }
```

- [ ] **Step 3: Compile check**

Run the compile check command from the header. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Do NOT commit yet**

Both files carry unrelated pre-existing modifications (see dirty-tree warning). These two additions ride along until Task 8.

---

### Task 2: OnboardingState step engine

**Files:**
- Create: `Vibez/OnboardingState.swift`

- [ ] **Step 1: Create the file with the full step engine**

```swift
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

    var screenTimeAuthorized: Bool { manager.authState == .authorized }

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
```

- [ ] **Step 2: Compile check**

Run the compile check command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit (new file only)**

```bash
git add Vibez/OnboardingState.swift
git commit -m "feat(onboarding): add OnboardingState step engine"
```

---

### Task 3: MockSystemDialog (practice-tap replica)

**Files:**
- Create: `Vibez/MockSystemDialog.swift`

Uses the existing `.shake(trigger:amount:shakesPerUnit:duration:)` modifier from `Vibez/Components.swift:173`.

- [ ] **Step 1: Create the file**

```swift
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
```

- [ ] **Step 2: Compile check**

Run the compile check command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Vibez/MockSystemDialog.swift
git commit -m "feat(onboarding): add practice-tap mock system dialog"
```

---

### Task 4: The seven step views

**Files:**
- Create: `Vibez/OnboardingSteps.swift`

Notes for the implementer:
- `Theme` fields used here (`bg`, `bgPanel`, `bgChip`, `fg`, `fgMute`, `fgFaint`, `hairline`, `accent`, `onAccent`) all exist — `Vibez/Theme.swift:87`.
- `MascotForAgent(agent:listening:size:gap:focused:animate:)` — `gap`/`focused`/`animate` have defaults (`Vibez/Mascots.swift:62`).
- The Vibez ID step intentionally duplicates `VibezSetupCard`'s field/status mechanics (the layouts differ; the card stays for home-screen error/skip cases). Keep the logic identical — same validation call, same status copy.
- Plugin install commands come from the repo READMEs (`README.md:54-66`).

- [ ] **Step 1: Create the file**

```swift
//
//  OnboardingSteps.swift
//  Vibez
//
//  The individual pages of the onboarding flow. Layout scaffolding
//  (headline / subtitle / centered content / pinned CTA) is shared via
//  OnboardingPage; all gating decisions live in OnboardingState — these
//  views only render state and fire actions.
//

import SwiftUI
import UIKit

// MARK: - Shared page scaffolding

/// Common page chrome. Content is vertically centered between the
/// header and the CTA, which keeps each permission step's mock dialog
/// near where the real system alert will appear (screen center).
struct OnboardingPage<Content: View>: View {
    let theme: Theme
    let headline: String
    let subtitle: String
    var ctaTitle: String? = nil
    var ctaEnabled: Bool = true
    var ctaAction: () -> Void = {}
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text(headline)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.fg)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(theme.fgMute)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 76)   // clears the Skip button row
            .padding(.horizontal, 32)

            Spacer(minLength: 16)

            content()

            Spacer(minLength: 16)

            if let ctaTitle {
                Button(action: ctaAction) {
                    Text(ctaTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ctaEnabled ? theme.onAccent : theme.fgFaint)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(ctaEnabled ? theme.accent : theme.bgChip)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!ctaEnabled)
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 58)   // clears the progress dots
    }
}

// MARK: - Step 1 · Welcome

struct OnboardingWelcomeStep: View {
    let theme: Theme
    let agent: Agent
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Welcome to Vibez",
            subtitle: "When Claude or Codex finishes a task or needs you, Vibez blocks your distracting apps — agent idle time becomes focus time.",
            ctaTitle: "Get Started",
            ctaAction: onContinue
        ) {
            MascotForAgent(agent: agent, listening: true, size: 150)
        }
    }
}

// MARK: - Remediation (denied permissions)

/// "Open Settings" remediation shown when a permission was denied —
/// iOS shows each system prompt only once, so the fix lives in the
/// Settings app. The flow re-checks gates on scenePhase-active and
/// auto-advances when the round-trip fixed it.
struct OnboardingRemediation: View {
    let theme: Theme
    let explanation: String
    let settingsURL: URL?
    var retryLabel: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text(explanation)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(theme.fgMute)
                .multilineTextAlignment(.center)

            Button {
                if let settingsURL {
                    UIApplication.shared.open(settingsURL)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14).fill(theme.accent)
                    )
            }
            .buttonStyle(.plain)

            if let retryLabel, let onRetry {
                Button(retryLabel, action: onRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 36)
    }
}

// MARK: - Step 2 · Notifications

struct OnboardingNotificationsStep: View {
    let theme: Theme
    @Bindable var state: OnboardingState
    let onAdvance: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Allow notifications",
            subtitle: "Vibez pings you the moment Claude finishes or needs your input. iOS is about to show the dialog below for real — tap Allow, exactly like this."
        ) {
            if state.notificationStatus == .denied {
                OnboardingRemediation(
                    theme: theme,
                    explanation: "Notifications are currently off for Vibez. iOS only asks once — flip them on in Settings, then come back here.",
                    settingsURL: URL(string: UIApplication.openNotificationSettingsURLString)
                )
            } else {
                MockSystemDialog(
                    title: "“Vibez” Would Like to Send You Notifications",
                    message: "Notifications may include alerts, sounds, and icon badges. These can be configured in Settings.",
                    cancelLabel: "Don’t Allow",
                    confirmLabel: "Allow",
                    denyHint: "You’ll want Allow — without it, Vibez can’t ping you when your agent needs you.",
                    onConfirm: requestPermission
                )
            }
        }
    }

    private func requestPermission() {
        Task {
            await NotifyClient.requestAuthorization()
            await state.refreshNotificationStatus()
            if state.notificationsGranted {
                onAdvance()
            }
            // Denied → notificationStatus is now .denied and the view
            // re-renders into the remediation state on its own.
        }
    }
}

// MARK: - Step 3 · Screen Time

struct OnboardingScreenTimeStep: View {
    let theme: Theme
    @Bindable var manager: ScreenTimeManager
    let onAdvance: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Allow Screen Time access",
            subtitle: "This is what lets Vibez actually shield Instagram, TikTok & co. iOS is about to show this dialog for real — tap Continue, exactly like this."
        ) {
            if manager.authState == .denied {
                OnboardingRemediation(
                    theme: theme,
                    explanation: "Screen Time access was declined. Try again, or enable it for Vibez in Settings, then come back here.",
                    settingsURL: URL(string: UIApplication.openSettingsURLString),
                    retryLabel: "Try again",
                    onRetry: requestPermission
                )
            } else {
                MockSystemDialog(
                    title: "“Vibez” Would Like to Access Screen Time",
                    message: "Providing “Vibez” access to Screen Time may allow it to see your activity data, restrict content, and limit the usage of apps and websites.",
                    cancelLabel: "Don’t Allow",
                    confirmLabel: "Continue",
                    denyHint: "You’ll want Continue — Screen Time access is the mechanism that blocks your distracting apps.",
                    onConfirm: requestPermission
                )
            }
        }
    }

    private func requestPermission() {
        Task {
            await manager.requestAuthorization()
            if manager.authState == .authorized {
                onAdvance()
            }
        }
    }
}

// MARK: - Step 4 · Agent pick

struct OnboardingAgentPickStep: View {
    let theme: Theme
    @Binding var agentRaw: String
    let onAdvance: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Which agent do you use?",
            subtitle: "Picks the mascot, the accent color, and which install instructions you see next. Change it anytime in the app."
        ) {
            VStack(spacing: 12) {
                ForEach([Agent.claude, .codex, .both]) { option in
                    agentRow(option)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func agentRow(_ option: Agent) -> some View {
        let selected = agentRaw == option.rawValue
        let rowTheme = Theme.make(agent: option)
        return Button {
            agentRaw = option.rawValue
            // Brief pause so the checkmark registers before the slide.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                onAdvance()
            }
        } label: {
            HStack(spacing: 14) {
                MascotForAgent(
                    agent: option,
                    listening: true,
                    size: 44,
                    gap: 3,
                    animate: false
                )
                .frame(width: 76)
                Text(option == .both ? "Both" : option.label)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.fg)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? rowTheme.accent : theme.fgFaint)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16).fill(theme.bgPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        selected ? rowTheme.accent : theme.hairline,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 5 · Plugin install

struct OnboardingPluginStep: View {
    let theme: Theme
    let agent: Agent
    let onAdvance: () -> Void

    @State private var copiedCommand: String?

    private struct CommandRow: Identifiable {
        let text: String
        var copyable = true
        var id: String { text }
    }

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Install the plugin",
            subtitle: "On your Mac. The setup command at the end prints your 4-word Vibez ID — keep it handy for the next step.",
            ctaTitle: "I have my Vibez ID",
            ctaAction: onAdvance
        ) {
            VStack(spacing: 18) {
                if agent != .codex {
                    commandGroup(
                        label: "Claude Code",
                        accent: Theme.claudeOrange,
                        rows: [
                            CommandRow(text: "/plugin marketplace add Peter-Zhao-751/Vibez"),
                            CommandRow(text: "/plugin install vibez@plugin"),
                            CommandRow(text: "/vibez:setup"),
                        ]
                    )
                }
                if agent != .claude {
                    commandGroup(
                        label: "Codex",
                        accent: Theme.codexBlue,
                        rows: [
                            CommandRow(text: "codex plugin marketplace add Peter-Zhao-751/Vibez"),
                            CommandRow(text: "codex plugin install vibez@vibez"),
                            CommandRow(text: "ask Codex to run vibez-setup", copyable: false),
                        ]
                    )
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func commandGroup(
        label: String,
        accent: Color,
        rows: [CommandRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.fgMute)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                commandRowView(number: i + 1, row: row)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.bgPanel))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.hairline, lineWidth: 1)
        )
    }

    private func commandRowView(number: Int, row: CommandRow) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.fgFaint)
            Text(row.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.copyable ? theme.fg : theme.fgMute)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            if row.copyable {
                Image(systemName: copiedCommand == row.text ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copiedCommand == row.text ? .green : theme.fgMute)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.bgChip))
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.copyable else { return }
            UIPasteboard.general.string = row.text
            withAnimation { copiedCommand = row.text }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                if copiedCommand == row.text { copiedCommand = nil }
            }
        }
    }
}

// MARK: - Step 6 · Vibez ID

struct OnboardingVibezIdStep: View {
    let theme: Theme
    @Bindable var registrar: PushTokenRegistrar
    let onAdvance: () -> Void

    @State private var draft = ""
    @State private var fieldError: String?
    @FocusState private var focused: Bool

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Mirrors VibezSetupCard: save only a well-formed, *different* ID;
    /// a pure re-submit goes through the retry button.
    private var saveable: Bool {
        PushTokenRegistrar.isValidVibezId(trimmed)
            && trimmed != registrar.vibezId
    }

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Enter your Vibez ID",
            subtitle: "The 4 words the setup command printed on your Mac. It pairs this phone to your agents.",
            ctaTitle: "Continue",
            ctaEnabled: registrar.state == .registered,
            ctaAction: onAdvance
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        if draft.isEmpty && !focused {
                            Text("moss-pine-fox-jazz")
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(theme.fgFaint)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $draft)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(theme.fg)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit { commit() }
                            .onChange(of: draft) { _, _ in
                                if fieldError != nil { fieldError = nil }
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12).fill(theme.bgChip)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(theme.hairline, lineWidth: 1)
                    )

                    Button(action: commit) {
                        Text(registrar.state == .registering ? "…" : "Pair")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(saveable ? theme.onAccent : theme.fgFaint)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(saveable ? theme.accent : theme.bgChip)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!saveable)
                }

                statusRow

                if let fieldError {
                    Text(fieldError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.fgMute)
                .lineLimit(2)
            Spacer(minLength: 0)
            if case .error = registrar.state {
                Button("retry") {
                    Task { await registrar.reregister() }
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.fg)
                .buttonStyle(.plain)
            }
        }
    }

    private var statusColor: Color {
        switch registrar.state {
        case .idle:        .secondary
        case .registering: .orange
        case .registered:  .green
        case .error:       .red
        }
    }

    private var statusLabel: String {
        switch registrar.state {
        case .idle:
            registrar.vibezId.isEmpty ? "no Vibez ID yet" : "waiting for FCM token…"
        case .registering:
            "registering…"
        case .registered:
            registrar.isTestMode ? "test mode (no server)" : "paired ✓"
        case .error(let m):
            "error: \(m.prefix(80))"
        }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        guard PushTokenRegistrar.isValidVibezId(trimmed) else {
            fieldError = "Format: 4 hyphenated words, each 3-5 letters (e.g. moss-pine-fox-jazz)."
            return
        }
        fieldError = nil
        focused = false
        registrar.setVibezId(trimmed)
    }
}

// MARK: - Step 7 · How Vibez works + version

struct OnboardingFinishStep: View {
    let theme: Theme
    let agent: Agent
    let onDone: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "How Vibez works",
            subtitle: "You're set. Here's the loop:",
            ctaTitle: "Done",
            ctaAction: onDone
        ) {
            VStack(spacing: 0) {
                MascotForAgent(agent: agent, listening: true, size: 84, animate: false)
                    .padding(.bottom, 22)

                VStack(alignment: .leading, spacing: 16) {
                    bullet(
                        icon: "bell.badge.fill",
                        text: "Your agent finishes a task or needs input → Vibez gets a push."
                    )
                    bullet(
                        icon: "shield.fill",
                        text: "Your picked apps shield until you reply on the Mac, dismiss, or the timer runs out."
                    )
                    bullet(
                        icon: "hand.tap.fill",
                        text: "Tap the mascot anytime for a manual focus hold."
                    )
                    bullet(
                        icon: "switch.2",
                        text: "The big toggle arms Vibez; Settings picks apps and block durations."
                    )
                }
                .padding(.horizontal, 30)

                Text(Self.versionString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fgFaint)
                    .padding(.top, 24)
            }
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(theme.accent)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Vibez \(v) (\(b))"
    }
}
```

- [ ] **Step 2: Compile check**

Run the compile check command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Vibez/OnboardingSteps.swift
git commit -m "feat(onboarding): add the seven onboarding step views"
```

---

### Task 5: OnboardingFlow container

**Files:**
- Create: `Vibez/OnboardingFlow.swift`

- [ ] **Step 1: Create the file**

```swift
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
```

- [ ] **Step 2: Compile check**

Run the compile check command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Vibez/OnboardingFlow.swift
git commit -m "feat(onboarding): add OnboardingFlow container"
```

---

### Task 6: ContentView integration (launch gate)

**Files:**
- Modify: `Vibez/ContentView.swift` — init (~line 26-60), the `.task` modifier (~line 225-233), and the modifier chain after `.sheet(isPresented: $showSettings)` (~line 283)

- [ ] **Step 1: Add onboarding state to ContentView**

Add to the `@State` block (next to the other singletons, ~line 25):

```swift
    @State private var onboarding: OnboardingState
```

Add with the other UI `@State` vars (~line 83):

```swift
    @State private var onboardingPresented = false
```

In `init`, the manager line currently reads:

```swift
        let reg = registrar ?? .shared
        _manager = State(initialValue: manager ?? .shared)
```

Replace those two lines with:

```swift
        let reg = registrar ?? .shared
        let mgr = manager ?? .shared
        _manager = State(initialValue: mgr)
        _onboarding = State(initialValue: OnboardingState(manager: mgr, registrar: reg))
```

- [ ] **Step 2: Replace the auto-requesting `.task`**

The current block fires both real permission prompts on first appear — exactly what would preempt the instruction screens:

```swift
        .task {
            // Request notification permission early — the setup card
            // is still visible while iOS shows the system prompt, so
            // the user can do both in parallel.
            await NotifyClient.requestAuthorization()
            if manager.authState == .notDetermined {
                await manager.requestAuthorization()
            }
        }
```

Replace it with:

```swift
        .task {
            // Onboarding owns the system permission prompts now — each
            // is requested from its practice-tap step. This launch
            // check only decides whether the flow needs to present.
            // .task runs once per view lifetime, so this is a cold-
            // launch gate — backgrounding doesn't re-present a skipped
            // flow. Previews construct seeded singletons but the sim's
            // notification status is still notDetermined; don't let the
            // cover bury every existing home-screen preview.
            guard !Self.isRunningInPreviews else { return }
            await onboarding.refreshNotificationStatus()
            if onboarding.needsOnboarding {
                onboarding.begin()
                onboardingPresented = true
            }
        }
```

And add the helper near the other private statics (e.g. below `setupNeeded(for:)`, ~line 145):

```swift
    private static var isRunningInPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
```

- [ ] **Step 3: Present the cover**

After the `.sheet(isPresented: $showSettings) { ... }` modifier, add:

```swift
        .fullScreenCover(isPresented: $onboardingPresented) {
            OnboardingFlow(
                state: onboarding,
                manager: manager,
                registrar: registrar,
                onDismiss: { onboardingPresented = false }
            )
        }
```

- [ ] **Step 4: Compile check**

Run the compile check command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: No commit** (shared dirty file — handled in Task 8)

---

### Task 7: SettingsView Tutorial row

**Files:**
- Modify: `Vibez/SettingsView.swift` — `@State` block (~line 49), `Form` body (~line 81-89), modifier chain on the `NavigationStack` (~line 121-127), new section helper

- [ ] **Step 1: Add tutorial state**

Next to the other `@State` vars:

```swift
    @State private var tutorial: OnboardingState?
```

- [ ] **Step 2: Add the section to the Form**

The Form body currently ends with `ignoredConversationsSection`. Add a new line after it:

```swift
                ignoredConversationsSection
                tutorialSection
```

- [ ] **Step 3: Add the section view + cover**

Add alongside the other section builders (e.g. after `notificationsSection`):

```swift
    @ViewBuilder
    private var tutorialSection: some View {
        Section {
            Button {
                let s = OnboardingState(manager: manager, registrar: registrar)
                Task {
                    // Snapshot AFTER the async status read so the step
                    // list sees the real notification gate.
                    await s.refreshNotificationStatus()
                    s.begin()
                    tutorial = s
                }
            } label: {
                HStack {
                    Label("Tutorial", systemImage: "graduationcap")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("Replays the setup walkthrough. Steps you've already completed are skipped — fully set up, it's a quick tour of how Vibez works plus the app version.")
        }
    }
```

Add to the NavigationStack's modifier chain (after the `.sheet(isPresented: $showAddIgnoreSheet)` block):

```swift
            .fullScreenCover(item: $tutorial) { s in
                OnboardingFlow(
                    state: s,
                    manager: manager,
                    registrar: registrar,
                    onDismiss: { tutorial = nil }
                )
            }
```

- [ ] **Step 4: Compile check**

Run the compile check command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: No commit** (shared dirty file — handled in Task 8)

---

### Task 8: Docs, simulator verification, final commit

**Files:**
- Modify: `CLAUDE.md` (file map + ContentView description)
- Verify on simulator

- [ ] **Step 1: Update CLAUDE.md file map**

In the `Vibez/` section of the file map, after the `VibezSetupCard.swift` entry, add:

```
  OnboardingState.swift       @Observable step engine for the onboarding flow. Gate is
                              pure live state (notif status + FC auth + Vibez ID present)
                              — no "seen onboarding" flag. Steps snapshot at begin();
                              advance() auto-skips steps satisfied mid-flow.
  OnboardingFlow.swift        fullScreenCover container: forward-only transitions, progress
                              dots, Skip, scenePhase re-check for Settings round-trips.
                              Presented by ContentView (launch) and SettingsView (Tutorial).
  OnboardingSteps.swift       The seven pages: welcome, notifications + Screen Time
                              (practice-tap mock dialogs w/ denied-state remediation),
                              agent pick, plugin install, Vibez ID pairing, how-it-works
                              + app version.
  MockSystemDialog.swift      Practice-tap replica of the iOS permission alert — confirm
                              fires the real prompt; Don't Allow wiggles + hints. System
                              look on purpose (not app theme).
```

In the `ContentView.swift` file-map entry, append a sentence: `Presents OnboardingFlow as a fullScreenCover on launch while setup is incomplete; onboarding owns the permission prompts (the old auto-requesting .task is gone).`

- [ ] **Step 2: Build & install on simulator, verify the launch gate**

```bash
xcrun simctl boot "iPhone 15 Pro" 2>/dev/null || true
xcodebuild -project Vibez.xcodeproj -scheme Vibez -sdk iphonesimulator26.4 \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build 2>&1 | tail -3
# Find the built .app and install fresh (fresh install = notDetermined permissions)
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*iphonesimulator/Vibez.app" -newer /tmp -print -quit 2>/dev/null || \
      find ~/Library/Developer/Xcode/DerivedData -path "*iphonesimulator/Vibez.app" -print -quit)
xcrun simctl uninstall booted vibezlol.Vibez 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted vibezlol.Vibez
sleep 3 && xcrun simctl io booted screenshot /tmp/onboarding-1-welcome.png
```

Expected: screenshot shows the Welcome step (mascot + "Welcome to Vibez" + Get Started), NOT the home screen. **Caution (memory note):** do not pass `-vibez.vibezId` launch args here — NSArgumentDomain values mask in-app writes; a fresh install already fails all gates.

- [ ] **Step 3: Walk the flow on the simulator**

Tap through: Get Started → notifications mock (tap mock Allow → real sim dialog appears → Allow → auto-advance) → Screen Time mock (FamilyControls dialog on sim — see the memory note about the dialog click workaround if taps don't land) → agent pick → plugin install (verify copy buttons) → Vibez ID (enter `test` → "test mode (no server)" → Continue unlocks) → finish page shows version → Done. Screenshot each step to `/tmp/onboarding-N-<step>.png`.

Also verify: relaunch the app (`xcrun simctl launch booted vibezlol.Vibez`) after completing setup → onboarding does NOT re-present. Then Settings → Tutorial → only the finish page shows.

- [ ] **Step 4: STOP — ask Peter about the dirty shared files**

`ContentView.swift`, `SettingsView.swift`, `NotifyClient.swift`, `ScreenTimeManager.swift`, and `CLAUDE.md` had uncommitted modifications **before** this feature. Show `git diff --stat` and ask whether to (a) commit everything together, (b) commit only if he confirms the pre-existing changes are his finished work, or (c) leave the shared files uncommitted.

- [ ] **Step 5: Final commit (per Peter's answer)**

```bash
git add Vibez/ContentView.swift Vibez/SettingsView.swift Vibez/NotifyClient.swift \
        Vibez/ScreenTimeManager.swift CLAUDE.md
git commit -m "feat(onboarding): launch gate, Settings tutorial, permission readers

Onboarding now owns the system permission prompts (ContentView's
auto-requesting .task is gone). Settings gains a Tutorial row that
replays the flow with completed steps skipped."
```

---

## Post-plan notes

- **On-device verification (Peter, later):** exact wording of the two system dialogs vs the replicas; practice-tap → real prompt positioning; denied → Settings round-trip auto-advance. The replica copy lives only in `OnboardingSteps.swift` — trivial to adjust.
- **Not in scope (YAGNI, per spec):** app-selection step, re-presenting on foreground, persisting onboarding progress mid-flow.
