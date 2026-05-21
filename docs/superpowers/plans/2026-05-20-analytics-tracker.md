# AnalyticsTracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `AnalyticsTracker` class that records per-day usage stats (distinct conversations, user replies, reply body lengths, total pings) with midnight rollover and UserDefaults persistence.

**Architecture:** Single `@MainActor @Observable` class siblings the existing `TriggerStore` / `IgnoreStore`. Owns a Codable `DailyStats` struct persisted to standard UserDefaults under one key. Midnight rollover is lazy — checked on `init` and at the top of `record(_:)`. Single integration point: one new line at the top of `ContentView.handleIncoming`, before any existing gating.

**Tech Stack:** Swift 6, SwiftUI `@Observable`, `JSONEncoder`/`JSONDecoder`, `UserDefaults`, `Calendar.current.startOfDay(...)`. iOS 26.4 deployment.

**Testing note:** No XCTest target exists in `Vibez.xcodeproj`. "Verify" steps in this plan are manual — `xcodebuild` for compile checks, then simulator runs with a *temporary* debug button added to `ContentView` that synthesizes `NtfyMessage`s and calls `analytics.record(...)` directly. The temp button is reverted before the task closes. `injectFakeMessage` on `NotifyClient` is unwired in the current UI; we don't route through it on purpose — driving the tracker directly is one less indirection.

**Commits:** Steps include `git commit` blocks per the skill's convention. Skip them if Peter says to batch — Peter will tell you when. Don't commit unprompted.

**Reference spec:** `docs/superpowers/specs/2026-05-20-analytics-tracker-design.md`.

---

## File map

Will create:
- `Vibez/AnalyticsTracker.swift` (~75 lines: `DailyStats` struct + `AnalyticsTracker` class)

Will modify:
- `Vibez/ContentView.swift` — one new `@State` declaration alongside the existing stores; one new line at the top of `handleIncoming`

Will NOT modify:
- `Vibez.xcodeproj/project.pbxproj` — the synchronized root group picks up new files automatically (per CLAUDE.md).
- `Vibez/VibezApp.swift` — `ContentView` owns the stores, not the App entry point.
- `Vibez/NotifyClient.swift`, `Vibez/ScreenTimeManager.swift`, `Vibez/TriggerStore.swift`, `Vibez/IgnoreStore.swift`, `VibezShield/*` — the tracker is a passive observer that doesn't cross into any of these.

---

## Task 1: Create `AnalyticsTracker.swift`

**Goal:** Land the new class as a standalone file that compiles. No callers yet — wiring happens in Task 2. Keeping the file self-contained means the build can fail isolated to one source file if anything is wrong.

**Files:**
- Create: `Vibez/AnalyticsTracker.swift`

- [ ] **Step 1: Confirm the target directory and absence of an existing file**

```bash
ls Vibez/AnalyticsTracker.swift 2>&1
```

Expected: `ls: Vibez/AnalyticsTracker.swift: No such file or directory`. If the file already exists, stop and read its contents — somebody started this work already.

- [ ] **Step 2: Create the file with the full class**

Write `Vibez/AnalyticsTracker.swift` with these exact contents:

