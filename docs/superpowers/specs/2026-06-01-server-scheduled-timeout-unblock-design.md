# Server-Scheduled Per-Session Timeout Unblock — Design

**Date:** 2026-06-01
**Status:** Approved design, pre-implementation
**Author:** Peter + Claude

## Problem

When a block's per-session timer elapses while Vibez is **suspended in the
background**, the apps stay shielded until the user next foregrounds the app.

Root cause (verified): the timeout unblock runs in `ScreenTimeManager.tick()`,
a 1 Hz `Task.sleep` loop that calls `pruneExpired()`. iOS freezes that loop
while the app is suspended, so an expired `PendingTrigger` is never pruned and
`recomputeBlocking()` never lifts the shield. Only foregrounding the app
resumes the loop and drops the shield.

There is **no in-app timer fix** — iOS will not run app code at a precise short
delay in the background (this is the same restriction behind the "no background
tasks under 15 minutes" guidance; `DeviceActivitySchedule` / `BGTaskScheduler`
have a ~15-minute floor, and the app uses neither today). The only thing that
runs app code at a precise short delay while suspended is a **remote push that
fires the Notification Service Extension**.

## Goals

- Lift the shield at (approximately) the right time **while Vibez is
  suspended**, without the user opening the app.
- Be **per-session correct**: a timeout for one conversation must not lift the
  shield while other conversations are still blocking. Behavior must match the
  existing app-side `pruneExpired` + `recomputeBlocking` semantics exactly.
- Reuse the existing, already-proven `shield:off` → NSE unblock path.
- Keep every existing unblock path (reply, manual Dismiss, master toggle off,
  focus-mode release) working unchanged.

## Non-Goals

- Guaranteed-to-the-second unblock. This is explicitly **best-effort**: push is
  the fast path, the existing foreground `pruneExpired` stays as the backstop.
  No iOS mechanism offers a hard guarantee here.
- Splitting behavior by duration ("<15 min vs ≥15 min"), or adding
  `DeviceActivityMonitor` as a second backup for long blocks. One mechanism — the
  server push — covers all durations (slider range 5s…1h). DeviceActivity is the
  Apple-native, network-independent tool for ≥15 min, but as a *second* backup it
  would duplicate the per-session unblock logic into a third extension, push
  schedule management (start/stop/reset) into both the host and the NSE, need a
  new target + entitlement, and straddle the `needs-input` default (900s) sitting
  right on the ~15-min floor. Deferred in favor of one coherent mechanism — see
  Out of Scope for the future-upgrade note.
- Changing how blocks are *engaged*. Only the *timeout unblock* changes.

## Core Principle

**The server never has authority over the shield. It only ever nudges the
device to re-evaluate one specific session. The device's pending-trigger set is
the single source of truth.**

There is exactly one OS shield (`ManagedSettingsStore(named: "vibez.shield")`) —
it is global, not per-session. Both the host app and the NSE model "should we be
blocking?" the same way: a **set of `PendingTrigger`s keyed by `sessionId`**
(persisted in the App Group under `vibez.pendingTriggers.v2`), where
`shield up ≡ set non-empty OR focus-mode held`.

A timeout is therefore not "lift the shield." It is "session X's timer is up —
remove X's trigger if it is actually due." The device removes only X and
re-derives whether the shield should stay up. Because of this, manual Dismiss,
reply, and toggle-off all keep working, and any stale/duplicate timeout push
simply finds nothing to do and **no-ops**.

## Layered Model

Two layers, with the device always authoritative:

- **Primary — on-device, precise.** The 1 Hz `pruneExpired` lifts the shield at
  the exact `expiresAt`, and manual Dismiss / reply / toggle act instantly.
  Active whenever Vibez is awake (foreground, or any background wake).
- **Backup — server push, approximate.** The scheduled `shield:off` timeout
  push only matters when Vibez was **suspended straight through** a block's
  expiry (the common "walked away / staring at the shield" case, where the tick
  loop is frozen). It is deliberately scheduled a few seconds **late** (§2) so it
  can never preempt the precise primary and — combined with an exact due-check
  (§3) — **can never unblock early.**

The on-device prune is also the final reconciler: opening Vibez always lifts
anything both layers somehow missed. The server is a safety net *under* a
mechanism that already works whenever the app is awake — never the other way
around. (We use one backup for every duration rather than swapping in
`DeviceActivityMonitor` for ≥15 min — see Non-Goals.)

## Design

### 1. Phone publishes its block durations

