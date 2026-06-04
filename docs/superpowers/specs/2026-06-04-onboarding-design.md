# Vibez Onboarding Flow — Design

**Date:** 2026-06-04
**Status:** Approved by Peter (brainstorming session w/ visual companion)

## Goal

A first-run / incomplete-setup onboarding flow that walks the user through
granting permissions (with practice-tap replicas of the real Apple dialogs),
installing the Mac-side plugin, and pairing a Vibez ID — plus a Tutorial
replay button in Settings. While setup is incomplete, the flow auto-presents
on every app launch.

## Gating rules

`needsOnboarding` is **pure live state — no "hasSeenOnboarding" flag**:

```
needsOnboarding =
       notificationStatus not granted     (.notDetermined or .denied)
    || ScreenTimeManager.authState != .authorized
    || registrar.vibezId.isEmpty
```

- Notification "granted" = `.authorized`, `.provisional`, or `.ephemeral`.
- The Vibez ID gate is **empty-only**. A registration *error* with a stored ID
  does NOT trigger onboarding — the home `VibezSetupCard` already owns retry
  for that case (its `setupNeeded` rule is unchanged).
- First launch trivially fails all three gates. After full setup the flow
  never auto-presents again. Revoking a permission in iOS Settings later
  correctly brings it back with just the missing step (+ Welcome + final).
- Presented on cold launch only — not re-presented on foreground within a
  session (a user who skipped shouldn't get re-ambushed on every app switch).
  Permission state IS re-checked on scenePhase-active so an open flow reacts
  to a Settings-app round-trip.

## Steps

Steps are **snapshotted when the flow presents** (so a grant mid-flow doesn't
yank pages out from under the transition). A step whose gate is already
satisfied when it becomes current auto-advances.

| # | Step | Included when |
|---|------|---------------|
| 1 | Welcome | any of steps 2–6 present |
| 2 | Notifications (practice-tap mock) | notifications not granted |
| 3 | Screen Time (practice-tap mock) | FC not authorized |
| 4 | Agent pick (Claude / Codex / Both) | vibezId empty |
| 5 | Plugin install instructions | vibezId empty |
| 6 | Vibez ID entry | vibezId empty |
| 7 | How Vibez works + version | **always** |

A fully-set-up Tutorial replay therefore shows only step 7.

### Step 1 — Welcome

Mascot, app name, one-liner ("Claude pings → distractions blocked"),
**Get Started** button.

### Steps 2 & 3 — Permission steps (practice-tap mock dialogs)

Instruction copy on top; below it a faithful SwiftUI replica of the real
iOS dialog (`MockSystemDialog`), dark/light aware:

- **Notifications:** title `"Vibez" Would Like to Send You Notifications`,
  body about alerts/sounds/badges, buttons **Don't Allow** / **Allow**.
- **Screen Time:** the Family Controls `.individual` consent dialog,
  buttons **Don't Allow** / **Continue**.
- Exact dialog wording/buttons must be **verified on a real device during
  implementation** and the replicas matched 1:1.

Interaction (approved option "A · Practice tap"):

- Tapping the mock's **Allow/Continue** fires the real system request
  (`UNUserNotificationCenter.requestAuthorization` /
  `AuthorizationCenter.requestAuthorization(for: .individual)`); the real
  dialog appears in the same screen position, so the user repeats the
  identical motion.
- Tapping the mock's **Don't Allow** wiggles the dialog (shake modifier
  already exists in the codebase) and shows a one-line caption on why the
  permission matters. Only Allow proceeds.
- Granted → auto-advance to the next step.
- Denied (now or previously) → the step morphs into a **remediation state**:
  "Open Settings" deep-link (`UIApplication.openNotificationSettingsURLString`
  for notifications, `openSettingsURLString` for Screen Time) + matching
  instructions. For Screen Time also offer "Try again" (re-calling
  `requestAuthorization` re-presents the dialog on some iOS versions; if it
  throws, remain in remediation). Status re-checked on scenePhase-active;
  auto-advance if fixed.

### Step 4 — Agent pick

"Which agent do you use?" — tap a mascot: Claude / Codex / Both. Writes the
existing `vibez.agent` @AppStorage (drives accent + home mascot) and filters
step 5's instructions.

### Step 5 — Plugin install

Copyable command rows for the picked agent:

- **Claude Code:** `/plugin marketplace add Peter-Zhao-751/Vibez` →
  `/plugin install vibez@plugin` → `/vibez:setup`
- **Codex:** `codex plugin marketplace add Peter-Zhao-751/Vibez` →
  `codex plugin install vibez@vibez` → `vibez-setup` skill
- **Both:** both sets, compact.

Ends with: "the setup command prints your 4-word Vibez ID."

### Step 6 — Vibez ID entry

Monospaced field (placeholder `moss-pine-fox-jazz`), same validation +
pairing via `registrar.setVibezId(...)` as `VibezSetupCard`, live status
(registering… → paired ✓, errors with retry). **Continue unlocks once
`state == .registered`** (covers the `"test"` offline escape hatch, which
restores straight to `.registered`).

### Step 7 — How Vibez works + version

Short explainer: agent finishes or needs you → push → picked apps shield
until you reply on the Mac, dismiss, or the timer runs out; mascot tap =
focus mode; toggle arms Vibez; Settings owns apps/durations. App version +
build (`CFBundleShortVersionString` / `CFBundleVersion`) at the bottom.
**Done** dismisses.

## Chrome & navigation

- **Skip for now** top-right on every step (approved: skippable). Dismisses
  the cover; the flow returns next cold launch until gates pass. On step 7
  the affordance is just **Done**.
- Progress dots at the bottom (one per snapshotted step).
- Forward-only: no back swipe; ZStack + slide/fade transitions.
- Themed via the app's `Theme` (Claude accent until the agent pick changes
  it), respects the `vibez.appearance` preference.

