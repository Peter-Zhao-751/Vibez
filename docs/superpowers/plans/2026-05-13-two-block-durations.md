# Two block durations + countdown + overlay stack — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split block duration into needs-input (15 min default) vs done (30 s default), add a live countdown to `BlockedOverlay`, auto-dismiss on expiry, and turn the overlay into a stack that pops to the next-most-recent unresolved block when the top is dismissed.

**Architecture:** Two new `AppStorage` keys with a one-shot UserDefaults migration. `ContentView` picks the duration per `message.event` and maintains an ordered `overlayQueue: [NtfyMessage]`. `BlockedOverlay` derives its countdown from `manager.pendingTriggers[sid].expiresAt` (single source of truth) and shows a "+N more" pill when stack depth > 1. Crossfade between stacked entries via `.id(msg.id) + .transition(.opacity)`.

**Tech Stack:** SwiftUI, `@AppStorage`, `@Observable`, `TimelineView` for the countdown ticker.

**Note on testing:** No XCTest target exists in the Vibez project; verification is `xcodebuild -scheme Vibez -destination 'generic/platform=iOS Simulator' -quiet build` for compile-cleanliness, and the change is only fully observable on a real device per `CLAUDE.md`. Tasks below are structured as implement-then-build-check rather than failing-test-first.

---

### Task 1: One-shot migration of `vibez.blockSeconds`

**Files:**
- Modify: `Vibez/VibezApp.swift`

- [ ] **Step 1: Add migration helper to `VibezApp.init`**

```swift
@main
struct VibezApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.migrateBlockSecondsKey()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    /// One-shot migration: split the legacy single `vibez.blockSeconds`
    /// (1800 default) into separate needs-input + done keys, seeding both
    /// from the previous value. Reads UserDefaults directly so we don't
    /// register a SwiftUI dependency on a key we're about to delete.
    private static func migrateBlockSecondsKey() {
        let defaults = UserDefaults.standard
        let legacyKey = "vibez.blockSeconds"
        guard let legacy = defaults.object(forKey: legacyKey) as? Int else { return }
        if defaults.object(forKey: "vibez.blockSeconds.needsInput") == nil {
            defaults.set(legacy, forKey: "vibez.blockSeconds.needsInput")
        }
        if defaults.object(forKey: "vibez.blockSeconds.done") == nil {
            defaults.set(legacy, forKey: "vibez.blockSeconds.done")
        }
        defaults.removeObject(forKey: legacyKey)
    }
}
```

- [ ] **Step 2: Verify Xcode picks up the change** — file is in `PBXFileSystemSynchronizedRootGroup`, no project edit needed.

---

### Task 2: SettingsView — split the slider into two

**Files:**
- Modify: `Vibez/SettingsView.swift`

- [ ] **Step 1: Replace `blockSeconds` AppStorage with two keys**

In `SettingsView`, replace:
```swift
@AppStorage("vibez.blockSeconds") private var blockSeconds = 1800
```
with:
```swift
@AppStorage("vibez.blockSeconds.needsInput") private var blockSecondsNeedsInput = 900
@AppStorage("vibez.blockSeconds.done") private var blockSecondsDone = 30
```

- [ ] **Step 2: Replace `durationSection` body and helpers**

Replace the existing `durationSection`, `durationIndexBinding`, and `closestStopIndex` with two-row variants:

```swift
@ViewBuilder
private var durationSection: some View {
    Section {
        durationRow(label: "Needs input", value: $blockSecondsNeedsInput)
        durationRow(label: "Done",        value: $blockSecondsDone)
    } header: {
        Text("Block duration")
    } footer: {
        Text("Needs input: how long apps stay blocked while Claude is waiting on you. Done: how long after Claude wraps a turn that doesn't need you.")
    }
}

@ViewBuilder
private func durationRow(label: String, value: Binding<Int>) -> some View {
    VStack(spacing: 8) {
        HStack {
            Text(label)
            Spacer()
            Text(formatDuration(value.wrappedValue))
                .monospaced()
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
        Slider(
            value: durationIndexBinding(for: value),
            in: 0...Double(durationStops.count - 1),
            step: 1
        ) {
            Text(label)
        } minimumValueLabel: {
            Text("5s").font(.caption2.monospaced()).foregroundStyle(.tertiary)
        } maximumValueLabel: {
            Text("1h").font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
    }
}

private func durationIndexBinding(for value: Binding<Int>) -> Binding<Double> {
    Binding(
        get: {
            let idx = durationStops.firstIndex(of: value.wrappedValue)
                ?? closestStopIndex(to: value.wrappedValue)
            return Double(idx)
        },
        set: { newValue in
            value.wrappedValue = durationStops[Int(newValue.rounded())]
        }
    )
}

private func closestStopIndex(to seconds: Int) -> Int {
    var best = 0
    var bestDelta = Int.max
    for (i, s) in durationStops.enumerated() {
        let d = abs(s - seconds)
        if d < bestDelta { bestDelta = d; best = i }
    }
    return best
}
```

---

### Task 3: ContentView — replace single `blockSeconds` with two keys + dispatcher