The server must know how long to wait before sending the timeout unblock. The
durations live on the phone (`vibez.blockSeconds.done` default 30,
`vibez.blockSeconds.needsInput` default 900), so the phone uploads them.

- Extend the `registerPushToken` callable to accept two optional ints,
  `blockSecondsDone` and `blockSecondsNeedsInput`. Validate each in
  `1…86400`; ignore/clamp out-of-range values. Persist on the device doc
  (`merge: true`), alongside `fcmToken` / `vibezId` / `platform`.
- `PushTokenRegistrar.registerIfPossible()` reads both values fresh from
  `UserDefaults.standard` and includes them in the existing `.call([...])`.
  They ride along on **every** registration (fresh FCM token, Vibez ID change).
- Re-publish on edit: `SettingsView.dismissSheet()` (and/or `.onDisappear`)
  calls `registrar.reregister()`. Closing the settings sheet is naturally
  debounced — one publish after the user finishes dragging sliders.
- Server defaults to `30` / `900` if a device doc lacks the fields (older app
  version). The durations are read **at `/notify` time**, which makes the
  scheduling delay an implicit snapshot — later edits never retroactively change
  an in-flight block, matching the on-device snapshot in `addTrigger`.

### 2. Server schedules the unblock (Cloud Tasks)

Add a delayed-dispatch layer using a Firebase **Cloud Tasks** queue
(`onTaskDispatched`). Not a `setTimeout` in the function (functions die when
they return) and not a Cloud Scheduler poll (too coarse).

- Refactor the APNs fan-out in `/notify` into a shared helper
  (`fanOutToVibezId` / `sendToToken`) so both `/notify` and the task handler
  build the identical payload envelope.
- In `/notify`, when a push **creates a timed trigger** — `shield !== "off"`,
  has a non-empty `session` (not `"nosid"`), and `event ∈ {done, needs-input}`
  or absent (absent → treated as `needs-input`) — enqueue one Cloud Task **per
  target device token** with `scheduleDelaySeconds = that device's stored
  duration for the event + UNBLOCK_BUFFER`. Task payload:
  `{ fcmToken, vibezId, session, event, agent, title, body }`.
- **`UNBLOCK_BUFFER ≈ 5–10s`** is the slack that makes the backup robust. The
  device starts its countdown when the block push *arrives*; the server starts
  its when the block push is *sent*, so the device's `expiresAt` lands ~delivery
  latency (δ, ~1–5s) *after* the server's bare `D`. Scheduling at `D + buffer`
  (buffer > δ) guarantees the timeout push reaches the device **after** its own
  `expiresAt`, so the exact due-check (§3) passes instead of no-opping. The cost
  — only in the suspended case — is being over-blocked by ~`buffer + δ`
  (~10–15s): negligible for `needs-input` (900s+), immaterial for a `done` nudge
  (foreground still unblocks at exactly `D`). Putting the slack in the *schedule*
  (always late) rather than the *due-check* is what yields the never-early
  guarantee.
- New `onTaskDispatched` function **`dispatchUnblock`** sends a `shield:off`
  push carrying **`reason: "timeout"`** to that one token, via the shared
  helper. Envelope is identical to today's reply unblock (passive
  interruption-level alert + `mutable-content: 1`, so it is silent but still
  fires the NSE — silent/background pushes do not fire the NSE on iOS 26).
- Replies (`shield:off`) and focus-mode never enqueue. Enqueue failures are
  logged and **non-fatal** — the block still works, the foreground prune is the
  backstop. `/notify`'s HTTP response is not blocked on enqueue success.

### 3. NSE: unblock **if due**, per session

A timeout unblock is *not* identical to a reply unblock. A reply means "drop it
now, unconditionally." A timeout means "drop it **only if it is actually due**."
The `reason` field selects the branch in `NotificationService.applyShieldState`
(and the host mirror — see §"Host vs NSE"):

```
on shield == "off":
    triggers = loadPendingTriggers()
    if reason == "timeout":
        t = triggers.first(where: sessionId == session)
        guard let t, now >= t.expiresAt else { return }   // not due / already gone → no-op
        triggers.removeAll(sessionId == session)
    else:                                                              // a reply
        triggers.removeAll(sessionId == session)                       // unconditional, as today
    save(triggers)
    if triggers.isEmpty && !focusMode { clearShield() }                // lift ONLY if nothing remains
    clearDeliveredNotifications(forSession: session)                   // only when we actually dropped
```

- `expiresAt = addedAt + durationSeconds` (the NSE's `PendingTrigger` mirror
  computes this inline; the host already has it as a computed property).
