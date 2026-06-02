# Server-Scheduled Timeout Unblock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift the app shield at (approximately) the right time while Vibez is suspended, by having the Firebase backend schedule a per-session `shield:off` push at each block's expiry — as a best-effort backup under the existing on-device timer.

**Architecture:** The on-device prune stays the precise primary. The phone publishes its block durations to Firestore; `/notify` enqueues a Cloud Task per device at `duration + buffer`; a new `dispatchUnblock` task function sends a per-session `shield:off` carrying `reason:"timeout"`; the NSE applies it only if that session is actually due (so stale/duplicate dispatches no-op). Reference: `docs/superpowers/specs/2026-06-01-server-scheduled-timeout-unblock-design.md`.

**Tech Stack:** Firebase Cloud Functions v2 (TypeScript, `firebase-functions@7`, Cloud Tasks via `onTaskDispatched`), Firestore (`tokens` db), FCM/APNs; iOS Swift (host app + `VibezPushService` NSE), vitest for backend unit tests.

**Conventions:**
- Commit on `main` in the repo root (project convention — recent history is direct-to-main). Each task ends with a commit of only its own files.
- Backend code MUST stay ≤80 columns and double-quoted (eslint-google runs in `predeploy`; max-len is an error).
- **Order matters:** do Phase A (backend) first and **deploy it** before Phase B device testing — Phase B's manual scenarios need the live functions. The server defaults to `30`/`900` durations if the phone hasn't published yet, so the two phases are otherwise decoupled.

---

## File Structure