**Files:**
- Modify: `Vibez/ContentView.swift`

- [ ] **Step 1: Swap the AppStorage line**

Replace:
```swift
@AppStorage("vibez.blockSeconds") private var blockSeconds = 1800
```
with:
```swift
@AppStorage("vibez.blockSeconds.needsInput") private var blockSecondsNeedsInput = 900
@AppStorage("vibez.blockSeconds.done") private var blockSecondsDone = 30
```

- [ ] **Step 2: Add the per-message duration helper**

Add inside `ContentView`:
```swift
private func durationFor(_ msg: NtfyMessage) -> Int {
    switch msg.event {
    case .done:                 return blockSecondsDone
    case .needsInput, .replied: return blockSecondsNeedsInput
    case .none:                 return blockSecondsNeedsInput  // untagged third-party producer
    }
}
```

- [ ] **Step 3: Use it at both call sites**

In `recordTrigger(from:)`, change:
```swift
blockSeconds: blockSeconds,
```
to:
```swift
blockSeconds: durationFor(message),
```

In `handleIncoming` `case .on`, change:
```swift
manager.addTrigger(sessionId: sid, durationSeconds: blockSeconds)
```
to:
```swift
manager.addTrigger(sessionId: sid, durationSeconds: durationFor(message))
```

---

### Task 4: BlockedOverlay — countdown + onExpire

**Files:**
- Modify: `Vibez/BlockedOverlay.swift`

- [ ] **Step 1: Extend the struct's stored properties**

Replace the existing field block with:
```swift
struct BlockedOverlay: View {
    let agent: Agent
    let theme: Theme
    let dark: Bool
    var message: NtfyMessage?
    var expiresAt: Date?              // nil = no auto-dismiss (untagged pings)
    let stackDepth: Int               // number of overlays in queue, including this one
    let onDismiss: () -> Void
    let onExpire: () -> Void

    @State private var appeared = false
    @State private var fired = false
```

- [ ] **Step 2: Add countdown-formatting helper**

Add inside the struct:
```swift
private func formatRemaining(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60
    let s = seconds % 60
    return String(format: "%d:%02d", m, s)
}

private func remainingSeconds(now: Date) -> Int {
    guard let expiresAt else { return 0 }
    return max(0, Int(expiresAt.timeIntervalSince(now)))
}
```

- [ ] **Step 3: Insert countdown view between the body text and the Dismiss button**

Locate the existing `Text(.init(bodyText))` block and insert immediately after it (and before the commented-out "Open" button section):

```swift
if expiresAt != nil {
    TimelineView(.periodic(from: .now, by: 1)) { context in
        let remaining = remainingSeconds(now: context.date)
        Text(formatRemaining(remaining))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.fgMute)
            .padding(.bottom, 18)
            .onChange(of: remaining) { _, new in
                if new == 0 && !fired {
                    fired = true
                    onExpire()
                }
            }
    }
}
```

`.onChange(of: remaining)` inside the `TimelineView` body fires when the periodic re-render produces a new value — that's the same trigger that drives the visible countdown, so the auto-dismiss happens on the same tick the user sees `0s`.

- [ ] **Step 4: No changes to existing Dismiss button or `appeared` animation.**

---

### Task 5: ContentView — overlayQueue stack

**Files:**
- Modify: `Vibez/ContentView.swift`

- [ ] **Step 1: Replace `overlayMessage` with the queue**

Replace:
```swift
@State private var overlayMessage: NtfyMessage?
```
with:
```swift
@State private var overlayQueue: [NtfyMessage] = []   // newest first
```

Add computed accessor immediately below it:
```swift
private var topOverlayMessage: NtfyMessage? { overlayQueue.first }
```

- [ ] **Step 2: Replace `dismissOverlay(for:)` with three helpers**

Delete the existing `private func dismissOverlay(for message: NtfyMessage)` and replace with:

```swift
/// Tap Dismiss on the top overlay: resolve its trigger and pop. The
/// next-most-recent unresolved block (if any) takes its place.
private func dismissTopOverlay() {
    guard let msg = overlayQueue.first else { return }
    if let sid = msg.sessionId, !sid.isEmpty, sid != "nosid" {
        manager.resolveTrigger(sessionId: sid)
        triggerStore.clearNeedsReply(forSession: sid)
    }
    withAnimation(.easeInOut(duration: 0.32)) {
        overlayQueue.removeFirst()
    }
}

/// Countdown on the top overlay reached 0. Trigger has already
/// auto-pruned in ScreenTimeManager; just clear the recent-trigger dot
/// and pop.
private func expireTopOverlay() {
    guard let msg = overlayQueue.first else { return }
    if let sid = msg.sessionId, !sid.isEmpty, sid != "nosid" {
        triggerStore.clearNeedsReply(forSession: sid)
    }
    withAnimation(.easeInOut(duration: 0.32)) {
        overlayQueue.removeFirst()
    }
}

/// Push a fresh ping onto the stack. If a queue entry exists with the
/// same sessionId, remove it first — the new ping carries the latest
/// state of that conversation, so it should replace the old entry and
/// jump to the top.
private func enqueueOverlay(_ message: NtfyMessage) {
    if let sid = message.sessionId, !sid.isEmpty, sid != "nosid" {
        overlayQueue.removeAll { $0.sessionId == sid }
    }
    overlayQueue.insert(message, at: 0)
}
```