```swift
//
//  AnalyticsTracker.swift
//  Vibez
//
//  Per-day usage stats: distinct conversations seen, user replies,
//  reply body lengths, total incoming pings. Resets at local midnight
//  on the first event of the new day (lazy — no timer). Persists to
//  standard UserDefaults so today's numbers survive force-quit.
//
//  Not visible to the shield extension. App Group is unused here.
//

import Foundation

struct DailyStats: Codable, Equatable {
    /// Calendar day (startOfDay) these stats are for. Drives midnight rollover.
    var date: Date
    /// Distinct session_ids seen today.
    var conversationIds: Set<String>
    /// Count of `_vibez:event:replied` pings.
    var responseCount: Int
    /// Character count of `NtfyMessage.body` for each `replied` ping, in arrival order.
    var responseLengths: [Int]
    /// Count of all incoming ntfy messages today (any event, including untagged).
    var pingCount: Int

    static func zero(on date: Date) -> DailyStats {
        DailyStats(
            date: date,
            conversationIds: [],
            responseCount: 0,
            responseLengths: [],
            pingCount: 0
        )
    }
}

@MainActor
@Observable
final class AnalyticsTracker {
    private(set) var stats: DailyStats

    private let defaults: UserDefaults
    private let key = "vibez.analytics.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.stats = Self.load(defaults: defaults)
            ?? DailyStats.zero(on: Calendar.current.startOfDay(for: Date()))
        rollIfNeeded()
    }

    /// Feed every incoming ntfy message. Rolls the day first, then folds
    /// the message into today's stats. Safe to call for any message —
    /// untagged pings still increment `pingCount`.
    func record(_ message: NtfyMessage) {
        rollIfNeeded()
        stats.pingCount += 1
        if let sid = message.sessionId, !sid.isEmpty, sid != "nosid" {
            stats.conversationIds.insert(sid)
        }
        if message.event == .replied {
            stats.responseCount += 1
            stats.responseLengths.append(message.body.count)
        }
        save()
    }

    // MARK: - Derived views

    var conversationsToday: Int { stats.conversationIds.count }
    var responsesToday: Int { stats.responseCount }
    var pingsToday: Int { stats.pingCount }
    var averageResponseLength: Double {
        guard !stats.responseLengths.isEmpty else { return 0 }
        let sum = stats.responseLengths.reduce(0, +)
        return Double(sum) / Double(stats.responseLengths.count)
    }

    // MARK: - Rollover

    private func rollIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if stats.date != today {
            stats = DailyStats.zero(on: today)
            save()
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(defaults: UserDefaults) -> DailyStats? {
        guard let data = defaults.data(forKey: "vibez.analytics.v1") else { return nil }
        return try? JSONDecoder().decode(DailyStats.self, from: data)
    }
}
```

A few details worth knowing if you go to modify this:
- `DailyStats.zero(on:)` is a factory so the two construction sites (init fallback + rollover) can't drift.
- `load` uses the literal key string rather than `self.key` because it's `static` and the instance doesn't exist yet — `self.key` would require `let key = "..."` to be `static let key` or threading the value through. Keeping it literal is the smaller change.
- `NtfyMessage`, `VibezEvent.replied` come from `Vibez/NotifyClient.swift`. No additional imports needed.

- [ ] **Step 3: Compile-check for the simulator**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`.

If you see `cannot find 'NtfyMessage' in scope` or `cannot find 'VibezEvent' in scope`: the file isn't in the Vibez target. The project uses a synchronized root group, so a fresh `.swift` file in `Vibez/` should auto-add. Re-check the path is exactly `Vibez/AnalyticsTracker.swift` (capital V, inside the `Vibez` group).

If you see `'replied' is inaccessible due to 'internal' protection level`: the `VibezEvent` enum is `internal` already (no `public` modifier) — both files are in the same module, so this shouldn't fire. Double-check imports.

- [ ] **Step 4: Commit**

```bash
git add Vibez/AnalyticsTracker.swift
git commit -m "AnalyticsTracker: per-day in-app usage stats"
```

---

## Task 2: Wire `AnalyticsTracker` into `ContentView`

**Goal:** Instantiate the tracker and call `record(_:)` from the single ntfy funnel. Per the spec: at the **top** of `handleIncoming`, before any of the existing gating (`shield == .off` early return, `manager.armed` guard, ignore-list handling). That ordering matters — replies and unarmed-state pings still count as activity.

**Files:**
- Modify: `Vibez/ContentView.swift` (around line 13 for the `@State`; around line 290 for the `handleIncoming` body)

- [ ] **Step 1: Add the `@State` property next to the existing stores**

Open `Vibez/ContentView.swift`. Find the block at the top of the struct that looks like:

```swift
struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @State private var notifyClient = NotifyClient()
    @State private var triggerStore = TriggerStore()
    @State private var ignoreStore = IgnoreStore()