## Architecture

New files (auto-build via `PBXFileSystemSynchronizedRootGroup`):

| File | Responsibility |
|------|----------------|
| `Vibez/OnboardingState.swift` | `@Observable`. Reads FC auth, async notification status, `registrar.vibezId`. Exposes `needsOnboarding`, pure `computeSteps(...)`, snapshot + advance logic, scenePhase refresh. |
| `Vibez/OnboardingFlow.swift` | fullScreenCover content: step container, transitions, dots, Skip. |
| `Vibez/OnboardingSteps.swift` | The seven step views. |
| `Vibez/MockSystemDialog.swift` | Reusable iOS-alert replica (practice-tap + wiggle + highlight states). |

Modified files:

- **`ContentView.swift`** — present the cover when `needsOnboarding` at
  launch; **remove the auto-requesting `.task`** (today it fires both real
  permission prompts on first appear, which would preempt the instruction
  screens). Onboarding becomes the sole requester of both permissions.
- **`NotifyClient.swift`** — add a static async
  `notificationAuthorizationStatus()` reader (only `requestAuthorization`
  exists today).
- **`SettingsView.swift`** — new "Tutorial" row presenting the same
  `OnboardingFlow` (steps recomputed at present time).

`VibezSetupCard` stays as-is — it still covers the skipped-onboarding and
registration-error cases on the home screen.

## Presentation timing

FC auth + vibezId are readable synchronously at launch; only the
notification status is async. Present the cover as soon as `needsOnboarding`
resolves true (sync-fail → immediately; notif-only-missing → after the
~instant async check). A 1–2 frame flash of home is acceptable.

## Edge cases

- `"test"` Vibez ID → step 6 unlocks like a real pairing (state
  `.registered`), no server call.
- Mid-flow grant via iOS Settings (user backgrounds, grants, returns) →
  scenePhase refresh updates statuses; satisfied steps auto-advance when
  reached.
- Registration error during step 6 → inline error + retry, Continue stays
  locked; user may Skip (home card persists the retry affordance).
- Appearance: both color schemes; the mock dialog uses its own
  system-faithful palette, not app theme colors.

## Testing

- `computeSteps` is a pure function — unit-test status-combination →
  step-list mapping if an app test target exists; otherwise cover via
  previews (one per step + per state) and treat previews as the spec.
- Simulator: layout/flow verification with launch-arg seeding
  (`-vibez.vibezId test`, etc. — see memory note on NSArgumentDomain
  masking writes). FC prompts and shield behavior: real device only.
- On-device: verify exact system dialog copy; verify practice-tap → real
  prompt positioning; verify denied → remediation → Settings round-trip.
