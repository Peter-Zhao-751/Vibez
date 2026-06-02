# Vibez Focus Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping the home-screen mascot while Vibez is armed manually shields all selected apps until tapped again, independent of agent pushes.

**Architecture:** Add a host-authoritative `focusMode` flag to `ScreenTimeManager`, OR it into the shield decision (`shouldShield = isBlocking || focusMode`), mirror it to the App Group so the push-service extension won't lift a manual hold on a backgrounded `shield:off`, and surface it on the mascot (determined pose + accent halo + a live `Focus mode · MM:SS · tap to release` pill).

**Tech Stack:** Swift / SwiftUI, FamilyControls + ManagedSettings, App Group `UserDefaults`, a `UNNotificationServiceExtension`.

**Verification model (read before starting):** This project has **no XCTest target**, and the shielding APIs are no-ops in the simulator (device-only). So each task is verified by an **`xcodebuild` compile check** + **SwiftUI preview**, not unit tests, plus a final **on-device checklist**. The files touched (`ScreenTimeManager.swift`, `ContentView.swift`, `NotificationService.swift`, `Components.swift`) carry **pre-existing uncommitted work**, so this plan does **not** auto-commit — changes are left in the working tree for Peter to review and commit (repo rule: commit only when asked).

**Compile command (used by every task):**
```bash
cd /Users/peter/Desktop/Vibez && xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -sdk iphonesimulator26.4 -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected on success: `** BUILD SUCCEEDED **`. (Building the `Vibez` scheme also compiles the embedded `VibezPushService` extension.)

---

## File Structure

- `Vibez/ScreenTimeManager.swift` — **modify.** Owns the shield. Adds `focusMode` state, `shouldShield`, `setFocusMode`, persistence, App-Group mirror, init reconcile, `setArmed` reset, and the `previewManager` knob.
- `VibezPushService/NotificationService.swift` — **modify.** Background push path. Reads `focusMode` and skips `clearShield()` on `shield:off` while a hold is active.
- `Vibez/Mascots.swift` — **modify.** Adds a `focused` pose (determined squint eyes, cycler paused) to `MascotForAgent` / `ClaudeMascot` / `CodexMascot`, plus a preview.
- `Vibez/Components.swift` — **modify.** Adds two reusable views: `FocusPill` (the live status pill) and `FocusHalo` (the pulsing accent glow).
- `Vibez/ContentView.swift` — **modify.** Makes the mascot tappable, adds `toggleFocusMode()`, the `focusStatusLabel`, the halo background, `import UIKit`, and a focus-mode preview.

---

## Task 1: `ScreenTimeManager` — focus-mode state & shield decision

**Files:**
- Modify: `Vibez/ScreenTimeManager.swift`

- [ ] **Step 1: Add the two persistence keys**

In `private enum Key { … }` (after `legacyBlocking`), add:

```swift
        /// Manual focus-mode hold (mascot tap). Host-authoritative;
        /// mirrored to the App Group so VibezPushService won't lift the
        /// shield on a backgrounded shield:off while a hold is active.
        static let focusMode = "vibez.focusMode.v1"
        static let focusModeStartedAt = "vibez.focusModeStartedAt.v1"
```

- [ ] **Step 2: Add stored + derived state**

After the `pendingTriggers` property (just before `var isBlocking: Bool { … }`), add:

```swift
    /// Manual focus hold started by tapping the mascot. ORs with
    /// `isBlocking` to decide the OS shield. Unlike a trigger it has no
    /// timer — it holds until the user taps to release (or disarms).
    private(set) var focusMode: Bool = false
    /// When the current hold began — drives the elapsed-time label.
    /// nil whenever `focusMode` is false.
    private(set) var focusModeStartedAt: Date?
```

After `var isBlocking: Bool { !pendingTriggers.isEmpty }`, add:

```swift
    /// OS shield is up iff a trigger is pending OR a manual focus hold is
    /// active. `isBlocking` keeps its trigger-only meaning for the overlay
    /// layer; this is the shield decision used by init/recompute/setArmed.
    var shouldShield: Bool { isBlocking || focusMode }
```

- [ ] **Step 3: Add `setFocusMode` and `persistFocusMode`**

After `setArmed(_:)` (before the `// MARK: - Per-session pending triggers` section), add:

```swift
    /// Toggles the manual focus hold. Requires `armed` (the UI only
    /// enables the mascot tap when armed; this guard is defensive).
    /// Reconciles the OS shield via `recomputeBlocking`, which now reads
    /// `shouldShield`. Turning focus off while triggers remain leaves the
    /// shield up for them.
    func setFocusMode(_ on: Bool) {
        guard armed else { return }
        guard on != focusMode else { return }
        focusMode = on
        focusModeStartedAt = on ? Date() : nil
        persistFocusMode()
        recomputeBlocking()
    }

    private func persistFocusMode() {
        defaults.set(focusMode, forKey: Key.focusMode)
        sharedDefaults?.set(focusMode, forKey: Key.focusMode)
        if let startedAt = focusModeStartedAt {
            defaults.set(startedAt.timeIntervalSince1970, forKey: Key.focusModeStartedAt)
            sharedDefaults?.set(startedAt.timeIntervalSince1970, forKey: Key.focusModeStartedAt)
        } else {
            defaults.removeObject(forKey: Key.focusModeStartedAt)
            sharedDefaults?.removeObject(forKey: Key.focusModeStartedAt)
        }
    }

    /// Loads the persisted focus hold on launch. A persisted `focusMode`
    /// with no timestamp is normalized to "started now" so a hold that
    /// survived a kill keeps the shield up rather than being dropped.
    private func loadFocusState() {
        focusMode = defaults.bool(forKey: Key.focusMode)
        if focusMode {
            if let ts = defaults.object(forKey: Key.focusModeStartedAt) as? Double {
                focusModeStartedAt = Date(timeIntervalSince1970: ts)
            } else {
                focusModeStartedAt = Date()
            }
        } else {
            focusModeStartedAt = nil
        }
    }
```

- [ ] **Step 4: Reset focus on disarm + use `shouldShield` in `setArmed`**

In `setArmed(_:)`, replace the body so disarm also clears focus and the shield decision uses `shouldShield`:

```swift
    func setArmed(_ on: Bool) {
        armed = on
        if !on {
            pendingTriggers.removeAll()
            focusMode = false
            focusModeStartedAt = nil
        }
        persistArmed()
        persistPendingTriggers()
        persistFocusMode()
        // Force the OS shield to match `shouldShield`. recomputeBlocking
        // would short-circuit when `shieldApplied == shouldBlock`, but
        // VibezPushService engages the shield from its own process without
        // bumping our `shieldApplied`, so this bypass guarantees the user's
        // toggle wins.
        if shouldShield {
            applyShield()
        } else {
            clearShield(reason: "setArmed(\(on))")
        }
        shieldApplied = shouldShield
    }
```

- [ ] **Step 5: Load focus state in `init` and reconcile against `shouldShield`**

In `init()`, add `loadFocusState()` immediately after `loadStateAndMigrate()`:

```swift
        loadSelection()
        loadStateAndMigrate()
        loadFocusState()
        mirrorAllToAppGroup()
```

Then change the launch reconcile from `isBlocking` to `shouldShield`:

```swift
        pruneExpired()
        let shouldBlock = shouldShield
        shieldLog.info("init: armed=\(self.armed, privacy: .public) pending=\(self.pendingTriggers.count, privacy: .public) focus=\(self.focusMode, privacy: .public) → blocking=\(shouldBlock, privacy: .public)")
        if shouldBlock {
            applyShield()
        } else {
            clearShield(reason: "init-sync")
        }
```

- [ ] **Step 6: Mirror focus keys to the App Group**

In `mirrorAllToAppGroup()`, extend the `keys` array:

```swift
        let keys = [
            Key.selection,
            Key.armed,
            Key.focusMode,
            Key.focusModeStartedAt,
        ]
```

- [ ] **Step 7: Add focus keys to the App-Group recovery list**

In `recoverFromAppGroupIfNeeded()`, append to the `keys` array:

```swift
            "vibez.blockSeconds.done",
            "vibez.blockSeconds.needsInput",
            "vibez.focusMode.v1",
            "vibez.focusModeStartedAt.v1",
        ]
```

- [ ] **Step 8: Use `shouldShield` in `updateSelection` and `recomputeBlocking`**

