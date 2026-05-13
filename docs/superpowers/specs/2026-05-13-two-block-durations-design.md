# Two block durations + countdown on the BlockedOverlay

## Problem

Today there's one `vibez.blockSeconds` setting (default 1800), used for every incoming ping regardless of whether it's `— needs you` or `— done`. That conflates two very different lifetimes:

- **needs-input**: Claude is parked on a reply. You probably want a longer block (typical: 15 min) so you don't drift back to TikTok while the agent waits.
- **done**: Claude finished a turn that doesn't appear to need you. The block should be short (typical: 30 s) — long enough to nudge you into checking the result, not long enough to feel punitive.

Secondarily, `BlockedOverlay` shows the message but no remaining time, and never auto-dismisses. If you ignore it, it just sits there until you tap Dismiss, even though the underlying `PendingTrigger` has already expired in `ScreenTimeManager`. The overlay and the shield drift out of sync.

## Goal

Four changes, kept narrow:

1. Two separate AppStorage defaults for block duration — needs-input vs done — selected at trigger time by `message.event`.
2. `BlockedOverlay` shows a live countdown bound to the underlying `PendingTrigger.expiresAt` so the visible timer is the same clock as the actual shield lifetime.
3. The overlay auto-dismisses when the countdown reaches 0, regardless of which event type produced it. The shield has already lifted by then (per-session timer in `ScreenTimeManager` is the source of truth); the visual dismiss just keeps the two in sync.
4. The overlay becomes a **stack**. When multiple sessions are blocking simultaneously, the newest sits on top; dismissing/expiring the top reveals the next-most-recent unresolved block underneath. A subtle visual cue indicates depth so the user understands the new overlay isn't a fresh ping.

Non-goals: changing how `pendingTriggers` are pruned in `ScreenTimeManager`, per-event UI styling beyond the countdown, or changing the "Dismiss" button behavior.

## Approach

### Settings: split `vibez.blockSeconds` into two keys

Remove `vibez.blockSeconds` (1800). Add:

- `vibez.blockSeconds.needsInput` — default `900` (15 min)
- `vibez.blockSeconds.done` — default `30`

One-shot migration runs from `VibezApp.init` (before any `@AppStorage` reads): peek `UserDefaults.standard.object(forKey: "vibez.blockSeconds")` directly. If non-nil and either new key is absent, seed both new keys from it, then delete the old key. This means existing users who had 1h get 1h for both events on the first run; they can split them in Settings. Reading the raw key (rather than via `@AppStorage`) avoids registering a SwiftUI dependency on a key we're about to delete.

`SettingsView` swaps the single duration row for two rows in the same Section ("Block duration"), each with its own slider over the existing `durationStops` ladder. Section footer updates: "Needs input: how long apps stay blocked while Claude is waiting on you. Done: how long after Claude wraps a turn that doesn't need you."

### Dispatch: pick the duration in `handleIncoming`

ContentView already reads `blockSeconds` once and passes it to both `addTrigger(...)` and `TriggerEvent.blockSeconds` (for the Recent triggers history). Replace with a per-message lookup:

```swift
private func durationFor(_ msg: NtfyMessage) -> Int {
    switch msg.event {
    case .done:        return blockSecondsDone
    case .needsInput:  return blockSecondsNeedsInput
    case .replied, nil: return blockSecondsNeedsInput  // safe default
    }
}
```

Use the result in both call sites (`addTrigger` and `TriggerEvent` construction).

`.replied` is unreachable on this code path (it would mean `shield: .off`, which short-circuits earlier). `nil` is reached only by untagged third-party producers; we default to needsInput because that's the more conservative choice for an unknown push.

### Overlay: countdown bound to the pending trigger

Pass the trigger's `expiresAt` into `BlockedOverlay` as an optional `Date`. The overlay's existing `appeared` state stays; add two new params and one guard flag:

```swift
struct BlockedOverlay: View {
    // existing fields …
    var expiresAt: Date?              // nil = no auto-dismiss (untagged pings without a sid)
    let onDismiss: () -> Void
    let onExpire: () -> Void          // fired when countdown hits 0

    @State private var fired = false  // ensures onExpire is called at most once
    // …
}
```

Implementation can use either `TimelineView(.periodic(from: …, by: 1))` (re-renders the countdown subview once a second, no manual ticker) or `Timer.publish(every: 1, on: .main, in: .common).autoconnect()` driving an `@State var now = Date()`. Either is fine — pick whichever reads cleaner during implementation.

`remainingSeconds` = `max(0, Int(expiresAt.timeIntervalSince(.now)))`. Display sits right under the existing body text, monospaced, in the same `theme.fgMute` palette as the body so it doesn't shout. Format: `m:ss` while ≥ 60 s, `Ns` while < 60 s. Hidden when `expiresAt == nil`.

When `remainingSeconds` reaches 0 AND `expiresAt != nil` AND `!fired`: set `fired = true` and call `onExpire()`. The flag prevents double-fire if the timer source ticks again before the parent removes the overlay.

