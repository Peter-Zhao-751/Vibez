# AnalyticsTracker — per-day in-app usage stats

## Problem

Vibez sees a stream of ntfy pings from Claude Code / Codex (sessions, replies, agent prompts) but does nothing with them analytically. There's no in-app sense of "how busy was today" — how many distinct conversations ran, how many times the user actually replied, how long those replies tend to be.

The goal is a small, self-contained tracker that records these counts for the current calendar day and discards them once the day rolls over. No history, no charts, no UI yet — just a class that's collecting the data so it can be surfaced later.

## Goals

- A new `AnalyticsTracker` class (sibling to `TriggerStore`, `IgnoreStore`) that:
  - Counts distinct conversations seen today (unique `sessionId`s).
  - Counts user replies today (ntfy messages with `event == .replied`).
  - Records the body character count of each reply.
  - Counts total incoming ntfy messages today.
- Persists across app kill within the same calendar day.
- Resets at midnight (local time) on the first event of the new day.

## Non-goals

- No UI in this change — `ContentView` only gains the wiring to feed `record(message:)`; no rendering.
- No per-hour, per-week, or historical aggregation. Today only.
- No analytics export over ntfy / HTTP for Mac-side consumption. Future work; the model leaves room but the wire format isn't specified here.
- No Codex-vs-Claude split. The shape is one bucket of counts; splitting is a one-field addition later if needed.
- No background timer for midnight rollover. Rollover is checked lazily at read/write time.

## Approach

### File and wiring

New file: `Vibez/AnalyticsTracker.swift`. Same shape as the other store classes — `@MainActor`, `@Observable`, init takes `defaults: UserDefaults = .standard` for testability symmetry with `TriggerStore`.

`ContentView` already owns all the stores as `@State` (manager, notifyClient, triggerStore, ignoreStore — lines 10–13). It gains one more:

```swift
@State private var analytics = AnalyticsTracker()
```

`VibezApp` is untouched.

### Data model

```swift
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
}
```

`Set<String>` encodes natively via `JSONEncoder` → JSON array. The struct lives inside `AnalyticsTracker.swift` (not a separate file) since it's an implementation detail of one type.

### `AnalyticsTracker` API

```swift
@MainActor
@Observable
final class AnalyticsTracker {
    private(set) var stats: DailyStats

    init(defaults: UserDefaults = .standard)

    /// Feed every incoming ntfy message. Rolls the day first, then folds
    /// the message into today's stats. Safe to call for any message —
    /// untagged pings still increment `pingCount`.
    func record(_ message: NtfyMessage)

    // Derived views
    var conversationsToday: Int      // stats.conversationIds.count
    var responsesToday: Int          // stats.responseCount
    var pingsToday: Int              // stats.pingCount
    var averageResponseLength: Double  // 0 when responseLengths is empty
}
```

`record(_:)`:

```swift
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
```

The `nosid` / empty-string guard mirrors `ScreenTimeManager.addTrigger` so a placeholder session id from older / misconfigured plugins doesn't pollute the conversation count.

### Midnight rollover

Lazy, no timer:

```swift
private func rollIfNeeded() {
    let today = Calendar.current.startOfDay(for: Date())
    if stats.date != today {
        stats = DailyStats(
            date: today,
            conversationIds: [],
            responseCount: 0,
            responseLengths: [],
            pingCount: 0
        )
        save()
    }
}
```

Called from `init()` (so a stats blob loaded from yesterday's UserDefaults gets reset before any read) and from the top of `record(...)`.

Known caveat — written down so the next session doesn't relitigate: if the app sits idle past midnight with no new pings, a UI read of `conversationsToday` would still show yesterday's count until the next event arrives. Acceptable today because there is no UI yet. When a stats screen is added, that screen should call a public `refresh()` (which just runs `rollIfNeeded()`) on scenePhase=.active.

### Persistence

Single UserDefaults key: `"vibez.analytics.v1"`. JSON-encoded `DailyStats`. Same `JSONEncoder` / `JSONDecoder` pattern as `TriggerStore`:

```swift
private let key = "vibez.analytics.v1"

private func save() {
    guard let data = try? JSONEncoder().encode(stats) else { return }
    defaults.set(data, forKey: key)
}

private static func load(defaults: UserDefaults) -> DailyStats? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(DailyStats.self, from: data)
}
```

`init` flow:

```swift
init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.stats = Self.load(defaults: defaults)
        ?? DailyStats(
            date: Calendar.current.startOfDay(for: Date()),
            conversationIds: [],
            responseCount: 0,
            responseLengths: [],
            pingCount: 0
        )
    rollIfNeeded()
}
```

Standard `UserDefaults`, not the App Group suite — the shield extension has no business reading this.

### Integration point

`ContentView.handleIncoming(_ message: NtfyMessage)` is the single funnel for every incoming push. The new call goes at the **top** of that method, before any of the existing gating:

```swift
private func handleIncoming(_ message: NtfyMessage) {
    analytics.record(message)   // ← new, first thing
    // existing logic (shield==.off early return, armed gate,
    // ignoreStore handling, recordTrigger, etc.) unchanged.
    ...
}
```

Placement matters. Existing branches matter for shielding decisions but not for tallying activity:

- `shield == .off` pings (user replies) early-return today. Those are exactly the events we want to count for `responseCount` and `responseLengths`. Calling `analytics.record` first ensures replies are counted before the early return.
- The `manager.armed` gate skips dormant Vibez. We still want to count agent activity that arrived while the toggle was off — that's part of "what happened today."
- Ignored sessions skip shielding/overlay. The conversation still happened, so it still counts.

The analytics tracker is a passive observer of the message stream; armed/ignored are shielding concerns, not tracking concerns.

No changes to `NotifyClient`, `ScreenTimeManager`, `TriggerStore`, or the shield extension.

## What we considered and rejected

- **Event-log model.** Persist every event with timestamp + kind + payload, compute aggregates on demand. More flexible (you can ask "how many between 10am and noon"), but Vibez doesn't need any of that today and the bytes / read cost would grow with traffic.
- **Reuse `TriggerStore`'s capped array shape.** Looks consistent on the surface, but it forces every read to recount the array. Counts are natively counters; modeling them as such keeps reads O(1) and the on-disk size bounded.
- **Per-agent split (claude vs codex).** `etc.` in the original ask covers it, but YAGNI for v1. Adding a `pingsByAgent: [String: Int]` field later is a one-line change in `record(...)` and a Codable extension on `DailyStats`.
- **Midnight timer.** Considered, rejected — lazy rollover is correct for the no-UI-yet case and avoids one more `Task` lifecycle to reason about. Revisit when UI lands.

## Testing

No unit-test target exists in `Vibez.xcodeproj` today. Behavior is verified by:

1. Force-quitting Vibez, relaunching, and confirming `analytics.stats` matches what was persisted (manual print or breakpoint).
2. Sending a fake ntfy message via the existing "Test push" button (`NotifyClient.injectFakeMessage`) and confirming counts update.
3. Setting the system clock forward a day in the simulator and confirming the next `record(...)` resets `stats`.

When a test target is added later, the natural shape is: inject a `UserDefaults(suiteName: ...)` test instance into the initializer, drive `record(...)` with handcrafted `NtfyMessage`s, assert on `stats`.

## File summary

- New: `Vibez/AnalyticsTracker.swift`
- Modified: `Vibez/ContentView.swift` (one `@State` declaration alongside the existing stores, one line at the top of `handleIncoming`)