In `updateSelection(_:)` change `if isBlocking { applyShield() }` → `if shouldShield { applyShield() }`.

In `recomputeBlocking()` change `let shouldBlock = isBlocking` → `let shouldBlock = shouldShield`.

- [ ] **Step 9: Extend `previewManager` (DEBUG) with a `focusMode` knob**

In the `#if DEBUG` extension, update `previewManager` signature + body:

```swift
    static func previewManager(
        armed: Bool,
        pendingTriggers: [PendingTrigger] = [],
        authState: AuthState = .authorized,
        focusMode: Bool = false
    ) -> ScreenTimeManager {
        let m = ScreenTimeManager()
        m.armed = armed
        m.pendingTriggers = Dictionary(
            uniqueKeysWithValues: pendingTriggers.map { ($0.sessionId, $0) }
        )
        m.authState = authState
        m.focusMode = focusMode
        m.focusModeStartedAt = focusMode ? Date().addingTimeInterval(-(12 * 60 + 34)) : nil
        return m
    }
```

- [ ] **Step 10: Compile**

Run the compile command from the header. Expected: `** BUILD SUCCEEDED **`.

---

## Task 2: `VibezPushService` — honor focus mode on background `shield:off`

**Files:**
- Modify: `VibezPushService/NotificationService.swift`

- [ ] **Step 1: Add the focus-mode key**

In `private enum Key { … }` (after `shieldState`), add:

```swift
        static let focusMode = "vibez.focusMode.v1"
```

- [ ] **Step 2: Guard the background unblock**

In `applyShieldState(...)`, replace the `if shield == "off"` block with:

```swift
        if shield == "off" {
            guard !session.isEmpty, session != "nosid" else { return }
            var triggers = loadPendingTriggers()
            let before = triggers.count
            triggers.removeAll { $0.sessionId == session }
            savePendingTriggers(triggers)
            // A manual focus hold (mascot tap) keeps the shield up even when
            // no per-session triggers remain. Without this guard, a reply
            // that lands while Vibez is suspended would lift a hold the user
            // set by hand.
            let focusMode = sharedDefaults?.bool(forKey: Key.focusMode) ?? false
            if triggers.isEmpty && !focusMode {
                clearShield()
            }
            log.info("shield=off: \(session, privacy: .public) (\(before, privacy: .public)→\(triggers.count, privacy: .public)) focus=\(focusMode, privacy: .public)")
            return
        }
```

- [ ] **Step 3: Compile**

Run the compile command from the header. Expected: `** BUILD SUCCEEDED **`.

---

## Task 3: `Mascots` — the focused pose

**Files:**
- Modify: `Vibez/Mascots.swift`

- [ ] **Step 1: Thread `focused` through `MascotForAgent`**

Replace the `MascotForAgent` struct body:

```swift
struct MascotForAgent: View {
    let agent: Agent
    let listening: Bool
    let size: CGFloat
    var gap: CGFloat = 6
    var focused: Bool = false

    var body: some View {
        switch agent {
        case .claude:
            ClaudeMascot(listening: listening, size: size, focused: focused)
        case .codex:
            CodexMascot(listening: listening, size: size, focused: focused)
        case .both:
            HStack(alignment: .bottom, spacing: gap) {
                ClaudeMascot(listening: listening, size: size * 0.78, focused: focused)
                CodexMascot(listening: listening, size: size * 0.78, focused: focused)
            }
        }
    }
}
```

- [ ] **Step 2: Pin determined eyes on `ClaudeMascot` when focused**

Add `var focused: Bool = false` under `let size: CGFloat`. Then change the eyes line and the cycler modifier:

```swift
            ClaudeEyes(expression: focused ? .squint : (listening ? expression : .blink), color: dark)
```

```swift
        .modifier(ExpressionCycler(listening: listening && !focused, expression: $expression))
```

- [ ] **Step 3: Pin determined eyes on `CodexMascot` when focused**

Add `var focused: Bool = false` under `let size: CGFloat`. Then change the eyes call and the cycler modifier:

```swift
            CodexEyes(
                expression: focused ? .squint : (listening ? expression : .open),
                color: eyeColor,
                listening: listening
            )
```

```swift
        .modifier(ExpressionCycler(listening: listening && !focused, expression: $expression))
```

- [ ] **Step 4: Add a focused-pose preview**