- [ ] **Step 3: Update `handleIncoming` to use the queue**

In the `shield: .off` branch, replace:
```swift
if let current = overlayMessage,
   current.sessionId == message.sessionId {
    withAnimation { overlayMessage = nil }
}
```
with:
```swift
if let sid = message.sessionId {
    withAnimation(.easeInOut(duration: 0.32)) {
        overlayQueue.removeAll { $0.sessionId == sid }
    }
}
```

In `case .on:`, replace:
```swift
withAnimation(.easeOut(duration: 0.45)) {
    overlayMessage = message
}
```
with:
```swift
withAnimation(.easeInOut(duration: 0.32)) {
    enqueueOverlay(message)
}
```

In `case .none:`, replace:
```swift
withAnimation(.easeOut(duration: 0.45)) {
    overlayMessage = message
}
```
with:
```swift
withAnimation(.easeInOut(duration: 0.32)) {
    enqueueOverlay(message)
}
```

- [ ] **Step 4: Update the overlay rendering site in `body`**

Replace:
```swift
if let msg = overlayMessage {
    BlockedOverlay(
        agent: agent,
        theme: theme,
        dark: effectiveDark,
        message: msg,
        onDismiss: { dismissOverlay(for: msg) }
    )
    .zIndex(5)
}
```
with:
```swift
if let msg = topOverlayMessage {
    BlockedOverlay(
        agent: agent,
        theme: theme,
        dark: effectiveDark,
        message: msg,
        expiresAt: msg.sessionId.flatMap { manager.pendingTriggers[$0]?.expiresAt },
        stackDepth: overlayQueue.count,
        onDismiss: dismissTopOverlay,
        onExpire: expireTopOverlay
    )
    .id(msg.id)
    .transition(.opacity.combined(with: .scale(scale: 0.97)))
    .zIndex(5)
}
```

- [ ] **Step 5: Add the reconciliation observer**

In the `.onChange(of: notifyClient.lastMessage)` chain area (just after it is fine), add:

```swift
.onChange(of: manager.pendingTriggers) { _, newPending in
    // A non-top entry's per-session timer expired in the background.
    // Drop those queue entries so popping the top doesn't reveal a
    // stale entry that would immediately fire onExpire. Untagged
    // pings (nil sessionId) aren't reconciled — they have no backing
    // trigger and are removed only by the Dismiss button.
    overlayQueue.removeAll { msg in
        guard let sid = msg.sessionId, !sid.isEmpty, sid != "nosid"
        else { return false }
        return newPending[sid] == nil
    }
}
```

---

### Task 6: BlockedOverlay — "+N more" stack-depth pill

**Files:**
- Modify: `Vibez/BlockedOverlay.swift`

- [ ] **Step 1: Add the pill subview at the top of the ZStack**

Inside the `body`'s top-level `ZStack(alignment: .top)`, add a third child after the existing background and main `VStack`:

```swift
if stackDepth > 1 {
    HStack {
        Spacer()
        Text("+\(stackDepth - 1) more")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(theme.fgMute)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.fgMute.opacity(0.10))
            )
            .padding(.trailing, 18)
            .padding(.top, 14)
    }
}
```

The pill sits in the top safe area, top-right, mute palette. Stays clear of the centered hero stack.

---

### Task 7: Compile check

- [ ] **Step 1: Build for the iOS simulator**

```bash
cd /Users/peter/Desktop/Vibez && xcodebuild -scheme Vibez -destination 'generic/platform=iOS Simulator' -quiet build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`. Any warnings/errors must be fixed before commit. Family Controls runtime behavior is not exercised by this build — that's a manual on-device check.

---

### Task 8: Commit

- [ ] **Step 1: Stage and commit**

```bash
cd /Users/peter/Desktop/Vibez && git add Vibez/BlockedOverlay.swift Vibez/ContentView.swift Vibez/SettingsView.swift Vibez/VibezApp.swift docs/superpowers/specs/2026-05-13-two-block-durations-design.md docs/superpowers/plans/2026-05-13-two-block-durations.md && git commit -m "$(cat <<'EOF'
overlay: two block durations, live countdown, stack semantics

- Split vibez.blockSeconds into needsInput (15m) and done (30s) AppStorage
  keys. One-shot migration in VibezApp.init seeds both from the legacy
  value so existing configs aren't lost.
- BlockedOverlay shows a live countdown bound to PendingTrigger.expiresAt
  (single source of truth between visible timer and shield lifetime).
  Auto-dismisses when the timer hits 0.
- Multiple simultaneous blocks now stack: dismiss/expire pops the top and
  the next-most-recent unresolved block takes its place. A "+N more" pill
  in the top-right shows stack depth.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

Note: do NOT commit `Vibez/ContentView.swift` etc. that may have unrelated working-tree changes from the user's session. Inspect with `git diff --stat` first.