```

Insert one new line so it reads:

```swift
struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @State private var notifyClient = NotifyClient()
    @State private var triggerStore = TriggerStore()
    @State private var ignoreStore = IgnoreStore()
    @State private var analytics = AnalyticsTracker()
```

- [ ] **Step 2: Add the `record(_:)` call at the top of `handleIncoming`**

Find `private func handleIncoming(_ message: NtfyMessage) {` (around line 290). The current body starts with:

```swift
    private func handleIncoming(_ message: NtfyMessage) {
        // shield:off (the user just replied in Claude) is a control
        // signal — never surface it as a notification, and only act on
```

Insert `analytics.record(message)` as the very first statement, before the `shield:off` comment block. The result should look like:

```swift
    private func handleIncoming(_ message: NtfyMessage) {
        // Tracker is a passive observer — fires for every incoming
        // message, before any of the gating below. shield:off pings
        // (user replies) and pings that arrive while Vibez is unarmed
        // both still count as activity for today's stats.
        analytics.record(message)

        // shield:off (the user just replied in Claude) is a control
        // signal — never surface it as a notification, and only act on
```

Do **not** move it down next to the `triggerStore.record(...)` call inside `case .on:`. That branch is reached only after the `shield == .off` early return — putting it there would silently miss every reply, which is exactly the thing the user wants to count.

- [ ] **Step 3: Compile-check**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`.

If you see `cannot find 'AnalyticsTracker' in scope`: Task 1's file isn't in the target. See Task 1, Step 3 troubleshooting.

- [ ] **Step 4: Commit**

```bash
git add Vibez/ContentView.swift
git commit -m "ContentView: feed every ntfy message into AnalyticsTracker"
```

---

## Task 3: Manual smoke test on simulator

**Goal:** Confirm the tracker counts the right things, persists across a relaunch, and zeroes out on a day change. There is no XCTest harness; this is the verification. All source edits in this task are temporary debug scaffolding — reverted at the end so the only commits on the branch are the two from Tasks 1 and 2.

**Files:**
- Temporary edit: `Vibez/ContentView.swift` (debug button + sample messages) — reverted in Step 6.

- [ ] **Step 1: Add a temporary debug button to `ContentView`**

This is scaffolding for verification only. You will revert all of it in Step 6.

Find any visible spot in `ContentView`'s `body` — a good place is right above the existing main toggle, inside whichever `VStack`/`ScrollView` already renders the home screen. (If you can't find a clear spot in 30 seconds, drop it inside `body` as the first child of the outermost container — it doesn't have to look pretty.)

Add this block:

```swift
#if DEBUG
Button("Analytics debug: 2× needs-input + 1× replied") {
    let m1 = NtfyMessage(
        id: UUID().uuidString,
        title: "Plan plugin distribution",
        body: "Permission required to run npm install.",
        receivedAt: Date(),
        event: .needsInput,
        shield: .on,
        sessionId: "test-session-A",
        agent: .claude
    )
    let m2 = NtfyMessage(
        id: UUID().uuidString,
        title: "Plan plugin distribution",
        body: "Should I keep going?",
        receivedAt: Date(),
        event: .needsInput,
        shield: .on,
        sessionId: "test-session-A",
        agent: .claude
    )
    let m3 = NtfyMessage(
        id: UUID().uuidString,
        title: "Plan plugin distribution",
        body: "Yes, please proceed.",
        receivedAt: Date(),
        event: .replied,
        shield: .off,
        sessionId: "test-session-A",
        agent: .claude
    )
    analytics.record(m1)
    analytics.record(m2)
    analytics.record(m3)
    print("Analytics after 3 pings: \(analytics.stats)")
}
.padding()
#endif
```

`NtfyMessage`'s memberwise initializer accepts every field as a labeled argument (see `Vibez/NotifyClient.swift`); the `event`/`shield`/`sessionId`/`agent` arguments have defaults so the order above is what compiles.

- [ ] **Step 2: Build for the simulator**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run on a simulator and tap the debug button**

In Xcode: pick any iOS 26.4 simulator → Run. (Family Controls is a no-op in the simulator per CLAUDE.md; the tracker code path doesn't touch Family Controls anyway, so this is fine.)

If a "Connect ntfy" setup card blocks the main UI, paste any junk URL to dismiss it — we're not using the real WebSocket. The debug button should be visible somewhere on the home screen.

Tap **Analytics debug: 2× needs-input + 1× replied** once. Look at the Xcode debug console.

Expected output (the exact field order may vary; the values shouldn't):
```
Analytics after 3 pings: DailyStats(date: <today's startOfDay>, conversationIds: ["test-session-A"], responseCount: 1, responseLengths: [20], pingCount: 3)
```

Why those numbers:
- `pingCount = 3` (one per `record` call).
- `conversationIds = ["test-session-A"]` — all three messages share that session, so the set has one entry.
- `responseCount = 1` — only the third message has `event == .replied`.
- `responseLengths = [20]` — the body `"Yes, please proceed."` is 20 characters.

If `pingCount` is 6 instead of 3, you tapped the button twice or `analytics.record` is being called from both `handleIncoming` *and* the button. The Task 2 wiring shouldn't fire here because the debug button doesn't route through `NotifyClient` — but double-check.

- [ ] **Step 4: Force-quit and relaunch to confirm persistence**

In the simulator: swipe up from the home indicator → swipe Vibez away. Re-launch from the home screen.

You should immediately see the previous run's stats restored. Set a breakpoint at the end of `AnalyticsTracker.init` and `po stats` in lldb — or just read the JSON from defaults:

```
(lldb) po String(data: UserDefaults.standard.data(forKey: "vibez.analytics.v1") ?? Data(), encoding: .utf8) ?? ""
```

Expected: JSON with `pingCount: 3`, `conversationIds: ["test-session-A"]`, `responseCount: 1`, `responseLengths: [20]`. Survived the process kill.

- [ ] **Step 5: Confirm midnight rollover**

In the simulator: Settings → General → Date & Time → turn off **Set Automatically** → bump the date forward one day. Re-launch Vibez.

Set a breakpoint at the end of `AnalyticsTracker.init` and inspect `stats`.

Expected: `stats.date` is the new day's startOfDay; `pingCount = 0`, `conversationIds` is empty, `responseCount = 0`, `responseLengths = []`. The persisted blob in UserDefaults is now the zeroed one — verify with the same `po String(data: …)` from Step 4 if you want.

Restore the simulator date afterwards (Set Automatically → on).

- [ ] **Step 6: Revert the debug scaffolding**

```bash
git diff Vibez/ContentView.swift
```

Confirm the only changes are the Step 1 debug block. Then revert just that file:

```bash
git checkout -- Vibez/ContentView.swift
```

If you also made the Task 2 edits in the same file and committed them, the `checkout` will only drop the uncommitted scaffolding — Tasks 1 and 2 stay on the branch. Double-check with:

```bash
git status
git log --oneline -5
```

Expected: working tree clean. The two top commits are Task 1 (`AnalyticsTracker: …`) and Task 2 (`ContentView: feed every ntfy message…`).

If you see the debug block still in `git diff` after a checkout, you may have committed it by mistake — that means one of the earlier task commits picked it up. Use `git log -p -1 -- Vibez/ContentView.swift` to find which commit, and amend/reset to remove the block before continuing.

---

## Done criteria

- `Vibez/AnalyticsTracker.swift` exists, ~75 lines, builds standalone.
- `ContentView` declares `@State private var analytics = AnalyticsTracker()` alongside the other stores.
- `ContentView.handleIncoming` calls `analytics.record(message)` as its first statement.
- Simulator smoke test (Task 3) showed counts incrementing, persistence across relaunch, and rollover on date change.
- Two commits on the branch (one per Task 1 / Task 2). No extras.