- The due-check is **exact** (`now >= expiresAt`) — no fudge factor. The slack
  that makes the push *arrive* after `expiresAt` lives in the **schedule**
  (`D + UNBLOCK_BUFFER`, §2), not here. Exact check + late schedule = the
  **never-early guarantee**: the server can only ever drop the shield at or
  after the device's true expiry. If an unusually slow block push ever pushed
  `expiresAt` past even the buffer, the check simply no-ops and the foreground
  prune backstops — still never early.
- Reset protection: a re-ping moves `expiresAt` later by a *full fresh
  duration*. The stale first task fires at `original_expiry + buffer`, still far
  short of the new `expiresAt`, so the exact due-check no-ops it; the re-ping's
  own task fires at the new time and drops. No task cancellation needed, at any
  duration — because the due-check is exact, even a re-pinged *short* block can
  never unblock early.

This is the key property: because the drop is conditional on the session being
present **and** due, **duplicate, early, and at-least-once task deliveries are
all harmless no-ops** — so we need *no* task-cancellation logic when a re-ping
resets a timer. Stale tasks simply fizzle.

### 4. Backstop: foreground prune retained

`ScreenTimeManager.tick()` / `pruneExpired()` stays exactly as-is. Push is the
fast path; the foreground prune catches anything the push missed (device off, no
network, push throttled). Opening the app always reconciles to truth.

### Host vs NSE responsibility (foreground)

The NSE fires for every `mutable-content` push regardless of foreground/
background. To avoid the host and NSE disagreeing when a timeout push lands in
the **foreground**:

- The **host** path (`NotifyClient.acceptPushUserInfo` →
  `ScreenTimeManager.applyTriggerFor`) **ignores `reason == "timeout"`** pushes.
  While foreground, the 1 Hz `pruneExpired` already owns expiry precisely.
- The **NSE** applies the due-check in all cases. When it drops a trigger in the
  foreground, the host's existing `reloadPendingTriggersFromAppGroupIfChanged()`
  (runs every tick) picks up the App Group change within ~1s, recomputes the
  shield, and the overlay for that session clears reactively. No new wiring.

## Wire-Format Changes

- **`registerPushToken` request** gains optional `blockSecondsDone: number`,
  `blockSecondsNeedsInput: number`. Stored on the device doc.
- **Timeout unblock push** adds a top-level `reason: "timeout"` (sibling of
  `event` / `shield` / `session` / `agent`). Absent on all existing pushes;
  reply unblocks keep sending `shield:off` with no `reason`.
- **Parsers** that read it: `VibezPushService/NotificationService.didReceive`
  and `NotifyClient.acceptPushUserInfo` (→ `NtfyMessage.reason`). Backward
  compatible — absence means "reply / unconditional," today's behavior.

## Per-Session Behavior Requirements (first-class)

| Scenario | Required outcome |
|---|---|
| A times out, B still pending | Remove A only; **shield stays up** for B |
| A and B both time out | Shield lifts only after the **last** trigger is removed |
| Re-ping A (timer reset) before A's first task fires | First task no-ops; shield lifts at the reset expiry |
| Manual Dismiss A before A's task fires | Shield reacts to Dismiss immediately; later task no-ops |
| Reply to A before A's task fires | Reply drops A immediately; later task no-ops |
| Master toggle off | All triggers cleared, shield down; later tasks no-op |
| Focus-mode hold active, A times out | A removed, **shield stays** (focus guard) |
| Duplicate task delivery for A | Second delivery no-ops |

## Races & Failure Modes

- **Timer reset / duplicate / at-least-once delivery** → handled by the
  due-check (§3). No task cancellation needed.
- **Push not delivered (device off / airplane / throttle)** → no fast unblock;
  foreground `pruneExpired` lifts on next open (backstop, §4).
- **App Group read-modify-write concurrency** — the `pendingTriggers` array is
  written by both the host and the NSE. If two background pushes for *different*
  sessions land within the same sub-second RMW window, one write can clobber the
  other (e.g. a freshly-added trigger lost). **Pre-existing** today (reply vs.
  new block); this change routes timeouts through the same path, so it is
  exercised more often. Accepted at personal scale (pings are seconds-to-minutes
  apart, single device). Future hardening: a file-lock or atomic merge around
  the trigger array. Tracked, not blocking.

## Multi-Device

`/notify` enqueues **one task per target device token**, each with that device's
own stored duration, and `dispatchUnblock` targets that single token. This is
per-device-correct (an iPhone and iPad with different durations each unblock on
their own schedule) and is barely more code than a single fan-out, since
`/notify` already iterates the device set. If a token rotated between block and
unblock, the stale task no-ops (token invalid → swept; or session already gone)
and the backstop covers it.

