# Vibez Focus Mode — Design

**Date:** 2026-06-01
**Status:** Approved, not yet implemented.

## Goal

Give the user a deliberate, manual way to block their selected apps **right
now**, independent of any agent push. When Vibez is armed (the big toggle is
ON) and the user **taps the mascot**, all selected apps shield immediately and
stay shielded — regardless of whether any push has landed — until the user taps
the mascot again to release. This is "focus mode."

## Mental model

Today the OS shield is up **iff** there is at least one open per-session
trigger:

```
isBlocking = !pendingTriggers.isEmpty        // timed, per-session, push-driven
shield up  ⇔  isBlocking
```

Focus mode adds one orthogonal, user-driven reason to hold the shield. The
shield decision becomes:

```
shouldShield = !pendingTriggers.isEmpty  ||  focusMode
shield up    ⇔  shouldShield
```

`focusMode` is a manual hold the user starts and stops by tapping the mascot. It
is the clean revival of the "manual blocking" the codebase previously removed
for being a confusing second persistent switch
(`Vibez/ScreenTimeManager.swift:13`) — but reframed as an *intentional momentary
gesture*, not a background toggle that silently ORs with pings forever.

Focus mode and the timed triggers are **independent**: a push that lands during
focus mode still records its trigger / overlay / analytics as usual, and
releasing focus mode only drops the shield if no live trigger remains.

## Approach (chosen: A — OR-flag in `ScreenTimeManager`)

Add a single boolean to the existing shield owner and fold it into the shield
decision. This reuses every existing apply/clear/persist/analytics path and
mirrors exactly how `armed` already works.

Rejected alternatives:

- **B — model focus as a no-expiry synthetic `PendingTrigger`.** Pollutes the
  per-session semantics of `pendingTriggers`, needs a sentinel `sessionId`, and
  would spawn a bogus blocked-overlay with a meaningless countdown.
- **C — a second `ManagedSettingsStore` layered for focus.** Two OS stores to
  reconcile, more failure modes, no upside over a flag.

## State changes — `Vibez/ScreenTimeManager.swift`

- Add stored state:
  - `private(set) var focusMode: Bool = false`
  - `private(set) var focusModeStartedAt: Date?` — drives the elapsed-time
    label; persisted so elapsed survives an app reopen.
- Add derived state:
  - `var shouldShield: Bool { isBlocking || focusMode }`
  - `isBlocking` keeps its current triggers-only meaning. The overlay / trigger
    logic (`shouldEnqueueOverlay`, `handleIncoming`, etc.) continues to read
    `isBlocking` / `pendingTriggers` unchanged.
- Add `func setFocusMode(_ on: Bool)`:
  - Guard `armed` (defensive — the UI only enables the tap when armed).
  - Set `focusMode = on`; set `focusModeStartedAt = on ? Date() : nil`.
  - Persist (see Persistence), then call `recomputeBlocking()` — now reconciling
    against `shouldShield` — to apply/clear the OS shield. Reusing
    `recomputeBlocking` (as `addTrigger` / `resolveTrigger` do) avoids
    duplicating the apply/clear decision; it already always-applies/clears
    without short-circuiting on `shieldApplied`.
  - Turning focus **off** while triggers are still pending leaves the shield up
    (`recomputeBlocking` sees `isBlocking == true`) — correct and intended.
- Swap the shield-decision sites from `isBlocking` → `shouldShield`:
  - `init` reconcile (`let shouldBlock = isBlocking` → `shouldShield`).
  - `updateSelection` (`if isBlocking { applyShield() }` → `if shouldShield`).
  - `recomputeBlocking` (`let shouldBlock = isBlocking` → `shouldShield`).
- `setArmed(false)` is a global stop: also reset `focusMode = false` /
  `focusModeStartedAt = nil` before clearing the shield, and persist. (Focus
  mode requires armed, so disarming must end it.)

## Background correctness — `VibezPushService/NotificationService.swift`

This is the one non-obvious correctness requirement. The NSE runs in its own
process and, on a `shield:off` push, clears the OS shield once no triggers
remain (`NotificationService.swift:178-189`). If focus mode is holding the
shield while Vibez is suspended and a reply (`shield:off`) lands, the NSE would
drop the manual hold.

- Add `static let focusMode = "vibez.focusMode.v1"` to the NSE `Key` enum.
- In `applyShieldState`, read the flag:
  `let focusMode = sharedDefaults?.bool(forKey: Key.focusMode) ?? false`.
- In the `shield == "off"` branch, change:
  - `if triggers.isEmpty { clearShield() }`
  - → `if triggers.isEmpty && !focusMode { clearShield() }`.

No other NSE change. `shield:on` still adds a trigger and applies the shield
(redundant but harmless while focus already holds it). The NSE reads `focusMode`
from App Group `UserDefaults` the same way it already reads `armed` — a path
known to work NSE-side.

## UI / interaction — `Vibez/ContentView.swift` + `Vibez/Mascots.swift`

### Tap target
- Wrap the home-screen `MascotForAgent` (`ContentView.swift:568`) in a tap
  region (`.contentShape(Rectangle())` + `.onTapGesture`) with a heavy haptic,
  matching `BigToggle`'s feedback.