At the end of the file add:

```swift
#if DEBUG
#Preview("Mascot · focused") {
    HStack(spacing: 28) {
        VStack { ClaudeMascot(listening: true, size: 110); Text("listening").font(.caption2) }
        VStack { ClaudeMascot(listening: true, size: 110, focused: true); Text("focused").font(.caption2) }
        VStack { CodexMascot(listening: true, size: 110, focused: true); Text("focused").font(.caption2) }
    }
    .padding()
    .preferredColorScheme(.dark)
}
#endif
```

- [ ] **Step 5: Compile + preview**

Run the compile command. Expected: `** BUILD SUCCEEDED **`. In Xcode, open the `Mascot · focused` preview and confirm the focused mascots show fixed chevron/squint eyes and no blink-cycling.

---

## Task 4: `Components` — `FocusPill` + `FocusHalo`

**Files:**
- Modify: `Vibez/Components.swift`

- [ ] **Step 1: Add the two views**

Append to `Vibez/Components.swift`:

```swift
// MARK: - Focus mode

/// Live status pill shown under the mascot while a manual focus hold is
/// active. Ticks the elapsed time once a second and is itself a tap target
/// to release the hold.
struct FocusPill: View {
    let startedAt: Date?
    let theme: Theme
    var onTap: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .bold))
                Text("Focus mode")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .tracking(1)
                Text("·").opacity(0.6)
                Text(elapsed(now: context.date))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                Text("· tap to release")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .opacity(0.85)
            }
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.accent))
        }
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .accessibilityLabel("Focus mode active. Double tap to release.")
    }

    private func elapsed(now: Date) -> String {
        guard let startedAt else { return "0:00" }
        let total = max(0, Int(now.timeIntervalSince(startedAt)))
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Soft pulsing accent glow placed behind the mascot while focused.
/// Purely decorative — never eats taps.
struct FocusHalo: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.45), color.opacity(0.0)],
                    center: .center,
                    startRadius: 2,
                    endRadius: 110
                )
            )
            .frame(width: 220, height: 220)
            .scaleEffect(pulse ? 1.08 : 0.92)
            .opacity(pulse ? 0.9 : 0.55)
            .blur(radius: 8)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .allowsHitTesting(false)
    }
}
```

- [ ] **Step 2: Compile**

Run the compile command. Expected: `** BUILD SUCCEEDED **`. (The views are unused until Task 5 — that compiles fine.)

---

## Task 5: `ContentView` — wire up the tap, label, halo & preview

**Files:**
- Modify: `Vibez/ContentView.swift`

- [ ] **Step 1: Import UIKit for haptics**

At the top, after `import FamilyControls`, add:

```swift
import UIKit
```

- [ ] **Step 2: Make the mascot tappable, focused, haloed, and add the status label**

In `homeContent(...)`, replace the mascot `VStack(spacing: 1.5) { … }` block (the one containing `MascotForAgent` and the ground-line `Rectangle`) plus its trailing `.frame/.padding` chain with:

```swift
            VStack(spacing: 1.5) {
                MascotForAgent(
                    agent: agent,
                    listening: manager.armed,
                    size: mascotSize(for: availableHeight),
                    gap: 4,
                    focused: manager.focusMode
                )
                .offset(y: mascotOffset())
                .background {
                    if manager.focusMode {
                        FocusHalo(color: theme.accent)
                    }
                }

                // Ground line — solid, ~60% of available width, sits
                // just under the mascot's feet so it reads as standing
                // on the ground. Tints to the accent while focused.
                Rectangle()
                    .fill(manager.focusMode ? theme.accent.opacity(0.85) : theme.fgMute.opacity(0.45))
                    .frame(width: availableWidth * 0.6, height: 1.5)
            }
            .frame(
                height: mascotFrameHeight(for: availableHeight),
                alignment: unlockedLayoutExpanded ? .center : .bottom
            )
            .padding(.horizontal, 10)
            .padding(.top, unlockedLayoutExpanded ? 0 : 8)
            .padding(.bottom, unlockedLayoutExpanded ? 0 : 18)
            .contentShape(Rectangle())
            .onTapGesture { toggleFocusMode() }

            focusStatusLabel
```

- [ ] **Step 3: Add the `focusStatusLabel` view + `toggleFocusMode()`**