**Backend (`Backend/functions/`)**
- Create `src/scheduling.ts` — pure, firebase-free helpers: `clampDuration`, `delayForEvent`, `shouldScheduleUnblock`, `buildApnsPayload`, `APNS_HEADERS`, `UNBLOCK_BUFFER_SECONDS`. Unit-testable in isolation (no `initializeApp`).
- Create `test/scheduling.test.ts` — vitest tests for the above.
- Modify `src/index.ts` — import the helpers; extend `registerPushToken` to store durations; refactor `/notify`'s payload build + add per-device unblock enqueue; add `dispatchUnblock`.
- Modify `package.json` — add `vitest` devDep + `"test"` script.
- Modify `.eslintrc.js` — ignore `/test/**/*` (tests don't follow google jsdoc/max-len).

**iOS**
- Modify `VibezPushService/NotificationService.swift` — parse `reason`; per-session "if due" branch for `reason:"timeout"`; `PendingTrigger.expiresAt`; skip last-message + NC-clear for timeouts.
- Modify `Vibez/NotifyClient.swift` — host ignores `reason:"timeout"` pushes.
- Modify `Vibez/PushTokenRegistrar.swift` — include the two durations in `registerPushToken`.
- Modify `Vibez/SettingsView.swift` — re-publish durations when the settings sheet closes.
- Modify `CLAUDE.md` — document the new function + wire field.

---

## Phase A — Backend

### Task A1: Pure scheduling helpers + vitest harness (TDD)

**Files:**
- Create: `Backend/functions/src/scheduling.ts`
- Create: `Backend/functions/test/scheduling.test.ts`
- Modify: `Backend/functions/package.json`
- Modify: `Backend/functions/.eslintrc.js`

- [ ] **Step 1: Add the test runner + ignore tests from lint**

In `Backend/functions/`, install vitest:

```bash
cd Backend/functions && npm install -D vitest
```

Add a `test` script — edit `package.json` `"scripts"` to include:

```json
    "test": "vitest run",
```

Edit `.eslintrc.js` `ignorePatterns` to add the test dir:

```js
  ignorePatterns: [
    "/lib/**/*", // Ignore built files.
    "/generated/**/*", // Ignore generated files.
    "/test/**/*", // Vitest tests — not google-style.
  ],
```

- [ ] **Step 2: Write the failing tests**

Create `Backend/functions/test/scheduling.test.ts`:

```ts
import {describe, it, expect} from "vitest";
import {
  clampDuration,
  delayForEvent,
  shouldScheduleUnblock,
  buildApnsPayload,
  UNBLOCK_BUFFER_SECONDS,
} from "../src/scheduling";

describe("clampDuration", () => {
  it("passes valid values through, rounded", () => {
    expect(clampDuration(30, 999)).toBe(30);
    expect(clampDuration(900.4, 999)).toBe(900);
  });
  it("clamps out-of-range to [1, 86400]", () => {
    expect(clampDuration(0, 999)).toBe(1);
    expect(clampDuration(99999999, 999)).toBe(86400);
  });
  it("falls back on non-numbers", () => {
    expect(clampDuration("x", 30)).toBe(30);
    expect(clampDuration(undefined, 900)).toBe(900);
    expect(clampDuration(NaN, 7)).toBe(7);
  });
});

describe("delayForEvent", () => {
  const d = {done: 30, needsInput: 900};
  it("uses the done duration for done", () => {
    expect(delayForEvent("done", d)).toBe(30 + UNBLOCK_BUFFER_SECONDS);
  });
  it("uses needsInput for needs-input and absent", () => {
    expect(delayForEvent("needs-input", d))
      .toBe(900 + UNBLOCK_BUFFER_SECONDS);
    expect(delayForEvent(undefined, d))
      .toBe(900 + UNBLOCK_BUFFER_SECONDS);
  });
});

describe("shouldScheduleUnblock", () => {
  it("schedules a timed block that has a session", () => {
    expect(shouldScheduleUnblock(
      {shield: "on", session: "s1", event: "done"})).toBe(true);
    expect(shouldScheduleUnblock(
      {session: "s1", event: "needs-input"})).toBe(true);
    expect(shouldScheduleUnblock({session: "s1"})).toBe(true);
  });
  it("skips replies, focus/untagged, and replied", () => {
    expect(shouldScheduleUnblock(
      {shield: "off", session: "s1"})).toBe(false);
    expect(shouldScheduleUnblock({event: "done"})).toBe(false);
    expect(shouldScheduleUnblock({session: "nosid"})).toBe(false);
    expect(shouldScheduleUnblock(
      {session: "s1", event: "replied"})).toBe(false);
  });
});

describe("buildApnsPayload", () => {
  it("puts custom fields + reason at the top level", () => {
    const p = buildApnsPayload({
      title: "T", body: "B", event: "done", shield: "off",
      session: "s1", agent: "cc", reason: "timeout",
    });
    expect(p.session).toBe("s1");
    expect(p.reason).toBe("timeout");
    expect(p.shield).toBe("off");
  });
  it("uses passive interruption + no sound for shield:off", () => {
    const p = buildApnsPayload({title: "T", body: "B", shield: "off"});
    expect(p.aps["interruption-level"]).toBe("passive");
    expect(p.aps.sound).toBeUndefined();
  });
  it("uses sound for non-off pushes", () => {
    const p = buildApnsPayload({title: "T", body: "B", shield: "on"});
    expect(p.aps.sound).toBe("default");
  });
});
```

- [ ] **Step 3: Run tests — verify they FAIL**

```bash
cd Backend/functions && npm test
```

Expected: FAIL — `Cannot find module "../src/scheduling"` (file not created yet).

- [ ] **Step 4: Implement the helpers**

Create `Backend/functions/src/scheduling.ts`:

```ts
// Pure, side-effect-free helpers for the timeout-unblock backup layer.
// No firebase imports here, so they unit-test without the admin SDK.

/**
 * Seconds added to every scheduled unblock so the push lands AFTER the
 * device's own expiry — the device starts its countdown when the block
 * push arrives (~1-5s after the server sent it). Design spec §2.
 */
export const UNBLOCK_BUFFER_SECONDS = 8;

/**
 * Clamp an untrusted duration to [1, 86400] seconds, rounding; fall
 * back when the value is not a finite number.
 */
export function clampDuration(value: unknown, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }
  return Math.min(86400, Math.max(1, Math.round(value)));
}

/**
 * Seconds to wait before the timeout unblock for this event, including
 * the delivery-skew buffer. `done` uses the short duration; everything
 * else (needs-input / absent) uses the long one.
 */
export function delayForEvent(
  event: string | undefined,
  durations: {done: number; needsInput: number},
): number {
  const base = event === "done" ? durations.done : durations.needsInput;
  return base + UNBLOCK_BUFFER_SECONDS;
}

/**
 * Whether a /notify push should schedule a timeout unblock. Only blocks
 * that create a per-session timed trigger qualify: not replies
 * (shield:off), not focus/untagged (no session), not `replied`. An
 * absent event is treated as needs-input and DOES qualify.
 */
export function shouldScheduleUnblock(p: {
  shield?: string;
  session?: string;
  event?: string;
}): boolean {
  if (p.shield === "off") return false;
  if (!p.session || p.session === "nosid") return false;
  if (p.event === "replied") return false;
  return true;
}

/** APNs headers shared by every Vibez push. */
export const APNS_HEADERS: Record<string, string> = {
  "apns-push-type": "alert",
  "apns-priority": "10",
};

/**
 * Build the apns.payload for a Vibez push. `shield:"off"` → passive
 * (silent) alert; otherwise a standard alert with sound. Custom fields
 * sit at the top level (siblings of `aps`) so iOS surfaces them in
 * userInfo, matching what NotifyClient + the NSE parse. Returns `any`
 * to mirror index.ts's existing payload typing.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function buildApnsPayload(f: {
  title: string;
  body: string;
  event?: string;
  shield?: string;
  session?: string;
  agent?: string;
  reason?: string;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
}): any {
  const isSilent = f.shield === "off";
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const aps: any = isSilent ?
    {
      "alert": {title: f.title, body: f.body},
      "interruption-level": "passive",
      "content-available": 1,
      "mutable-content": 1,
    } :
    {
      "alert": {title: f.title, body: f.body},
      "sound": "default",
      "content-available": 1,
      "mutable-content": 1,
    };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const payload: any = {aps, title: f.title, body: f.body};
  if (f.event !== undefined) payload.event = f.event;
  if (f.shield !== undefined) payload.shield = f.shield;
  if (f.session !== undefined) payload.session = f.session;
  if (f.agent !== undefined) payload.agent = f.agent;
  if (f.reason !== undefined) payload.reason = f.reason;
  return payload;
}
```

- [ ] **Step 5: Run tests — verify they PASS**

```bash
cd Backend/functions && npm test
```

Expected: PASS — all 4 describe blocks green.

- [ ] **Step 6: Verify lint + build still pass**

```bash
cd Backend/functions && npm run lint && npm run build
```

Expected: no errors (tests are ignored by lint; `scheduling.ts` compiles).

- [ ] **Step 7: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Backend/functions/src/scheduling.ts \
  Backend/functions/test/scheduling.test.ts \
  Backend/functions/package.json Backend/functions/package-lock.json \
  Backend/functions/.eslintrc.js
git -C /Users/peter/Desktop/Vibez commit -m "feat(backend): pure scheduling helpers + vitest harness"
```

---

### Task A2: Store per-device durations in `registerPushToken`

**Files:**
- Modify: `Backend/functions/src/index.ts`

- [ ] **Step 1: Import the one helper this task uses**

`tsconfig` has `noUnusedLocals: true`, so import helpers only as each task
starts using them (we extend this line in A3/A5). At the top of `src/index.ts`,
after the existing imports, add:

```ts
import {clampDuration} from "./scheduling.js";
```

(The `.js` extension is required by the NodeNext module resolution — it points at the compiled `scheduling.js`.)

- [ ] **Step 2: Persist durations on the device doc**

In `registerPushToken`, replace the existing `await tokensDb...set({...}, {merge: true})` call with:

```ts
    const deviceDoc: Record<string, unknown> = {
      fcmToken,
      vibezId,
      platform,
      createdAt: FieldValue.serverTimestamp(),
      lastSeen: FieldValue.serverTimestamp(),
    };
    if (data.blockSecondsDone !== undefined) {
      deviceDoc.blockSecondsDone = clampDuration(data.blockSecondsDone, 30);
    }
    if (data.blockSecondsNeedsInput !== undefined) {
      deviceDoc.blockSecondsNeedsInput =
        clampDuration(data.blockSecondsNeedsInput, 900);
    }

    await tokensDb.collection(DEVICES).doc(fcmToken).set(
      deviceDoc,
      {merge: true}
    );
```

- [ ] **Step 3: Build + lint**

```bash
cd Backend/functions && npm run build && npm run lint
```

Expected: no errors. `clampDuration` is now used (in `registerPushToken`), so there are no unused-import errors.

- [ ] **Step 4: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Backend/functions/src/index.ts
git -C /Users/peter/Desktop/Vibez commit -m "feat(backend): store per-device block durations on registerPushToken"
```

---

### Task A3: Refactor `/notify` to use `buildApnsPayload` (no behavior change)

**Files:**
- Modify: `Backend/functions/src/index.ts`

- [ ] **Step 1: Extend the scheduling import, then replace the inline aps/payload construction**

First extend the scheduling import to add the two helpers this task uses:

```ts
import {clampDuration, buildApnsPayload, APNS_HEADERS} from "./scheduling.js";
```

In `notify`, delete the block that builds `isSilent`, `aps`, `apnsPayload`, and `apnsHeaders` (from `const isSilent = shield === "off";` through the `apnsHeaders` object literal) and replace with:

```ts
    const apnsPayload = buildApnsPayload({
      title,
      body: bodyText,
      event,
      shield,
      session,
      agent,
    });
    const apnsHeaders = APNS_HEADERS;
```

The downstream `sendEachForMulticast({tokens: chunk, apns: {headers: apnsHeaders, payload: apnsPayload}})` is unchanged — `buildApnsPayload` returns the identical shape it built before (no `reason` here).

- [ ] **Step 2: Build + verify no behavior change**

```bash
cd Backend/functions && npm run build && npm run lint
```

Expected: no errors. The emitted payload is byte-for-byte equivalent to the previous inline version for existing pushes.

- [ ] **Step 3: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Backend/functions/src/index.ts
git -C /Users/peter/Desktop/Vibez commit -m "refactor(backend): build /notify payload via shared buildApnsPayload"
```

---

### Task A4: Add the `dispatchUnblock` task function

**Files:**
- Modify: `Backend/functions/src/index.ts`

- [ ] **Step 1: Add the tasks import, then append the task-dispatched function**

Add the v2 tasks trigger import (used here):

```ts
import {onTaskDispatched} from "firebase-functions/tasks";
```

At the end of `src/index.ts`, add:

```ts
/**
 * Cloud Tasks target. Fires at a block's expiry + buffer and sends a
 * per-session `shield:off` carrying `reason:"timeout"` to one device.
 * The NSE applies it ONLY if that session is actually due (design spec
 * §3), so a stale or duplicate dispatch is a harmless no-op. Best-
 * effort backup under the on-device prune.
 */
export const dispatchUnblock = onTaskDispatched(
  {
    retryConfig: {maxAttempts: 3, minBackoffSeconds: 5},
    rateLimits: {maxConcurrentDispatches: 20},
  },
  async (req) => {
    const d = (req.data ?? {}) as Record<string, unknown>;
    const fcmToken = typeof d.fcmToken === "string" ? d.fcmToken : "";
    if (!fcmToken) return;

    const payload = buildApnsPayload({
      title: typeof d.title === "string" ? d.title : "Vibez",
      body: typeof d.body === "string" ? d.body : "",
      event: typeof d.event === "string" ? d.event : undefined,
      shield: "off",
      session: typeof d.session === "string" ? d.session : undefined,
      agent: typeof d.agent === "string" ? d.agent : undefined,
      reason: "timeout",
    });

    try {
      await getMessaging().send({
        token: fcmToken,
        apns: {headers: APNS_HEADERS, payload},
      });
      logger.info("dispatchUnblock sent", {
        session: d.session,
        tokenPrefix: fcmToken.slice(0, 12),
      });
    } catch (e) {
      const code = (e as {code?: string})?.code;
      logger.warn("dispatchUnblock failed", {code, session: d.session});
      if (code === "messaging/registration-token-not-registered") {
        await tokensDb.collection(DEVICES).doc(fcmToken).delete()
          .catch(() => undefined);
      }
    }
  }
);
```

- [ ] **Step 2: Build + lint**

```bash
cd Backend/functions && npm run build && npm run lint
```

Expected: no errors. `getMessaging` is already imported in index.ts.

- [ ] **Step 3: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Backend/functions/src/index.ts
git -C /Users/peter/Desktop/Vibez commit -m "feat(backend): add dispatchUnblock Cloud Tasks function"
```

---

### Task A5: Enqueue per-device unblock tasks from `/notify`

**Files:**
- Modify: `Backend/functions/src/index.ts`

- [ ] **Step 1: Add the remaining imports, then decide once + collect per-device delays**

Extend the scheduling import to its final form and add the admin Task Queue API:

```ts
import {
  clampDuration,
  delayForEvent,
  shouldScheduleUnblock,
  buildApnsPayload,
  APNS_HEADERS,
} from "./scheduling.js";
import {getFunctions} from "firebase-admin/functions";
```

In `notify`, just before the `snapshot.forEach(...)` that partitions devices, add:

```ts
    const scheduleUnblock = shouldScheduleUnblock({shield, session, event});
    const unblockTargets: {token: string; delaySeconds: number}[] = [];
```

Then, inside that `snapshot.forEach((doc) => {...})`, in the branch that
pushes an APNs token (`} else if (typeof token === "string" && token.length > 0) {`),
after `apnsTokens.push(token);` add:

```ts
        if (scheduleUnblock) {
          const durations = {
            done: clampDuration(doc.get("blockSecondsDone"), 30),
            needsInput: clampDuration(doc.get("blockSecondsNeedsInput"), 900),
          };
          unblockTargets.push({
            token,
            delaySeconds: delayForEvent(event, durations),
          });
        }
```

- [ ] **Step 2: Enqueue the tasks after the fan-out**

In `notify`, after the stale-token sweep (`if (invalidTokens.length > 0) {...}`) and before the web-events block / final `res.status(200)`, add:

```ts
    // Schedule the per-session timeout unblock (backup layer): one Cloud
    // Task per device, each at that device's own duration + buffer. Best-
    // effort — a failed enqueue just falls back to the on-device prune,
    // so we never fail the /notify response on it.
    if (scheduleUnblock && unblockTargets.length > 0) {
      // taskQueue("dispatchUnblock") resolves the queue for the function
      // in the default region (us-central1). If a deploy ever moves the
      // function, use "locations/<region>/functions/dispatchUnblock".
      const queue = getFunctions().taskQueue("dispatchUnblock");
      await Promise.all(unblockTargets.map((t) =>
        queue.enqueue(
          {
            fcmToken: t.token,
            vibezId,
            session,
            event,
            agent,
            title,
            body: bodyText,
          },
          {scheduleDelaySeconds: t.delaySeconds}
        ).catch((err) => logger.warn("enqueue unblock failed", {
          session,
          err: String(err),
        }))
      ));
    }
```

- [ ] **Step 3: Build + lint (full backend now compiles clean)**

```bash
cd Backend/functions && npm run build && npm run lint && npm test
```

Expected: no errors; vitest still green.

- [ ] **Step 4: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Backend/functions/src/index.ts
git -C /Users/peter/Desktop/Vibez commit -m "feat(backend): enqueue per-device timeout unblock tasks from /notify"
```

---

### Task A6: Deploy + provision the Cloud Tasks queue / IAM

**Files:** none (deploy + verification)

- [ ] **Step 1: Deploy all functions**

```bash
cd Backend/functions && npm run deploy
```

Expected: `registerPushToken`, `notify`, and **`dispatchUnblock`** all deploy. The deploy auto-creates the `dispatchUnblock` Cloud Tasks queue and wires Cloud Tasks → function invocation (OIDC).

- [ ] **Step 2: Smoke-test the enqueue→dispatch round trip**

Send a fake block to your own Vibez ID (replace `<VIBEZ_ID>` and `<NOTIFY_URL>`),
using a short `done` duration so you don't wait 15 min. The phone must be
registered. Use the `/notify` URL printed by `firebase deploy` (or the one the
plugin already posts to — see `ClaudePlugin/scripts/notify.sh`).

```bash
curl -sS -X POST "<NOTIFY_URL>" \
  -H "Content-Type: application/json" \
  -d '{"vibezId":"<VIBEZ_ID>","title":"Plan test","body":"timeout unblock smoke","event":"done","shield":"on","session":"plan-smoke-1","agent":"cc"}'
```

Then watch logs:

```bash
cd Backend/functions && firebase functions:log --only notify,dispatchUnblock | tail -40
```

Expected timeline: a `notify fan-out` log immediately, then ~`done + 8s`
later a `dispatchUnblock sent` log. On the device, the shield should engage
then lift on its own.

- [ ] **Step 3: If enqueue fails with PERMISSION_DENIED — grant the enqueuer role**

If Step 2's logs show `enqueue unblock failed` with a permission error, the
functions runtime service account lacks `cloudtasks.enqueuer`. Find the SA and
grant it (project `vibez-backend`):

```bash
gcloud functions describe notify --region=us-central1 \
  --project=vibez-backend --gen2 \
  --format="value(serviceConfig.serviceAccountEmail)"
# → e.g. <PROJECT_NUMBER>-compute@developer.gserviceaccount.com

gcloud projects add-iam-policy-binding vibez-backend \
  --member="serviceAccount:<SA_EMAIL_FROM_ABOVE>" \
  --role="roles/cloudtasks.enqueuer"
```

Re-run Step 2 to confirm the dispatch now fires. No commit (infra/IAM).

---

## Phase B — iOS

> Per-task gate: a simulator **compile** build of the `Vibez` scheme (builds the app + both extensions). It won't exercise shielding (no-op in sim) — that's covered by the device scenarios in Task B5.
>
> Compile command used throughout Phase B:
> ```bash
> xcodebuild -project /Users/peter/Desktop/Vibez/Vibez.xcodeproj \
>   -scheme Vibez -sdk iphonesimulator \
>   -destination 'generic/platform=iOS Simulator' \
>   build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
> ```
> Expected: `** BUILD SUCCEEDED **`.

### Task B1: NSE — parse `reason` and apply timeout "if due"

**Files:**
- Modify: `VibezPushService/NotificationService.swift`

- [ ] **Step 1: Add `expiresAt` to the trigger mirror**

Replace the `PendingTrigger` struct (top of the file) with:

```swift
struct PendingTrigger: Codable, Equatable {
    let sessionId: String
    let addedAt: Date
    let durationSeconds: Int

    /// When this trigger's timer is up. Mirrors the host's computed
    /// property so the NSE can decide whether a timeout unblock is due.
    var expiresAt: Date {
        addedAt.addingTimeInterval(TimeInterval(durationSeconds))
    }
}
```

- [ ] **Step 2: Read `reason` in `didReceive`, pass it down, and gate the timeout-specific side effects**

In `didReceive`, after `let body = (userInfo["body"] as? String) ?? ""`, add:

```swift
        let reason = (userInfo["reason"] as? String) ?? ""
```

Change the `applyShieldState(...)` call to pass it:

```swift
        applyShieldState(
            shield: shield,
            session: session,
            event: event,
            agent: agent,
            title: title,
            body: body,
            reason: reason
        )
```

Wrap the `writeLastMessageToAppGroup(...)` call so timeouts don't replay as
an overlay (a timeout is not a user-facing ping):

```swift
        // A timeout unblock is a backup mechanism, not a ping — never
        // replay it as an in-app overlay / Recent-triggers row.
        if reason != "timeout" {
            writeLastMessageToAppGroup(
                userInfo: userInfo, identifier: request.identifier)
        }
```

In the Notification-Center cleanup block, scope the reply sweep so a *not-
yet-due* timeout doesn't yank a still-valid banner — change the `else if`
condition to also require `reason != "timeout"`:

```swift
        if notificationsOff {
            clearDeliveredNotifications(forSession: nil)
        } else if shield == "off", reason != "timeout",
                  !session.isEmpty, session != "nosid" {
            clearDeliveredNotifications(forSession: session)
        }
```

- [ ] **Step 3: Add the `reason` param + "if due" guard to `applyShieldState`**

Change the `applyShieldState` signature to add `reason: String`:

```swift
    private func applyShieldState(
        shield: String,
        session: String,
        event: String,
        agent: String,
        title: String,
        body: String,
        reason: String
    ) {
```

Replace the `if shield == "off" { ... }` branch body with:

```swift
        if shield == "off" {
            guard !session.isEmpty, session != "nosid" else { return }
            var triggers = loadPendingTriggers()
            if reason == "timeout" {
                // Backup unblock: drop ONLY if this session's timer is
                // actually due. Not due (the timer was reset by a later
                // ping) or already gone → no-op, so a stale/duplicate
                // dispatch can never unblock early. Design spec §3.
                guard let t = triggers.first(
                          where: {$0.sessionId == session}),
                      Date() >= t.expiresAt else {
                    log.info("shield=off timeout \(session, privacy: .public): not due / gone — no-op")
                    return
                }
            }
            let before = triggers.count
            triggers.removeAll { $0.sessionId == session }
            savePendingTriggers(triggers)
            let focusMode = sharedDefaults?.bool(forKey: Key.focusMode) ?? false
            if triggers.isEmpty && !focusMode {
                clearShield()
            }
            log.info("shield=off: \(session, privacy: .public) (\(before, privacy: .public)→\(triggers.count, privacy: .public)) focus=\(focusMode, privacy: .public) reason=\(reason, privacy: .public)")
            return
        }
```

- [ ] **Step 4: Compile**

Run the Phase B compile command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add VibezPushService/NotificationService.swift
git -C /Users/peter/Desktop/Vibez commit -m "feat(nse): apply timeout unblock per-session, only if due"
```

---

### Task B2: Host — ignore `reason:"timeout"` pushes

**Files:**
- Modify: `Vibez/NotifyClient.swift`

- [ ] **Step 1: Early-return in `acceptPushUserInfo`**

At the very top of `acceptPushUserInfo(_:wasBackgroundEngaged:)`, before the
`var msg = NtfyMessage(...)` line, add:

```swift
        // Timeout unblocks are the server's backup layer. The NSE applies
        // them (if due), and while we're awake the 1 Hz prune owns expiry.
        // The host must NOT act here — resolving unconditionally would
        // drop a session that may have been re-pinged. (Design spec §3.)
        if (userInfo["reason"] as? String) == "timeout" {
            log.info("acceptPushUserInfo: ignoring reason=timeout (NSE + prune own it)")
            return
        }
```

(The NSE already skips writing `last-message.json` for timeouts, so the drain
path never surfaces them either — this guard covers the live foreground
`willPresent` path.)

- [ ] **Step 2: Compile**

Run the Phase B compile command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Vibez/NotifyClient.swift
git -C /Users/peter/Desktop/Vibez commit -m "feat(ios): host ignores timeout unblock pushes (NSE + prune own them)"
```

---

### Task B3: Registrar — publish block durations

**Files:**
- Modify: `Vibez/PushTokenRegistrar.swift`

- [ ] **Step 1: Include the durations in the register call**

In `registerIfPossible()`, just before the `_ = try await functions...call([...])`,
read the two durations, then add them to the payload:

```swift
        let doneSeconds =
            defaults.object(forKey: "vibez.blockSeconds.done") as? Int ?? 30
        let needsSeconds =
            defaults.object(forKey: "vibez.blockSeconds.needsInput")
                as? Int ?? 900
        do {
            _ = try await functions
                .httpsCallable("registerPushToken")
                .call([
                    "fcmToken": token,
                    "vibezId": vibezId,
                    "platform": "ios",
                    "blockSecondsDone": doneSeconds,
                    "blockSecondsNeedsInput": needsSeconds,
                ])
```

(Replace the existing `.call([...])` dict — keep the rest of the `do {} catch {}`
body unchanged.)

- [ ] **Step 2: Compile**

Run the Phase B compile command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Vibez/PushTokenRegistrar.swift
git -C /Users/peter/Desktop/Vibez commit -m "feat(ios): publish block durations to registerPushToken"
```

---

### Task B4: Settings — re-publish durations on sheet close

**Files:**
- Modify: `Vibez/SettingsView.swift`

- [ ] **Step 1: Re-register when the sheet dismisses**

Replace `dismissSheet()` with:

```swift
    private func dismissSheet() {
        vibezIdFocused = false
        // Push any block-duration edits to the server so it schedules
        // timeout unblocks with the latest values. reregister() re-reads
        // the durations from UserDefaults. Design spec §1.
        Task { await registrar.reregister() }
        isPresented = false
        dismiss()
    }
```

- [ ] **Step 2: Compile**

Run the Phase B compile command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add Vibez/SettingsView.swift
git -C /Users/peter/Desktop/Vibez commit -m "feat(ios): re-publish durations when Settings closes"
```

---

### Task B5: On-device acceptance (manual)

**Files:** none (run the device, build+install via Xcode to Peter's iPhone)

Build/run the `Vibez` scheme to the physical iPhone (shielding is a no-op in
the simulator). Confirm Phase A is deployed first. Pick a couple of apps and
arm the toggle. Set `done` to a short value (e.g. 15s) and `needs-input` to a
short value (e.g. 60s) in Settings to keep the loop fast, then verify the
core spec scenarios (design spec "Test Plan"). Trigger pings with `curl`
to `/notify` (as in A6 Step 2), varying `session`/`event`.

- [ ] **Scenario 1 — single session, background expiry.** Trigger one `done`
  block, lock the phone / leave Vibez backgrounded. Assert the shield engages,
  then **lifts on its own** ~`done + 8s` later, without opening Vibez.
- [ ] **Scenario 2 — two sessions, one expires (the key requirement).** Trigger
  session `A` (`done`, short) and `B` (`needs-input`, longer). When A's timeout
  fires, assert A's block clears **but the shield stays up** for B. Apps still
  blocked.
- [ ] **Scenario 4 — reset.** Trigger `A` (`needs-input`). Re-send the same
  `session` ~halfway through. Assert the first task's fire is a **no-op** (shield
  stays) and the shield lifts only after the reset expiry.
- [ ] **Scenario 5 — dismiss before timeout.** Trigger `A`; tap Dismiss in the
  app. Shield drops immediately; when A's stale timeout fires later, assert it's
  a no-op (no errors, B/other state untouched).
- [ ] **Scenario 7 — reply before timeout.** Trigger `A` (`needs-input`); send a
  `shield:off`/`replied` for it. Shield drops; later timeout task no-ops.
- [ ] **Scenario 11 — duration publish.** Change `done` in Settings, close the
  sheet. In `firebase functions:log` / Firestore, confirm `registerPushToken`
  ran and the device doc's `blockSecondsDone` updated; a subsequent `done` block
  schedules at the new delay.

If all pass, no code change — this task is the acceptance gate.

---

### Task B6: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Document the new function + wire field**

In the `Backend/ ... functions/src/index.ts` description, change "Two functions"
to "Three functions" and add a bullet:

```
    - dispatchUnblock (Cloud Tasks onTaskDispatched): enqueued per device by
      /notify at block-expiry + buffer; sends a per-session shield:off with
      reason:"timeout". The NSE drops the shield only if that session is due,
      so stale/duplicate dispatches no-op. Backup under the on-device prune.
```

In the push-pipeline / payload notes, add that pushes may carry a top-level
`reason:"timeout"`, and that block durations are published to the device doc
via `registerPushToken` (`blockSecondsDone` / `blockSecondsNeedsInput`).

- [ ] **Step 2: Commit**

```bash
git -C /Users/peter/Desktop/Vibez add CLAUDE.md
git -C /Users/peter/Desktop/Vibez commit -m "docs: document dispatchUnblock + reason:timeout wire field"
```

---

## Done When

- Backend deploys clean (`registerPushToken`, `notify`, `dispatchUnblock`); vitest green; `dispatchUnblock` fires ~`duration + 8s` after a block in `firebase functions:log`.
- On device: a backgrounded block lifts on its own at expiry; a timeout for one conversation never lifts the shield while another is still blocking (Scenario 2); reset / dismiss / reply make stale timeouts no-op.
- `CLAUDE.md` reflects the new function + `reason` field.