- Tap calls a new `ContentView.toggleFocusMode()`:
  - If **not armed** → no-op (a sleeping mascot ignoring taps reads naturally).
  - If armed but **no apps selected** (`!manager.hasSelection`) → open Settings
    (`showSettings = true`), where the app picker lives, instead of engaging an
    empty shield.
  - Otherwise → `manager.setFocusMode(!manager.focusMode)`.
- The `MascotForAgent` inside `BlockedOverlay` (`BlockedOverlay.swift:115`) is
  **not** made tappable — it keeps the default `focused: false`.

### Mascot pose — `Mascots.swift`
- Add `var focused: Bool = false` to `MascotForAgent`, `ClaudeMascot`, and
  `CodexMascot`. Default `false` keeps `BlockedOverlay` and all previews
  unchanged.
- When `focused`:
  - Pin **determined squint eyes** (reuse the existing `.squint` chevron
    expression) instead of the cycling/sleeping expressions.
  - Stop the auto-cycler by passing `listening: listening && !focused` to
    `ExpressionCycler`, so it doesn't override the pinned expression.

### Focus visuals — `ContentView`
- **Focused state:** a soft, slowly pulsing accent halo behind the mascot, plus
  an accent pill below the ground line reading `Focus mode · MM:SS · tap to
  release`. The elapsed `MM:SS` updates live via `TimelineView`, computed from
  `manager.focusModeStartedAt`. The pill is also tappable to release (a reliable
  hit target in addition to the mascot).
- **Armed-but-idle discoverability hint:** a faint `tap to lock in` one-liner
  under the mascot when armed and not focused, so *entering* focus mode is
  discoverable (the release label only covers exiting). Trimmable if it reads as
  noisy.
- Both treatments animate in/out with the existing easing language and only
  appear in the armed / unlocked layout.

## Persistence & lifecycle

- Add keys:
  - `Key.focusMode = "vibez.focusMode.v1"`
  - `Key.focusModeStartedAt = "vibez.focusModeStartedAt.v1"`
- `persistFocusMode()` writes both to `.standard` **and** the App Group
  `UserDefaults` (mirroring `persistArmed`). `focusMode` is host-authoritative —
  only the mascot tap sets it — so standard → App Group is the correct mirror
  direction.
- Add `Key.focusMode` / `Key.focusModeStartedAt` to:
  - `mirrorAllToAppGroup` (so `init` seeds the App Group for the NSE), and
  - `recoverFromAppGroupIfNeeded` (so the brief App-Group-as-defaults era
    recovers cleanly).
- `init` loads both from `.standard` and uses `shouldShield` for the launch
  reconcile, so a focus hold **survives app kill / device restart** and is
  restored on next launch. (An indefinite manual hold that survives a force-quit
  is the intended behavior — releasing is always one mascot tap away.)
- `tick()` needs no change: `focusMode` never changes from the background, and
  `recomputeBlocking` already keeps the shield up while `shouldShield` is true.

## Analytics — no change

Focus time flows through the existing edges automatically: `applyShield` →
`AnalyticsTracker.noteShieldArmed`, `clearShield` →
`AnalyticsTracker.noteShieldLifted`. Both are idempotent, so a focus hold that
overlaps a real trigger is counted once. Focus time therefore accrues into
today's `focusSeconds` with no new analytics code.

## Edge cases

- **Not armed + tap mascot:** no-op.
- **Armed + no apps selected + tap:** route to Settings (app picker), don't
  engage an empty shield.
- **Toggle off while focused:** `setArmed(false)` ends focus mode and clears the
  shield.
- **Push lands during focus mode:** trigger / overlay / analytics record as
  normal; the shield was already up. Releasing focus later keeps the shield up
  iff a live trigger remains.
- **`shield:off` arrives while suspended + focused:** NSE keeps the shield up
  (the `&& !focusMode` guard).
- **App killed mid-focus:** shield persists (OS-level), focus state restored on
  relaunch.

## Testing

- **Unit / logic (simulator OK):** `setFocusMode(true/false)` flips
  `shouldShield`; `setArmed(false)` resets `focusMode`; persistence round-trips
  `focusMode` + `focusModeStartedAt` across a fresh `ScreenTimeManager`;
  `shouldShield` truth table over `{isBlocking} × {focusMode}`.
- **Compile check:** `xcodebuild` against `iphonesimulator26.4` for both the app
  and the `VibezPushService` target.
- **On device (required for real shielding):**
  1. Arm, tap mascot → selected apps blocked, mascot shows focused pose + pill.
  2. Tap mascot again → apps unblock (no pending triggers).
  3. Focus on, send a real push, reply (`shield:off`) while Vibez is
     backgrounded → apps stay blocked (NSE guard). Release focus → unblock.
  4. Focus on, force-quit Vibez → apps stay blocked; relaunch → focused pose
     restored, tap releases.
  5. Toggle off while focused → unblock.
  6. Armed, no apps selected, tap mascot → Settings opens.
- **Previews:** a `#Preview` with `focusMode == true` to render the focused
  mascot + pill without a device.

## Out of scope (YAGNI)

- Timed / pomodoro focus sessions (we chose indefinite tap-to-release).
- Per-app focus subsets distinct from the main selection.
- Shortcuts / widget / Control Center entry points.
- Pushing focus state to other registered devices.