## Scaling & Isolation (hundreds–thousands of users)

- **The App Group RMW race is strictly per-device.** Each phone has its own
  container, NSE, and trigger array; one user's pushes never touch another's
  storage. Its probability scales with a *single user's* concurrent agent
  sessions, **not** with the user population. It does not get worse with more
  users.
- **The backend is partitioned by Vibez ID, so it is embarrassingly parallel.**
  `/notify` only reads `where vibezId == X` (a user's 1–3 device docs, never the
  whole collection). Doc IDs are FCM tokens (high entropy) → no Firestore
  sequential-key hotspot. No shared mutable state across users.
- **Scale is a config dial, not a rewrite.** `maxInstances` is currently `10` —
  a deliberate *cost* ceiling, not a throughput wall (each Gen-2/Cloud Run
  instance serves many concurrent requests; per-user traffic is bursty-but-tiny,
  so 10 covers thousands; bump in one line if outgrown). The Cloud Tasks queue
  has its own `maxDispatchesPerSecond`. Cloud Tasks, FCM, and Firestore each
  scale orders of magnitude past this. Cost grows **linearly** — pennies per
  thousand events across Functions + Tasks + Firestore.
- **The real pre-scale concern is abuse/auth, not throughput.** `/notify` is
  `invoker:"public"` with the Vibez ID as the only secret; at scale, App Check
  (already roadmap step 2) is what gates spam/enumeration. Out of scope here.

## Test Plan

Device-only feature (shields are no-ops in the simulator). On a real device,
with apps picked and the master toggle armed, all "while backgrounded" steps
performed without foregrounding Vibez until the assertion:

1. **Single session, background expiry.** Trigger A (`done`, 30s) backgrounded →
   shield engages. Wait ~35s. Assert shield lifts, apps usable, app never
   foregrounded.
2. **Two sessions, one expires.** Trigger A (`done` 30s) + B (`needs-input`
   900s). At ~35s assert A gone but **shield still up** (B pending). ← core req.
3. **Both expire.** Continue (2) to ~905s; assert shield lifts.
4. **Reset.** Trigger A (`needs-input` 900s) @T0; re-ping A @T0+300. Assert the
   ~T0+900 task no-ops (shield up); shield lifts ~T0+1200.
5. **Dismiss before timeout.** Trigger A; Dismiss in app → shield drops; later
   timeout task arrives → no-op (no errors, no effect on other state).
6. **Dismiss A while B pending.** A+B pending; Dismiss A → B stays blocked;
   A's later task → no-op; B still blocked.
7. **Reply before timeout.** Trigger A; reply in agent → shield drops; later
   task → no-op.
8. **Toggle off.** A+B pending; master toggle off → all clear; later tasks →
   no-op.
9. **Duplicate delivery.** Force `dispatchUnblock` twice for A → second no-ops.
10. **Offline backstop.** Trigger A backgrounded; airplane mode past expiry
    (push undelivered); foreground → `pruneExpired` lifts shield.
11. **Duration publish.** Change `done` in Settings, close sheet; assert
    `registerPushToken` re-called with new value and the device doc updates; a
    subsequent `done` block schedules at the new delay.
12. **`allowDismiss` off.** With the Dismiss button hidden, confirm (1) still
    works so a backgrounded user is never stuck.
13. **Focus hold.** Manual focus hold + a session times out → trigger removed,
    **shield stays** (focus guard).

## Out of Scope / Future

- `DeviceActivityMonitor` (`DeviceActivitySchedule`) as an *additional*,
  network-independent backup for **long** blocks specifically — the one case the
  push backup can't cover is the phone being offline at a long block's expiry. A
  clean future add-on if that proves to matter; deliberately deferred to avoid a
  second backup subsystem (see Non-Goals).
- App Check on `/notify` and `dispatchUnblock` (roadmap step 2).
- File-lock / atomic merge to fully close the App Group RMW race.
- Suppressing the lone passive Notification Center entry a timeout push leaves
  (same residue as today's reply unblock; swept on the next push or app open).

## Open Questions

- `UNBLOCK_BUFFER` value: ~5–10s proposed — big enough to clear typical APNs
  delivery latency so the timeout push lands after the device's `expiresAt`,
  small enough to be immaterial. Tunable once latency is instrumented.
- Cloud Tasks queue provisioning + enqueuer IAM on first deploy (one-time setup
  to confirm during implementation).