After the `homeContent(...)` function (near `mascotOffset()`), add:

```swift
    @ViewBuilder
    private var focusStatusLabel: some View {
        if manager.focusMode {
            FocusPill(
                startedAt: manager.focusModeStartedAt,
                theme: theme,
                onTap: { toggleFocusMode() }
            )
            .padding(.top, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if manager.armed {
            Text("tap to lock in")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(theme.fgFaint)
                .padding(.top, 8)
                .transition(.opacity)
        }
    }

    /// Tap the mascot to start/stop a manual focus hold. Only meaningful
    /// while armed. With no apps selected, route to Settings so the user
    /// can pick apps rather than engage an empty shield.
    private func toggleFocusMode() {
        guard manager.armed else { return }
        guard manager.hasSelection else {
            showSettings = true
            return
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            manager.setFocusMode(!manager.focusMode)
        }
    }
```

- [ ] **Step 4: Add a focus-mode preview**

Update `previewContent(...)` (DEBUG) to accept and forward `focusMode`. Change its signature to add `focusMode: Bool = false,` (e.g. after `armed: Bool = true,`) and pass it into `ScreenTimeManager.previewManager`:

```swift
        manager: ScreenTimeManager.previewManager(
            armed: armed,
            pendingTriggers: pendingTriggers,
            focusMode: focusMode
        ),
```

Then add a new preview after `#Preview("Armed · listening · dark")`:

```swift
#Preview("Focus mode · dark") {
    // Armed and holding a manual focus block: determined mascot, accent
    // halo + ground line, and the live "Focus mode · MM:SS · tap to
    // release" pill. No triggers — the shield is held by the tap alone.
    previewContent(
        armed: true,
        focusMode: true,
        analytics: previewAnalytics(pings: 0, chats: 0, replies: 0)
    )
}
```

- [ ] **Step 5: Compile + preview**

Run the compile command. Expected: `** BUILD SUCCEEDED **`. Open the `Focus mode · dark` preview: determined mascot, pulsing halo, accent ground line, and a ticking `Focus mode · 12:34 · tap to release` pill. Open `Armed · listening · dark`: faint `tap to lock in` under the mascot, no pill/halo.

---

## Task 6: Integration verification

**Files:** none (verification only).

- [ ] **Step 1: Full compile of all targets**

Run the compile command from the header. Expected: `** BUILD SUCCEEDED **` (covers `Vibez` + embedded `VibezPushService`). Also build the shield extension scheme:

```bash
cd /Users/peter/Desktop/Vibez && xcodebuild -project Vibez.xcodeproj -scheme VibezShield \
  -sdk iphonesimulator26.4 -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

- [ ] **Step 2: On-device checklist (Peter runs on iPhone)**

Document for Peter to run on hardware (shielding is a simulator no-op):

1. Arm Vibez, tap the mascot → selected apps blocked; mascot shows determined pose + halo + pill.
2. Tap the mascot (or pill) again → apps unblock (no pending triggers).
3. Focus on; send a real push and reply (`shield:off`) while Vibez is backgrounded → apps stay blocked; release focus → unblock.
4. Focus on; force-quit Vibez → apps stay blocked; relaunch → focused pose restored; tap releases.
5. Toggle Vibez off while focused → apps unblock, pill disappears.
6. Armed with **no** apps selected, tap mascot → Settings opens (no empty shield).

- [ ] **Step 3: Hand off**

Summarize the diff for Peter and note that commits are intentionally deferred (working tree has pre-existing WIP in several of these files).

---

## Self-Review notes

- **Spec coverage:** state model → Task 1; NSE guard → Task 2; mascot pose → Task 3; pill/halo → Task 4; tap + label + hint + no-selection routing + preview → Task 5; persistence/init/mirror/recover → Task 1 (steps 1,3,5,6,7); analytics → unchanged (flows through existing `applyShield`/`clearShield`, noted in spec). All covered.
- **Type consistency:** `focusMode: Bool`, `focusModeStartedAt: Date?`, `shouldShield: Bool`, `setFocusMode(_:)`, `FocusPill(startedAt:theme:onTap:)`, `FocusHalo(color:)`, `MascotForAgent(…, focused:)` used identically across tasks.
- **No placeholders:** every code step contains full code.