`onExpire` in ContentView: same body as `dismissOverlay(for:)` — the trigger has already auto-expired in `ScreenTimeManager`, so we just clear the overlay and the `needsReply` flag on the Recent triggers row.

### Overlay stack: newest on top, pop on dismiss

ContentView replaces the single `overlayMessage: NtfyMessage?` with an ordered queue:

```swift
@State private var overlayQueue: [NtfyMessage] = []   // newest first
private var topOverlayMessage: NtfyMessage? { overlayQueue.first }
```

**Push (incoming `shield: .on`):** if a queue entry already exists with the same `sessionId`, remove it. Then `overlayQueue.insert(msg, at: 0)`. This makes a re-ping for the same session jump back to the top with refreshed contents (matches the existing `pendingTriggers` overwrite semantics).

**Pop (Dismiss button OR countdown expire):** `overlayQueue.removeFirst()`. The underlying trigger is resolved (Dismiss path) or has already auto-pruned (Expire path) — same as today.

**External resolution (`shield: .off` push):** `overlayQueue.removeAll { $0.sessionId == replied_sid }`. Removes the entry whether it was on top or buried.

**Reconciliation with `pendingTriggers`:** `.onChange(of: manager.pendingTriggers)` removes any queue entry whose sessionId is no longer in `pendingTriggers`. Catches the case where a non-top entry's per-session timer expires in the background — without this, dismissing the top would reveal a stale entry that immediately fires `onExpire`. (No-op for queue entries with nil sessionId — untagged pings don't have backing triggers.)

**Untagged pings** (no sessionId, no pending trigger): still pushed onto the queue. They render with no countdown and no auto-dismiss; only the Dismiss button removes them. Reconciliation skips them.

### How ContentView wires it up

```swift
if let msg = topOverlayMessage {
    BlockedOverlay(
        agent: agent,
        theme: theme,
        dark: effectiveDark,
        message: msg,
        expiresAt: msg.sessionId.flatMap { manager.pendingTriggers[$0]?.expiresAt },
        stackDepth: overlayQueue.count,        // for the depth indicator
        onDismiss: { dismissTopOverlay() },
        onExpire: { expireTopOverlay() }
    )
    .id(msg.id)                                // forces SwiftUI to treat each top-of-stack as a distinct view
    .transition(.opacity.combined(with: .scale(scale: 0.97)))
    .zIndex(5)
}
```

`.animation(.easeInOut(duration: 0.32), value: topOverlayMessage?.id)` is applied to the parent `ZStack`. Combined with `.id(msg.id)` and the `.transition`, popping the top crossfades to the next entry — and dismissing the last one fades to nothing.

### Stack-depth indicator

`BlockedOverlay` gains `let stackDepth: Int`. When `stackDepth > 1`, render a small pill in the top-right corner of the overlay (just below the safe area, padded), showing `"+\(stackDepth - 1) more"`. Same `theme.fgMute` palette, monospaced, 11pt. Hidden when `stackDepth ≤ 1`.

The pill is the only depth cue — no card-stack offset/shadow. Keeps the overlay's existing centered hero layout intact.

### Persistence (no changes needed)

`ScreenTimeManager` already snapshots the duration on `addTrigger`, so the per-event durations propagate through unchanged. The `PendingTrigger.durationSeconds` field already exists and is the source of truth; the v2 migration in `ScreenTimeManager` is untouched.

## What's deliberately NOT in scope

- No per-event styling of the overlay (mascot, gradient, copy) — the existing `displayTitle` already says "Done — …" vs "Needs you — …", that's enough disambiguation.
- No card-stack visual (offset/shadow showing the literal stack underneath). The "+N more" pill is the only depth cue.
- No persistence of `overlayQueue` across launches. If the user kills the app while overlays are stacked, on relaunch the queue is empty; only the manager's `pendingTriggers` survive (so the shield stays up). The next ping will re-stack normally. Rebuilding the queue from `triggerStore.events ∩ pendingTriggers` would be a nice-to-have but is intentionally deferred.
- No "snooze" button — if the user wants to extend, they can ignore the timer and the trigger expires anyway; we're not adding new affordances.
- No analytics on how often timers expire vs are dismissed.

## Touch list

- `Vibez/SettingsView.swift` — split slider into two, update footer copy.
- `Vibez/ContentView.swift` — replace `blockSeconds` AppStorage with two; add `durationFor(_:)`; replace `overlayMessage` with `overlayQueue`; add push/pop/reconcile helpers.
- `Vibez/BlockedOverlay.swift` — add `expiresAt`, `onExpire`, `stackDepth` params; ticker; countdown view; depth pill.
- `Vibez/VibezApp.swift` — one-shot migration of `vibez.blockSeconds` in `init`.
- No changes to `ScreenTimeManager`, `NotifyClient`, `TriggerStore`, `IgnoreStore`.
