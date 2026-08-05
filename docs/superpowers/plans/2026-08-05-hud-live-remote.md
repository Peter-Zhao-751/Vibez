# VibezHUD Live Accuracy + 5-Minute Done Expiry + Cross-Device Sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS notch HUD reflect real agent state (it currently runs `--demo`), expire done rows after 5 minutes, and show agent sessions from OTHER devices by comparing the server's event log against the local plugin log.

**Architecture:** Local truth stays the plugins' JSONL sidecar log reduced by `SessionStore`. Remote truth is the Firestore event log (`events/{vibezId}/items`, anonymously readable) that `/notify` writes whenever a `web`-platform device is registered; the HUD self-registers as one, polls via plain REST every 15s, reduces docs to `Session` values, and merges them into the snapshot with local-sid-wins dedupe. Plugins gain a `machine` hostname field so remote rows can be labeled.

**Tech Stack:** Swift 6 (SwiftPM, Swift Testing framework — `import Testing`, NOT XCTest), bash 3.2-compatible plugin scripts, TypeScript Cloud Functions (vitest), Firestore REST API.

**Spec:** `docs/superpowers/specs/2026-08-05-hud-live-remote-design.md`

## Global Constraints

- Plugin mirroring: `post_vibez` / `hud_record` / watcher blocks are mirrored across `ClaudePlugin/`, `CodexPlugin/`, `CursorPlugin/` `scripts/notify.sh` — apply identical hunks (agent tag `cc`/`cx`/`cu` is the only allowed divergence, plus divergences already documented in comments).
- Plugin scripts must stay bash-3.2 compatible (macOS default): no `${var,,}`, no associative arrays, no `mapfile`.
- Swift tests use the Swift Testing framework (`@Test`, `#expect`), matching existing tests in `VibezHUD/Tests/`.
- Vibez ID pattern (4 hyphen-separated 3-5 letter lowercase words): `^[a-z]{3,5}(-[a-z]{3,5}){3}$`.
- `machine` field pattern (server + client): `^[A-Za-z0-9.-]{1,64}$` — invalid values are silently DROPPED, never a request rejection.
- Firebase project `vibez-backend`, Firestore database **"tokens"** (non-default — REST paths must say `databases/tokens`, not `databases/(default)`), functions region `us-central1`.
- The Firebase web API key is NOT secret (ships in every client): `AIzaSyAGhYqKjZt5NlrJa5Cqx4PFSP_wVL6hMkI` (same one as `VibezExtension/src/config.ts`).
- Do NOT add the `machine` field to the APNs payload (`buildApnsPayload` in `Backend/functions/src/scheduling.ts` stays untouched) — zero iOS churn.
- Commit after every task (conventional-commit style, matching `git log`).
- Run commands from the repo root `/Users/peter/Desktop/Vibez` unless a `cd` is shown.

---

### Task 1: Backend accepts + stores `machine`

**Files:**
- Modify: `Backend/functions/src/validation.ts`
- Modify: `Backend/functions/src/index.ts` (the `/notify` handler: field destructure ~line 407, and the `hasWeb` event-doc write ~lines 595-611)
- Test: `Backend/functions/test/validation.test.ts`

**Interfaces:**
- Produces: `MACHINE_PATTERN` export; `NotifyFields.machine?: string`; event docs in `events/{vibezId}/items` may carry `machine: string`. Task 9's REST client and Task 8's parser consume that doc field.

- [ ] **Step 1: Write the failing tests** — append to `Backend/functions/test/validation.test.ts`, following the file's existing import/describe style:

```ts
describe("machine field", () => {
  const base = {vibezId: "moss-pine-fox-jazz", title: "t", body: "b"};

  it("accepts a valid hostname", () => {
    const r = validateNotifyBody({...base, machine: "Peters-MacBook-Pro"});
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.fields.machine).toBe("Peters-MacBook-Pro");
  });

  it("drops an invalid machine without rejecting the request", () => {
    const r = validateNotifyBody({...base, machine: "bad host!$"});
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.fields.machine).toBeUndefined();
  });

  it("drops an over-long machine without rejecting the request", () => {
    const r = validateNotifyBody({...base, machine: "a".repeat(65)});
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.fields.machine).toBeUndefined();
  });

  it("drops a non-string machine without rejecting the request", () => {
    const r = validateNotifyBody({...base, machine: 42});
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.fields.machine).toBeUndefined();
  });

  it("omits machine when absent", () => {
    const r = validateNotifyBody(base);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.fields.machine).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run to verify failure** — `cd Backend/functions && npm test` → the new cases FAIL (machine is currently dropped-by-construction, so `accepts a valid hostname` fails).

- [ ] **Step 3: Implement validation** — in `validation.ts`:

Add below `SESSION_PATTERN`:

```ts
/**
 * Source-Mac label for the HUD's cross-device rows (design spec
 * 2026-08-05). Advisory metadata: an invalid value is DROPPED, never a
 * rejection — a weird hostname must not kill the push it rides on.
 */
export const MACHINE_PATTERN = /^[A-Za-z0-9.-]{1,64}$/;
```

Add `machine?: string;` to `interface NotifyFields` (after `agent?: string;`).

In `validateNotifyBody`, before the final `return {ok: true, fields};`:

```ts
  if (typeof body.machine === "string" && MACHINE_PATTERN.test(body.machine)) {
    fields.machine = body.machine;
  }
```

- [ ] **Step 4: Implement the event-doc write** — in `index.ts`:

Extend the destructure of `validation.fields` (~line 407):

```ts
    const {vibezId, title, body: bodyText, event, shield, session, agent,
      machine} = validation.fields;
```

In the `hasWeb` block (~line 604-607), after `if (agent !== undefined) item.agent = agent;`:

```ts
      if (machine !== undefined) item.machine = machine;
```

- [ ] **Step 5: Run tests + typecheck** — `cd Backend/functions && npm test && npm run build` → all PASS, tsc clean. (Do NOT deploy yet — Task 12.)

- [ ] **Step 6: Commit**

```bash
git add Backend/functions/src/validation.ts Backend/functions/src/index.ts Backend/functions/test/validation.test.ts
git commit -m "feat(backend): accept + store optional machine field on /notify event docs"
```

---

### Task 2: Plugins send `machine` with every push

**Files:**
- Modify: `ClaudePlugin/scripts/notify.sh` (`post_vibez`, ~line 294)
- Modify: `CodexPlugin/scripts/notify.sh` (`post_vibez`, ~line 273)
- Modify: `CursorPlugin/scripts/notify.sh` (`post_vibez`, ~line 271)
- Test: `ClaudePlugin/test/hooks.e2e.sh`, `CursorPlugin/test/hooks.e2e.sh`

**Interfaces:**
- Produces: every `/notify` POST body may carry `machine` (short hostname). Consumed by Task 1's validation. CodexPlugin has no hooks.e2e.sh — its correctness is pinned by a byte-diff against the Claude hunk (Step 5).

- [ ] **Step 1: Write the failing e2e assertion** — in `ClaudePlugin/test/hooks.e2e.sh`, find an existing case that asserts on a captured payload (they parse `${CAPTURE}` with jq). Append a new case near the other payload-shape cases, following the suite's `ok`/`bad` helper pattern:

```bash
# --- machine field rides every push --------------------------------------
reset_capture
printf '{"session_id":"mach-1","cwd":"/tmp/p","hook_event_name":"Notification","message":"Claude needs permission to use Bash"}' \
    | bash "${NOTIFY}" notification
sleep 1
expected_machine="$(hostname -s 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9.-' | cut -c1-64)"
got_machine="$(requests | tail -1 | jq -r '.machine // empty')"
if [ -n "${expected_machine}" ] && [ "${got_machine}" = "${expected_machine}" ]; then
    ok "machine field rides the push"
else
    bad "machine field rides the push" "expected '${expected_machine}' got '${got_machine}'"
fi
```

Mirror the same case into `CursorPlugin/test/hooks.e2e.sh` using that suite's existing invocation style (it feeds Cursor-shaped payloads — reuse one of its existing shield:on cases as the template, asserting `.machine` on the captured body).

- [ ] **Step 2: Run to verify failure** — `bash ClaudePlugin/test/hooks.e2e.sh` → new case FAILS (`.machine` empty).

- [ ] **Step 3: Implement** — in `ClaudePlugin/scripts/notify.sh` `post_vibez()`, after `session="${session:0:128}"`:

```bash
    # Short hostname so the HUD can label cross-device rows. Sanitized to
    # the server's MACHINE_PATTERN charset; the server drops anything
    # invalid rather than rejecting the push.
    local machine
    machine="$(hostname -s 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9.-' | cut -c1-64)"
```

In the payload jq, add `--arg machine "${machine}" \` after `--arg agent "${agent}" \`, and extend the filter's trailing conditionals with:

```
         + (if $machine != "" then {machine:$machine} else {} end)
```

Apply the identical hunk to `CodexPlugin/scripts/notify.sh` and `CursorPlugin/scripts/notify.sh` `post_vibez()` (same insertion points — all three functions are mirrored).

- [ ] **Step 4: Run tests** — `bash ClaudePlugin/test/hooks.e2e.sh && bash CursorPlugin/test/hooks.e2e.sh` → PASS, no regressions. Also `bash ClaudePlugin/scripts/notify.sh _selftest && bash CodexPlugin/scripts/notify.sh _selftest && bash CursorPlugin/scripts/notify.sh _selftest`.

- [ ] **Step 5: Verify the mirror** — the three hunks must be byte-identical:

```bash
for p in ClaudePlugin CodexPlugin CursorPlugin; do
  grep -A4 'Short hostname so the HUD' $p/scripts/notify.sh | md5
done
```

Expected: three identical hashes.

- [ ] **Step 6: Commit**

```bash
git add ClaudePlugin/scripts/notify.sh CodexPlugin/scripts/notify.sh CursorPlugin/scripts/notify.sh ClaudePlugin/test/hooks.e2e.sh CursorPlugin/test/hooks.e2e.sh
git commit -m "feat(plugins): send machine hostname with every /notify push (mirrored x3)"
```

---

### Task 3: Approval watcher writes a HUD record on grant

**Files:**
- Modify: `ClaudePlugin/scripts/notify.sh` (`watch_approval_start`, the process-match block ~line 668)
- Modify: `CodexPlugin/scripts/notify.sh` (`watch_approval_start`, the process-match block ~line 536)
- Test: `ClaudePlugin/test/hooks.e2e.sh` (extend the existing approval-watcher grant case)

**Interfaces:**
- Consumes: `hud_record <kind> <sid> <proj> <cwd> <title> [body] [tool]` (existing writer; empty proj/cwd/title deliberately trigger the store's identity fill-in, keeping the session's existing name).
- Produces: a `kind=tool` JSONL record at grant-detection time; `SessionStore` (unchanged) reduces it to `.working`.

- [ ] **Step 1: Extend the failing e2e case** — `ClaudePlugin/test/hooks.e2e.sh` already has approval-watcher grant cases (grep `approval` to find them; they simulate Notification → matching process appearing → watcher fires). In the grant-success case, after its existing shield:off assertion, add:

```bash
hud_log="${HOME}/.config/vibez/hud/events.jsonl"
watch_rec="$(grep '"kind":"tool"' "${hud_log}" 2>/dev/null | tail -1)"
if printf '%s' "${watch_rec}" | jq -e '.tool == "Bash" and (.body | startswith("(approved:"))' >/dev/null 2>&1; then
    ok "watcher grant writes a HUD tool record"
else
    bad "watcher grant writes a HUD tool record" "got: ${watch_rec:-<none>}"
fi
```

(Adjust `.tool == "Bash"` to whatever tool name that case's payload uses — read the case first.)

- [ ] **Step 2: Run to verify failure** — `bash ClaudePlugin/test/hooks.e2e.sh` → new assertion FAILS (no such record).

- [ ] **Step 3: Implement** — in `ClaudePlugin/scripts/notify.sh` `watch_approval_start()`, inside the `for pid ... do` match block, IMMEDIATELY BEFORE the `if post_vibez ...` line:

```bash
            # HUD: the approved command is RUNNING — flip the row
            # needs-input → working at start, not at completion. Recorded
            # ABOVE the push per the convention (the phone suppresses,
            # the HUD records everything). Empty proj/cwd/title: identity
            # fill-in keeps the session's existing name.
            hud_record "tool" "${sid}" "" "" "" "(approved: ${tool_name})" "${tool_name}"
```

Mirror the identical hunk into `CodexPlugin/scripts/notify.sh` `watch_approval_start()` at the same spot.

- [ ] **Step 4: Run tests** — `bash ClaudePlugin/test/hooks.e2e.sh` → PASS. `bash ClaudePlugin/test/hud.e2e.sh && bash CodexPlugin/test/hud.e2e.sh` → no regressions.

- [ ] **Step 5: Commit**

```bash
git add ClaudePlugin/scripts/notify.sh CodexPlugin/scripts/notify.sh ClaudePlugin/test/hooks.e2e.sh
git commit -m "fix(plugins): approval watcher records the grant in the HUD log (needs-you -> working at command start)"
```

---

### Task 4: 5-minute retention + memory eviction

**Files:**
- Modify: `VibezHUD/Sources/VibezSessionKit/SessionStore.swift` (`StoreConfig` ~line 9; `snapshot()` ~line 77)
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreRetentionTests.swift` (new)

**Interfaces:**
- Consumes: `FakeClock` / `FakeLiveness` (`Tests/.../Support/`), `makeEvent` (defined in `SessionStoreTransitionTests.swift`).
- Produces: `StoreConfig.retentionMs` default `5 * 60 * 1_000`; snapshot-time eviction (a retention-pruned sid returns `nil` from `stateForTesting`). Task 12's live behavior depends on this.

- [ ] **Step 1: Write the failing tests** — new file `SessionStoreRetentionTests.swift`:

```swift
// VibezHUD/Tests/VibezSessionKitTests/SessionStoreRetentionTests.swift
import Testing
@testable import VibezSessionKit

private func newStore(_ clock: FakeClock) -> SessionStore {
    SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
}

@Test func doneRowsExpireFiveMinutesAfterFinishing() {
    let clock = FakeClock(100_000); let s = newStore(clock)
    s.apply(makeEvent(.prompt, ts: 100_000))
    s.apply(makeEvent(.done, ts: 101_000))
    clock.advance(ms: 4_000)                       // grace elapses, done commits
    #expect(s.snapshot().done.map(\.sid) == ["s1"])
    clock.advance(ms: 5 * 60_000 - 4_000)          // 1ms short of 5 min since the done
    #expect(s.snapshot().done.map(\.sid) == ["s1"])
    clock.advance(ms: 2)                           // past 5 min
    #expect(s.snapshot().done.isEmpty)
}

@Test func endedRowsExpireOnTheSameFiveMinuteClock() {
    let clock = FakeClock(100_000); let s = newStore(clock)
    s.apply(makeEvent(.prompt, ts: 100_000))
    s.apply(makeEvent(.end, ts: 101_000))
    #expect(s.snapshot().done.first?.state == .ended)
    clock.advance(ms: 5 * 60_000 + 1_001)
    #expect(s.snapshot().done.isEmpty)
}

@Test func retentionPruningEvictsTheEntryFromMemory() {
    let clock = FakeClock(100_000); let s = newStore(clock)
    s.apply(makeEvent(.prompt, ts: 100_000))
    s.apply(makeEvent(.end, ts: 101_000))
    clock.advance(ms: 5 * 60_000 + 1_001)
    _ = s.snapshot()                               // the prune pass
    #expect(s.stateForTesting(sid: "s1") == nil)   // gone, not just hidden
}

@Test func workingRowsAreNeverTimePruned() {
    let clock = FakeClock(100_000); let s = newStore(clock)
    // Live pid: staleness must not end it, retention must not prune it.
    let live = FakeLiveness(); live.alive = true
    let store = SessionStore(config: StoreConfig(), clock: clock, liveness: live)
    store.apply(makeEvent(.prompt, ts: 100_000, agentPid: 4242, agentStart: "x"))
    clock.advance(ms: 60 * 60_000)
    #expect(store.snapshot().working.map(\.sid) == ["s1"])
}
```

Check `Support/FakeLiveness.swift` first: if its alive-control property is named differently (e.g. a constructor flag or a dictionary), adapt the last test to the actual API rather than adding one.

- [ ] **Step 2: Run to verify failure** — `cd VibezHUD && swift test` → `doneRowsExpireFiveMinutesAfterFinishing` and `retentionPruningEvictsTheEntryFromMemory` FAIL (retention is 60 min; eviction doesn't exist).

- [ ] **Step 3: Implement** — in `SessionStore.swift`:

`StoreConfig` default (line ~9): change `retentionMs: Int64 = 60 * 60 * 1_000` to:

```swift
                retentionMs: Int64 = 5 * 60 * 1_000,
```

Also update the doc comment above it if one exists. In `snapshot()`, replace the entry loop with an evicting version:

```swift
        var evicted: [String] = []
        for (sid, entry) in entries {
            guard var s = resolve(entry, now: now) else {
                // resolve() returns nil ONLY for retention-pruned done/ended
                // rows — evict, or a long-lived HUD accumulates one Entry
                // per sid forever.
                evicted.append(sid)
                continue
            }
            s.detail = s.detail?.isEmpty == true ? nil : s.detail
            switch s.state {
            case .needsYou: needsYou.append(s)
            case .working:  working.append(s)
            case .done, .ended: done.append(s)
            case .idle: continue
            }
        }
        for sid in evicted { entries.removeValue(forKey: sid) }
```

- [ ] **Step 4: Run the full Swift suite** — `cd VibezHUD && swift test`. Any existing test that encoded the 60-minute default (search for `retention` and `60 * 60`) must be updated to the new default or given an explicit `StoreConfig(retentionMs:)`. Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/SessionStore.swift VibezHUD/Tests/VibezSessionKitTests/SessionStoreRetentionTests.swift
git commit -m "feat(hud): done/ended rows expire after 5 minutes and evict from memory"
```

---

### Task 5: Sticky done commit (no re-opened grace flash)

**Files:**
- Modify: `VibezHUD/Sources/VibezSessionKit/SessionStore.swift` (`apply` done-case ~line 72, `resolve` ~line 125, `snapshot`, `stateForTesting`)
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreGraceTests.swift` (append)

**Interfaces:**
- Produces: once a done commits, the stored `entry.session.state` IS `.done` (persisted, not recomputed per snapshot). Existing behavior preserved: pre-commit repeats restart the grace from the latest done; any non-done event cancels a pending done.

- [ ] **Step 1: Write the failing tests** — append to `SessionStoreGraceTests.swift`:

```swift
@Test func repeatedDoneAfterCommitDoesNotReopenTheGraceWindow() {
    // The flash bug: a second Stop on an already-done session used to
    // overwrite pendingDoneAtMs, and the display reverted to the stored
    // pre-done state for 3s.
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .done)   // committed
    s.apply(makeEvent(.done, ts: 13_100))
    #expect(s.stateForTesting(sid: "s1") == .done)   // STAYS done — no flash
    clock.advance(ms: 10_000)
    #expect(s.stateForTesting(sid: "s1") == .done)
}

@Test func activityAfterACommittedDoneStillResumesWorking() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .done)
    s.apply(makeEvent(.prompt, ts: 14_000))
    #expect(s.stateForTesting(sid: "s1") == .working)
    // stateSince reflects the resume, not the pre-done working stretch.
    #expect(s.snapshot().working.first?.stateSinceMs == 14_000)
}
```

- [ ] **Step 2: Run to verify failure** — `cd VibezHUD && swift test --filter SessionStoreGraceTests` → `repeatedDoneAfterCommitDoesNotReopenTheGraceWindow` FAILS.

- [ ] **Step 3: Implement** — in `SessionStore.swift`:

Add a commit pass (private method):

```swift
    /// Commit provisional dones whose grace window has elapsed, INTO the
    /// stored entry. Persisting the commit is what makes done sticky: a
    /// later duplicate `done` finds state == .done and leaves it alone,
    /// instead of re-opening the grace window and flashing the row back
    /// to its pre-done state.
    private func commitPendingDones(now: Int64) {
        for (sid, var entry) in entries {
            guard let pending = entry.pendingDoneAtMs,
                  now - pending >= config.stopGraceMs else { continue }
            entry.session.state = .done
            entry.session.stateSinceMs = pending
            entry.pendingDoneAtMs = nil
            entries[sid] = entry
        }
    }
```

Call it first in both public read paths:
- `snapshot()`: `commitPendingDones(now: now)` immediately after `let now = clock.nowMs`.
- `stateForTesting(sid:)`: `commitPendingDones(now: clock.nowMs)` before the entry lookup.

In `resolve(_:now:ignoringRetention:)`, DELETE the pending-commit branch (lines ~124-128, the `if let pending = entry.pendingDoneAtMs ...` block) — commitment now happens in `commitPendingDones`.

In `apply`, change the done case:

```swift
        case .done:
            // Already-committed done: a repeated Stop refreshes recency
            // only. Re-arming the grace would revert the display for 3s.
            if entry.session.state != .done { entry.pendingDoneAtMs = e.ts }
```

- [ ] **Step 4: Run the full Swift suite** — `cd VibezHUD && swift test`. All grace tests must still pass (`repeatedDoneCommitsOnceAtTheLatestTimestamp` exercises PRE-commit repeats — unchanged behavior). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/SessionStore.swift VibezHUD/Tests/VibezSessionKitTests/SessionStoreGraceTests.swift
git commit -m "fix(hud): committed done is sticky - duplicate Stops no longer flash the row"
```

---

### Task 6: `start` resets a finished session

**Files:**
- Modify: `VibezHUD/Sources/VibezSessionKit/SessionStore.swift` (`apply` start-case ~line 68)
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreTransitionTests.swift` (append + amend matrix)

**Interfaces:**
- Produces: `start` on an entry in `.ended` or `.done` → `.idle` (fresh `stateSinceMs`); all other states unchanged by `start`.

- [ ] **Step 1: Write the failing test** — append to `SessionStoreTransitionTests.swift`:

```swift
@Test func startOnAFinishedSessionResetsToIdle() {
    // Resume bug: a session that ended (explicit end, or probed-dead pid)
    // showed "ended" in the done column until the first prompt.
    let clock = FakeClock(10_000); let s = newStore(clock)
    s.apply(makeEvent(.prompt, ts: 10_000))
    s.apply(makeEvent(.end, ts: 11_000))
    #expect(s.stateForTesting(sid: "s1") == .ended)
    s.apply(makeEvent(.start, ts: 12_000))
    #expect(s.stateForTesting(sid: "s1") == .idle)   // no "ended" ghost
    s.apply(makeEvent(.prompt, ts: 13_000))
    #expect(s.stateForTesting(sid: "s1") == .working)
}
```

Then amend `fullTransitionMatrix`: the `.ended` row's `.start` expectation changes from `.ended` to `.idle`.

- [ ] **Step 2: Run to verify failure** — `cd VibezHUD && swift test --filter SessionStoreTransitionTests` → both FAIL.

- [ ] **Step 3: Implement** — in `apply`, change the start case:

```swift
        case .start:
            // A fresh start on a FINISHED session is a resume — reset to
            // idle so the row doesn't show "ended"/"done" until the first
            // prompt. Live states (working/needsYou) are untouched: a
            // start record there is a replay/rotation artifact.
            if entry.session.state == .ended || entry.session.state == .done {
                setState(&entry, .idle, at: e.ts)
            }
```

- [ ] **Step 4: Run the full Swift suite** — `cd VibezHUD && swift test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/SessionStore.swift VibezHUD/Tests/VibezSessionKitTests/SessionStoreTransitionTests.swift
git commit -m "fix(hud): session resume (start after ended/done) resets the row to idle"
```

---

### Task 7: `Session.machine` + `snapshot(remote:)` merge + probe output

**Files:**
- Modify: `VibezHUD/Sources/VibezSessionKit/Session.swift`
- Modify: `VibezHUD/Sources/VibezSessionKit/SessionStore.swift` (`snapshot`)
- Modify: `VibezHUD/Sources/vibez-hud-probe/main.swift` (`rows`)
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreRemoteMergeTests.swift` (new)

**Interfaces:**
- Produces: `Session.machine: String?` (nil = local row; init param `machine: String? = nil` appended after `app:`); `SessionStore.snapshot(remote: [Session] = []) -> HUDSnapshot` — remote sessions merged into columns, dropped when their sid exists in the local entries dict; probe rows carry `"machine"` when present. Tasks 8/10 consume both.

- [ ] **Step 1: Write the failing tests** — new file `SessionStoreRemoteMergeTests.swift`:

```swift
// VibezHUD/Tests/VibezSessionKitTests/SessionStoreRemoteMergeTests.swift
import Testing
@testable import VibezSessionKit

private func remoteSession(sid: String, state: SessionState, machine: String = "mbp-air",
                           atMs ts: Int64) -> Session {
    Session(sid: sid, agent: .codex, proj: "", cwd: "", title: "Remote task",
            detail: nil, tool: nil, state: state,
            startedAtMs: ts, lastActivityMs: ts, stateSinceMs: ts,
            agentPid: nil, agentStart: nil, appPid: nil, app: nil,
            machine: machine)
}

@Test func remoteSessionsJoinTheirColumns() {
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    let snap = s.snapshot(remote: [
        remoteSession(sid: "r1", state: .needsYou, atMs: 99_000),
        remoteSession(sid: "r2", state: .done, atMs: 99_500),
        remoteSession(sid: "r3", state: .working, atMs: 99_900),
    ])
    #expect(snap.needsYou.map(\.sid) == ["r1"])
    #expect(snap.done.map(\.sid) == ["r2"])
    #expect(snap.working.map(\.sid) == ["r3"])
    #expect(snap.needsYou.first?.machine == "mbp-air")
}

@Test func localSidWinsOverItsRemoteEcho() {
    // The local log is strictly richer — a session this Mac owns must not
    // duplicate as a remote row when its push echoes back via the server.
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 99_000, sid: "shared"))
    let snap = s.snapshot(remote: [remoteSession(sid: "shared", state: .done, atMs: 99_500)])
    #expect(snap.working.map(\.sid) == ["shared"])   // local working row
    #expect(snap.done.isEmpty)                       // remote echo dropped
}

@Test func remoteRowsSortWithLocalRows() {
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.needsInput, ts: 99_800, sid: "local"))
    let snap = s.snapshot(remote: [remoteSession(sid: "r1", state: .needsYou, atMs: 99_100)])
    // needsYou sorts longest-wait-first: the remote row has waited longer.
    #expect(snap.needsYou.map(\.sid) == ["r1", "local"])
}

@Test func localSessionsHaveNilMachine() {
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 99_000))
    #expect(s.snapshot().working.first?.machine == nil)
}
```

- [ ] **Step 2: Run to verify failure** — `cd VibezHUD && swift test` → does not compile (`machine` unknown) — that counts as the failing state.

- [ ] **Step 3: Implement** —

`Session.swift`: add `public var machine: String?` after `public var app: String?`, and extend the init with a defaulted trailing parameter + assignment:

```swift
    public init(sid: String, agent: AgentTag, proj: String, cwd: String, title: String,
                detail: String?, tool: String?, state: SessionState,
                startedAtMs: Int64, lastActivityMs: Int64, stateSinceMs: Int64,
                agentPid: Int32?, agentStart: String?, appPid: Int32?, app: String?,
                machine: String? = nil) {
        // ... existing assignments ...
        self.machine = machine
    }
```

`SessionStore.swift`: change the signature to `public func snapshot(remote: [Session] = []) -> HUDSnapshot` and, after the local entry loop + eviction (before the sorts), add:

```swift
        // Remote rows — server-derived sessions from OTHER machines,
        // pre-resolved by RemoteReducer. Local wins: a sid the local log
        // already knows is dropped (the local reducer is strictly richer,
        // and every local push echoes back through the server log).
        for var s in remote where entries[s.sid] == nil {
            s.detail = s.detail?.isEmpty == true ? nil : s.detail
            switch s.state {
            case .needsYou: needsYou.append(s)
            case .working:  working.append(s)
            case .done, .ended: done.append(s)
            case .idle: continue
            }
        }
```

`vibez-hud-probe/main.swift` `rows(_:)`: after the `detail` line add:

```swift
        if let m = s.machine { row["machine"] = m }
```

- [ ] **Step 4: Run the full Swift suite** — `cd VibezHUD && swift test && swift build --product vibez-hud-probe` → PASS.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/Session.swift VibezHUD/Sources/VibezSessionKit/SessionStore.swift VibezHUD/Sources/vibez-hud-probe/main.swift VibezHUD/Tests/VibezSessionKitTests/SessionStoreRemoteMergeTests.swift
git commit -m "feat(hud): Session.machine + snapshot(remote:) merge with local-sid-wins dedupe"
```

---

### Task 8: RemoteEventDoc + Firestore REST parser + RemoteReducer

**Files:**
- Create: `VibezHUD/Sources/VibezSessionKit/RemoteEvents.swift`
- Test: `VibezHUD/Tests/VibezSessionKitTests/RemoteEventsTests.swift` (new)

**Interfaces:**
- Produces (consumed by Tasks 9/10):
  - `public struct RemoteEventDoc: Codable, Sendable, Equatable { session, agent: String; event, shield, body, machine: String?; title: String; createdAtMs: Int64 }`
  - `public enum FirestoreRESTParser { public static func parse(_ data: Data) -> [RemoteEventDoc] }`
  - `public enum RemoteReducer { public static func sessions(docs: [RemoteEventDoc], now: Int64, config: StoreConfig = StoreConfig()) -> [Session] }`

- [ ] **Step 1: Write the failing tests** — new file `RemoteEventsTests.swift`:

```swift
// VibezHUD/Tests/VibezSessionKitTests/RemoteEventsTests.swift
import Foundation
import Testing
@testable import VibezSessionKit

private func doc(_ session: String, event: String?, shield: String? = nil,
                 agent: String = "cc", machine: String? = "mbp-air",
                 atMs: Int64) -> RemoteEventDoc {
    RemoteEventDoc(session: session, agent: agent, event: event, shield: shield,
                   title: "T", body: "B", machine: machine, createdAtMs: atMs)
}

// MARK: - REST parsing

@Test func parsesARunQueryResponse() {
    let json = """
    [
      {"document": {"name": "projects/p/databases/tokens/documents/events/id/items/a1",
        "fields": {
          "title": {"stringValue": "Claude is done"},
          "body": {"stringValue": "Finished."},
          "event": {"stringValue": "done"},
          "shield": {"stringValue": "on"},
          "session": {"stringValue": "sess-1"},
          "agent": {"stringValue": "cc"},
          "machine": {"stringValue": "mbp-air"},
          "createdAtMs": {"integerValue": "170000"}
        }}, "readTime": "2026-08-05T00:00:00Z"},
      {"readTime": "2026-08-05T00:00:00Z"}
    ]
    """
    let docs = FirestoreRESTParser.parse(json.data(using: .utf8)!)
    #expect(docs.count == 1)
    #expect(docs.first == RemoteEventDoc(session: "sess-1", agent: "cc", event: "done",
                                         shield: "on", title: "Claude is done", body: "Finished.",
                                         machine: "mbp-air", createdAtMs: 170_000))
}

@Test func parserSkipsDocsWithoutAUsableSession() {
    let json = """
    [{"document": {"name": "x", "fields": {
        "title": {"stringValue": "test ping"}, "createdAtMs": {"integerValue": "1"}}}},
     {"document": {"name": "y", "fields": {
        "title": {"stringValue": "t"}, "session": {"stringValue": "nosid"},
        "createdAtMs": {"integerValue": "2"}}}}]
    """
    #expect(FirestoreRESTParser.parse(json.data(using: .utf8)!).isEmpty)
}

@Test func parserToleratesGarbage() {
    #expect(FirestoreRESTParser.parse(Data("not json".utf8)).isEmpty)
    #expect(FirestoreRESTParser.parse(Data("{}".utf8)).isEmpty)
}

// MARK: - reduction

@Test func newestDocPerSessionWins() {
    let sessions = RemoteReducer.sessions(docs: [
        doc("s", event: "done", atMs: 2_000),
        doc("s", event: "needs-input", atMs: 1_000),
    ], now: 10_000)
    #expect(sessions.map(\.state) == [.done])
}

@Test func eventMappingMatchesTheSpec() {
    let now: Int64 = 100_000
    #expect(RemoteReducer.sessions(docs: [doc("a", event: "needs-input", atMs: now)], now: now).first?.state == .needsYou)
    #expect(RemoteReducer.sessions(docs: [doc("b", event: "done", atMs: now)], now: now).first?.state == .done)
    #expect(RemoteReducer.sessions(docs: [doc("c", event: "replied", atMs: now)], now: now).first?.state == .working)
    // shield:off with no event (timeout-ish shapes) also means resumed.
    #expect(RemoteReducer.sessions(docs: [doc("d", event: nil, shield: "off", atMs: now)], now: now).first?.state == .working)
    // A needs-input whose doc says shield off is a reply race — resumed wins.
    #expect(RemoteReducer.sessions(docs: [doc("e", event: "needs-input", shield: "off", atMs: now)], now: now).first?.state == .working)
    // No event, shield on: informational — no row.
    #expect(RemoteReducer.sessions(docs: [doc("f", event: nil, shield: "on", atMs: now)], now: now).isEmpty)
}

@Test func remoteDoneExpiresAfterRetention() {
    let d = [doc("s", event: "done", atMs: 0)]
    #expect(RemoteReducer.sessions(docs: d, now: 5 * 60_000 - 1).count == 1)
    #expect(RemoteReducer.sessions(docs: d, now: 5 * 60_000 + 1).isEmpty)
}

@Test func remoteNonDoneGoesStaleAfterStaleMs() {
    let d = [doc("s", event: "needs-input", atMs: 0)]
    #expect(RemoteReducer.sessions(docs: d, now: 30 * 60_000 - 1).count == 1)
    #expect(RemoteReducer.sessions(docs: d, now: 30 * 60_000 + 1).isEmpty)
}

@Test func machineFallsBackToRemote() {
    let s = RemoteReducer.sessions(docs: [doc("s", event: "done", machine: nil, atMs: 0)], now: 0)
    #expect(s.first?.machine == "remote")
}

@Test func agentTagDecodesWithClaudeFallback() {
    let s = RemoteReducer.sessions(docs: [doc("s", event: "done", agent: "cx", atMs: 0),
                                          doc("t", event: "done", agent: "??", atMs: 0)], now: 0)
    #expect(s.first(where: { $0.sid == "s" })?.agent == .codex)
    #expect(s.first(where: { $0.sid == "t" })?.agent == .claude)
}
```

- [ ] **Step 2: Run to verify failure** — `cd VibezHUD && swift test` → compile failure (types missing).

- [ ] **Step 3: Implement** — new file `RemoteEvents.swift`:

```swift
import Foundation

/// One event doc from the server's per-Vibez-ID log
/// (`events/{vibezId}/items` in the "tokens" Firestore database) — the
/// same log the Chrome extension listens to. Codable so probe fixtures
/// can inject canned docs without any network.
public struct RemoteEventDoc: Codable, Sendable, Equatable {
    public var session: String
    public var agent: String
    public var event: String?
    public var shield: String?
    public var title: String
    public var body: String?
    public var machine: String?
    public var createdAtMs: Int64

    public init(session: String, agent: String, event: String?, shield: String?,
                title: String, body: String?, machine: String?, createdAtMs: Int64) {
        self.session = session; self.agent = agent; self.event = event
        self.shield = shield; self.title = title; self.body = body
        self.machine = machine; self.createdAtMs = createdAtMs
    }
}

/// Decodes a Firestore REST `documents:runQuery` response. Tolerant by
/// design: bare read-time rows, unknown fields and malformed docs are
/// skipped — a bad server response must never take down the panel.
public enum FirestoreRESTParser {
    public static func parse(_ data: Data) -> [RemoteEventDoc] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let document = row["document"] as? [String: Any],
                  let fields = document["fields"] as? [String: Any] else { return nil }
            func str(_ key: String) -> String? {
                (fields[key] as? [String: Any])?["stringValue"] as? String
            }
            func int(_ key: String) -> Int64? {
                let v = fields[key] as? [String: Any]
                if let s = v?["integerValue"] as? String { return Int64(s) }
                if let d = v?["doubleValue"] as? Double { return Int64(d) }
                return nil
            }
            guard let session = str("session"), !session.isEmpty, session != "nosid",
                  let createdAtMs = int("createdAtMs") else { return nil }
            return RemoteEventDoc(session: session,
                                  agent: str("agent") ?? "cc",
                                  event: str("event"),
                                  shield: str("shield"),
                                  title: str("title") ?? "",
                                  body: str("body"),
                                  machine: str("machine"),
                                  createdAtMs: createdAtMs)
        }
    }
}

/// Folds raw event docs into displayable remote `Session`s. The server
/// only sees phone-worthy moments, so the mapping is deliberately
/// coarse: needs-input → needsYou, done → done, replied/shield-off →
/// working (the user answered; the agent resumed). Time rules mirror
/// the local store: done expires after `retentionMs`, anything else
/// goes stale after `staleMs` (remote rows have no pid to probe).
public enum RemoteReducer {
    public static func sessions(docs: [RemoteEventDoc], now: Int64,
                                config: StoreConfig = StoreConfig()) -> [Session] {
        var newest: [String: RemoteEventDoc] = [:]
        for d in docs where (newest[d.session]?.createdAtMs ?? .min) < d.createdAtMs {
            newest[d.session] = d
        }
        return newest.values.compactMap { d in
            let state: SessionState
            if d.shield == "off" || d.event == "replied" {
                state = .working
            } else if d.event == "needs-input" {
                state = .needsYou
            } else if d.event == "done" {
                state = .done
            } else {
                return nil   // informational push — no row
            }
            let age = now - d.createdAtMs
            if state == .done { if age > config.retentionMs { return nil } }
            else if age > config.staleMs { return nil }
            return Session(sid: d.session,
                           agent: AgentTag(rawValue: d.agent) ?? .claude,
                           proj: "", cwd: "", title: d.title,
                           detail: d.body, tool: nil, state: state,
                           startedAtMs: d.createdAtMs, lastActivityMs: d.createdAtMs,
                           stateSinceMs: d.createdAtMs,
                           agentPid: nil, agentStart: nil, appPid: nil, app: nil,
                           machine: d.machine ?? "remote")
        }
    }
}
```

- [ ] **Step 4: Run the full Swift suite** — `cd VibezHUD && swift test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/RemoteEvents.swift VibezHUD/Tests/VibezSessionKitTests/RemoteEventsTests.swift
git commit -m "feat(hud): Firestore REST parser + remote-session reducer"
```

---

### Task 9: RemoteSessionSource (polling + web registration)

**Files:**
- Create: `VibezHUD/Sources/VibezSessionKit/RemoteSessionSource.swift`
- Test: `VibezHUD/Tests/VibezSessionKitTests/RemoteSessionSourceTests.swift` (new)

**Interfaces:**
- Consumes: `FirestoreRESTParser`, `RemoteReducer`, `RemoteEventDoc` (Task 8); `HUDPaths.configDir` / `HUDPaths.hudDir`.
- Produces (consumed by Task 10):
  - `public protocol RemoteEventsFetching: Sendable { func registerIfNeeded() async throws; func fetchRecentEvents() async throws -> [RemoteEventDoc] }`
  - `public final class FirestoreRESTClient: RemoteEventsFetching`
  - `public final class RemoteSessionSource` with `init(fetcher:config:pollIntervalMs:)`, `start()`, `stop()`, `pollOnce() async`, `currentSessions(now:) -> [Session]`, and `static func makeDefault() -> RemoteSessionSource?`.

- [ ] **Step 1: Write the failing tests** — new file `RemoteSessionSourceTests.swift`:

```swift
// VibezHUD/Tests/VibezSessionKitTests/RemoteSessionSourceTests.swift
import Foundation
import Testing
@testable import VibezSessionKit

private final class FakeFetcher: RemoteEventsFetching, @unchecked Sendable {
    var docs: [RemoteEventDoc] = []
    var registered = 0
    var fetches = 0
    var shouldThrow = false
    func registerIfNeeded() async throws { registered += 1 }
    func fetchRecentEvents() async throws -> [RemoteEventDoc] {
        fetches += 1
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        return docs
    }
}

@Test func pollOnceRegistersThenFetchesAndExposesSessions() async {
    let f = FakeFetcher()
    f.docs = [RemoteEventDoc(session: "r1", agent: "cx", event: "needs-input", shield: "on",
                             title: "Deploy?", body: nil, machine: "mini", createdAtMs: 1_000)]
    let src = RemoteSessionSource(fetcher: f)
    await src.pollOnce()
    #expect(f.registered == 1 && f.fetches == 1)
    let rows = src.currentSessions(now: 2_000)
    #expect(rows.map(\.sid) == ["r1"])
    #expect(rows.first?.machine == "mini")
}

@Test func fetchFailureKeepsThePreviousDocs() async {
    let f = FakeFetcher()
    f.docs = [RemoteEventDoc(session: "r1", agent: "cc", event: "done", shield: nil,
                             title: "T", body: nil, machine: nil, createdAtMs: 1_000)]
    let src = RemoteSessionSource(fetcher: f)
    await src.pollOnce()
    #expect(src.currentSessions(now: 2_000).count == 1)
    f.shouldThrow = true
    await src.pollOnce()
    // Stale-but-present beats empty; the reducer's time rules age it out.
    #expect(src.currentSessions(now: 2_000).count == 1)
}

@Test func registrationFailureStillAllowsFetching() async {
    final class RegFails: RemoteEventsFetching, @unchecked Sendable {
        var fetches = 0
        func registerIfNeeded() async throws { throw URLError(.timedOut) }
        func fetchRecentEvents() async throws -> [RemoteEventDoc] { fetches += 1; return [] }
    }
    let f = RegFails()
    let src = RemoteSessionSource(fetcher: f)
    await src.pollOnce()
    await src.pollOnce()
    #expect(f.fetches == 2)   // fetch proceeds; registration retries silently
}

@Test func makeDefaultHonorsTheKillSwitchAndMissingId() {
    // Pure decision logic, factored so it's testable without env mutation.
    #expect(RemoteSessionSource.shouldEnable(vibezId: "moss-pine-fox-jazz", killSwitch: "1") == false)
    #expect(RemoteSessionSource.shouldEnable(vibezId: nil, killSwitch: nil) == false)
    #expect(RemoteSessionSource.shouldEnable(vibezId: "not a valid id", killSwitch: nil) == false)
    #expect(RemoteSessionSource.shouldEnable(vibezId: "moss-pine-fox-jazz", killSwitch: nil) == true)
}
```

- [ ] **Step 2: Run to verify failure** — `cd VibezHUD && swift test` → compile failure.

- [ ] **Step 3: Implement** — new file `RemoteSessionSource.swift`:

```swift
import Foundation

/// Network seam for the remote-session feature. Protocol-shaped so unit
/// tests inject canned docs — no network in tests, ever.
public protocol RemoteEventsFetching: Sendable {
    /// Idempotent: ensure this HUD is registered as a `web` device for
    /// the Vibez ID (that registration is what turns ON the server-side
    /// event-log write — the `hasWeb` gate in /notify).
    func registerIfNeeded() async throws
    func fetchRecentEvents() async throws -> [RemoteEventDoc]
}

/// Anonymous Firestore REST reads + the registerPushToken callable.
/// Mirrors the Chrome extension's mechanism (VibezExtension/src/background/
/// firestore.ts) minus the SDK: the API key is the iOS app's non-secret
/// key, reads are gated by security rules (`read: if true` on the events
/// path), and the client id doubles as the device-doc id.
public final class FirestoreRESTClient: RemoteEventsFetching, @unchecked Sendable {
    private let vibezId: String
    private let clientIdURL: URL
    private let session: URLSession
    private var didRegister = false
    private let lock = NSLock()

    private static let apiKey = "AIzaSyAGhYqKjZt5NlrJa5Cqx4PFSP_wVL6hMkI"
    private static let queryURLBase =
        "https://firestore.googleapis.com/v1/projects/vibez-backend/databases/tokens/documents/events/"
    private static let registerURL =
        URL(string: "https://us-central1-vibez-backend.cloudfunctions.net/registerPushToken")!

    public init(vibezId: String,
                clientIdURL: URL = HUDPaths.hudDir.appendingPathComponent("web-client-id"),
                session: URLSession = .shared) {
        self.vibezId = vibezId; self.clientIdURL = clientIdURL; self.session = session
    }

    public func registerIfNeeded() async throws {
        lock.lock()
        let done = didRegister
        lock.unlock()
        guard !done else { return }
        let clientId = try loadOrCreateClientId()
        var req = URLRequest(url: Self.registerURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": ["fcmToken": clientId, "vibezId": vibezId, "platform": "web"],
        ])
        let (_, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        lock.lock(); didRegister = true; lock.unlock()
    }

    public func fetchRecentEvents() async throws -> [RemoteEventDoc] {
        var comps = URLComponents(string: Self.queryURLBase + vibezId + ":runQuery")!
        comps.queryItems = [URLQueryItem(name: "key", value: Self.apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "structuredQuery": [
                "from": [["collectionId": "items"]],
                "orderBy": [["field": ["fieldPath": "createdAtMs"],
                             "direction": "DESCENDING"]],
                "limit": 50,
            ],
        ])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return FirestoreRESTParser.parse(data)
    }

    /// A persisted random 32-hex id — it IS the device-doc id server-side,
    /// so it must survive relaunches or every launch would leak one of the
    /// Vibez ID's 10 device slots.
    private func loadOrCreateClientId() throws -> String {
        if let existing = try? String(contentsOf: clientIdURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count == 32 { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try FileManager.default.createDirectory(at: clientIdURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try fresh.write(to: clientIdURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: clientIdURL.path)
        return fresh
    }
}

/// Holds the latest server docs and hands reduced remote sessions to the
/// snapshot path. `start()` spawns one detached polling loop; reads are
/// lock-guarded so the 5 Hz snapshot path never blocks on the network.
public final class RemoteSessionSource: @unchecked Sendable {
    private let fetcher: any RemoteEventsFetching
    private let config: StoreConfig
    private let pollIntervalMs: Int64
    private var latestDocs: [RemoteEventDoc] = []
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(fetcher: any RemoteEventsFetching,
                config: StoreConfig = StoreConfig(),
                pollIntervalMs: Int64 = 15_000) {
        self.fetcher = fetcher; self.config = config; self.pollIntervalMs = pollIntervalMs
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                guard let interval = self?.pollIntervalMs else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    public func pollOnce() async {
        // Registration failure must not block reads: the log may already
        // exist (Chrome extension registered), and registration retries
        // on the next poll anyway.
        try? await fetcher.registerIfNeeded()
        guard let docs = try? await fetcher.fetchRecentEvents() else { return }
        lock.lock(); latestDocs = docs; lock.unlock()
    }

    public func currentSessions(now: Int64) -> [Session] {
        lock.lock(); let docs = latestDocs; lock.unlock()
        return RemoteReducer.sessions(docs: docs, now: now, config: config)
    }

    /// Pure enablement rule, seamed out of makeDefault for testability.
    public static func shouldEnable(vibezId: String?, killSwitch: String?) -> Bool {
        guard killSwitch != "1" else { return false }
        guard let id = vibezId else { return false }
        return id.range(of: #"^[a-z]{3,5}(-[a-z]{3,5}){3}$"#,
                        options: .regularExpression) != nil
    }

    /// nil when the feature is off: kill switch set, or no (valid) Vibez
    /// ID paired on this Mac. The HUD stays fully offline in that case.
    public static func makeDefault() -> RemoteSessionSource? {
        let killSwitch = ProcessInfo.processInfo.environment["VIBEZ_HUD_NO_REMOTE"]
        let idURL = HUDPaths.configDir.appendingPathComponent("vibez-id")
        let vibezId = (try? String(contentsOf: idURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldEnable(vibezId: vibezId, killSwitch: killSwitch),
              let id = vibezId else { return nil }
        return RemoteSessionSource(fetcher: FirestoreRESTClient(vibezId: id))
    }
}
```

- [ ] **Step 4: Run the full Swift suite** — `cd VibezHUD && swift test` → PASS.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/RemoteSessionSource.swift VibezHUD/Tests/VibezSessionKitTests/RemoteSessionSourceTests.swift
git commit -m "feat(hud): remote session source - REST polling + one-time web registration"
```

---

### Task 10: Wire remote into engine/app + hostname badge + demo + probe fixture

**Files:**
- Modify: `VibezHUD/Sources/VibezSessionKit/HUDEngine.swift`
- Modify: `VibezHUD/Sources/VibezHUDApp/HUDViewModel.swift` (init ~line 49, `start()` ~line 56)
- Modify: `VibezHUD/Sources/VibezHUDApp/Views/SessionTile.swift` (header HStack ~line 84)
- Modify: `VibezHUD/Sources/VibezHUDApp/DemoData.swift`
- Modify: `VibezHUD/Sources/vibez-hud-probe/main.swift`
- Test: `Tests/hud-e2e.sh` (append a remote-fixture case)

**Interfaces:**
- Consumes: Tasks 7-9 (`snapshot(remote:)`, `RemoteSessionSource`, `RemoteEventDoc` Codable).
- Produces: `HUDEngine(logURL:config:clock:liveness:remote:)` + `HUDEngine.startRemote()`; probe usage `vibez-hud-probe [events.jsonl] [remote-fixture.json]` where the fixture is a JSON array of `RemoteEventDoc`.

- [ ] **Step 1: Engine** — `HUDEngine.swift` becomes:

```swift
import Foundation

/// Reader + store wired together. The single entry point used by both the app
/// and the probe, so the two can never drift.
public final class HUDEngine {
    private let reader: EventLogReader
    private let store: SessionStore
    private let clock: any Clock
    private let remote: RemoteSessionSource?

    public init(logURL: URL = HUDPaths.defaultLogURL,
                config: StoreConfig = StoreConfig(),
                clock: any Clock = SystemClock(),
                liveness: any LivenessProbe = POSIXLivenessProbe(),
                remote: RemoteSessionSource? = nil) {
        self.reader = EventLogReader(url: logURL)
        self.store = SessionStore(config: config, clock: clock, liveness: liveness)
        self.clock = clock
        self.remote = remote
    }

    /// Begin the remote polling loop (no-op when the feature is off).
    public func startRemote() { remote?.start() }

    /// Cold start: bounded tail replay, then a snapshot.
    @discardableResult
    public func primeAndDrain(tailBytes: Int = HUDPaths.coldStartTailBytes) -> HUDSnapshot {
        for e in reader.primeFromTail(maxBytes: tailBytes) { store.apply(e) }
        for e in reader.readNew() { store.apply(e) }
        return snapshotWithRemote()
    }

    /// Drain whatever is new and re-snapshot. Safe to call on a timer.
    public func poll() -> HUDSnapshot {
        for e in reader.readNew() { store.apply(e) }
        return snapshotWithRemote()
    }

    private func snapshotWithRemote() -> HUDSnapshot {
        store.snapshot(remote: remote?.currentSessions(now: clock.nowMs) ?? [])
    }
}
```

- [ ] **Step 2: App wiring** — `HUDViewModel.swift` init line 49: `engine = demo ? nil : HUDEngine(remote: RemoteSessionSource.makeDefault())`. In `start()`: add `engine?.startRemote()` before `schedule(fast: false)`.

- [ ] **Step 3: Badge** — in `SessionTile.swift`, inside the header `HStack`, between `Text(session.proj)` and `Spacer(minLength: 4)`:

```swift
                    if let machine = session.machine {
                        Text(machine)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.12)))
                    }
```

- [ ] **Step 4: Demo row** — in `DemoData.swift`, extend the helper with a trailing `machine: String? = nil` parameter (pass it through to `Session`), and add to `needsYou`:

```swift
                s("d7", .claude, "", "Migrate the auth tests", .needsYou, nil, "which fixture layout?", 95_000, machine: "mbp-air"),
```

(Adjust the helper's signature/callers accordingly — every existing call keeps compiling because the parameter is defaulted.)

- [ ] **Step 5: Probe fixture arg** — `vibez-hud-probe/main.swift`: usage becomes `vibez-hud-probe [events.jsonl] [remote-fixture.json]`. After building the engine's snapshot, if a second argument exists, decode `[RemoteEventDoc]` with `JSONDecoder` and merge via a locally-built store — simplest correct shape: build the engine WITHOUT remote, then post-process:

```swift
let fixtureDocs: [RemoteEventDoc]
if CommandLine.arguments.count > 2,
   let data = FileManager.default.contents(atPath: CommandLine.arguments[2]) {
    fixtureDocs = (try? JSONDecoder().decode([RemoteEventDoc].self, from: data)) ?? []
} else {
    fixtureDocs = []
}
```

and replace `let snap = engine.primeAndDrain()` with:

```swift
var snap = engine.primeAndDrain()
if !fixtureDocs.isEmpty {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    snap = engine.snapshotMerging(remoteDocs: fixtureDocs, now: now)
}
```

which needs one more engine method (add to `HUDEngine.swift`):

```swift
    /// Probe seam: merge CANNED remote docs (fixture-injected) instead of
    /// live-polled ones — the probe never touches the network.
    public func snapshotMerging(remoteDocs: [RemoteEventDoc], now: Int64) -> HUDSnapshot {
        store.snapshot(remote: RemoteReducer.sessions(docs: remoteDocs, now: now))
    }
```

- [ ] **Step 6: e2e case** — append to `Tests/hud-e2e.sh` (after reading its existing structure; it drives real hooks into a sandbox log then diffs probe JSON). New case: write a fixture file with two docs — one whose `session` matches a sid already driven into the local log (expect NO remote row for it), one fresh (`session: "remote-1"`, `event: "needs-input"`, `machine: "other-mac"`, `createdAtMs` = now) — run `vibez-hud-probe <log> <fixture>` and assert with jq: `.needsYou` contains a row with `sid == "remote-1"` and `machine == "other-mac"`, and no duplicate of the local sid. Follow the suite's existing pass/fail helper conventions.

- [ ] **Step 7: Run everything** — `cd VibezHUD && swift test && swift build --product vibez-hud-probe && cd .. && bash Tests/hud-e2e.sh` → PASS.

- [ ] **Step 8: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/HUDEngine.swift VibezHUD/Sources/VibezHUDApp/HUDViewModel.swift VibezHUD/Sources/VibezHUDApp/Views/SessionTile.swift VibezHUD/Sources/VibezHUDApp/DemoData.swift VibezHUD/Sources/vibez-hud-probe/main.swift Tests/hud-e2e.sh
git commit -m "feat(hud): remote sessions in the panel - engine wiring, hostname badge, probe fixtures"
```

---

### Task 11: LaunchAgent install script

**Files:**
- Create: `VibezHUD/Scripts/install-launch-agent.sh`

**Interfaces:**
- Consumes: `VibezHUD/Scripts/make-app.sh` (builds `build/VibezHUD.app`).
- Produces: `~/Library/LaunchAgents/lol.vibez.hud.plist`, label `lol.vibez.hud`, RunAtLoad, NO arguments (live mode). `--uninstall` reverses it.

- [ ] **Step 1: Write the script:**

```bash
#!/usr/bin/env bash
#
# VibezHUD/Scripts/install-launch-agent.sh — build the HUD and keep it
# running LIVE at login. No arguments on the ProgramArguments line is the
# point: --demo is a dev flag, and a login item that ever carried it would
# put fake sessions on the notch forever (exactly the 2026-08-05 bug).
#
# Usage: ./Scripts/install-launch-agent.sh [--uninstall]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="lol.vibez.hud"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP="${HERE}/build/VibezHUD.app"
BIN="${APP}/Contents/MacOS/VibezHUD"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "${PLIST}"
    printf 'uninstalled %s\n' "${LABEL}"
    exit 0
fi

"${HERE}/Scripts/make-app.sh" "${APP}"

mkdir -p "${HOME}/Library/LaunchAgents"
cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${BIN}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST

# Re-bootstrap so an already-installed agent picks up the fresh binary.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST}"
printf 'installed %s -> %s\n' "${LABEL}" "${BIN}"
```

`chmod +x VibezHUD/Scripts/install-launch-agent.sh`

- [ ] **Step 2: Verify the script builds and installs (but do NOT leave it running yet** — Task 12 owns the cutover; here only verify `bash -n` syntax + `--uninstall` path is safe to run):

```bash
bash -n VibezHUD/Scripts/install-launch-agent.sh
```

- [ ] **Step 3: Commit**

```bash
git add VibezHUD/Scripts/install-launch-agent.sh
git commit -m "feat(hud): LaunchAgent installer - always-live HUD at login"
```

---

### Task 12: Rollout — full verdict, deploy, cache sync, live cutover

**Files:** none new (operations + verification).

- [ ] **Step 1: Full local verdict** — `bash Tests/run-all.sh` → `ALL GREEN`. Fix anything red before proceeding.

- [ ] **Step 2: Deploy the backend** —

```bash
cd Backend && npx -y firebase-tools deploy --only functions --project vibez-backend
```

Then verify the deployed function still answers: send a test push through the real pipeline with the machine field (`bash ClaudePlugin/scripts/notify.sh` isn't directly invokable for this — use the setup script's test path: `bash ClaudePlugin/scripts/setup.sh test` if it has one, else a direct curl):

```bash
VID="$(cat ~/.config/vibez/vibez-id)"
curl -sS -X POST -H 'content-type: application/json' \
  -d "{\"vibezId\":\"${VID}\",\"title\":\"Vibez test\",\"body\":\"machine-field rollout check\",\"machine\":\"$(hostname -s)\"}" \
  https://us-central1-vibez-backend.cloudfunctions.net/notify
```

Expected: `{"ok":true}` (one banner may land on the phone — acceptable).

- [ ] **Step 3: Sync live plugin caches** so the running hooks pick up the new scripts:
  - Claude: find the cache (`ls ~/.claude/plugins/cache/`) and rsync `ClaudePlugin/scripts/` over the cached plugin's `scripts/`, preserving any `.in_use/` directory.
  - Codex: the marketplace is git-sourced — `git push` (Step 6) is what updates it; additionally hand-copy `CodexPlugin/scripts/notify.sh` into the local Codex plugin cache if present (find it under `~/.codex/`).
  - Cursor: if `~/.cursor/vibez/` exists, copy `CursorPlugin/scripts/notify.sh` and `setup.sh` over it.

- [ ] **Step 4: Live HUD cutover** —

```bash
pkill -f 'VibezHUD.*--demo' || true
bash VibezHUD/Scripts/install-launch-agent.sh
```

- [ ] **Step 5: Verify live** —
  1. `launchctl print "gui/$(id -u)/lol.vibez.hud" | grep -E 'state|program'` → running, no `--demo` in args.
  2. `ps aux | grep '[V]ibezHUD'` → exactly one instance, argument-free.
  3. `VibezHUD/.build/debug/vibez-hud-probe` (or build it) against the real log → THIS Claude Code session appears as a working `cc` row (its hooks have been writing records all along).
  4. Registration check: `~/.config/vibez/hud/web-client-id` exists after ~20s of runtime.
  5. Remote check: with the HUD registered, trigger a push (e.g. the curl from Step 2 with a `session` + `event: done` + a fake `machine: "other-mac"`) and confirm a badged done row appears — either visually or via a probe fixture replay.
  6. Screen-level verification if needed: use CGWindowList capture (screencapture is blocked on this machine — see the macOS 26 verification notes in project memory).

- [ ] **Step 6: Final commit + push** —

```bash
git status   # everything committed by prior tasks; commit any stragglers
git push
```

(The push is what updates the git-sourced Codex plugin marketplace.)

- [ ] **Step 7: Update docs** — CLAUDE.md's VibezHUD section: note the HUD is no longer network-free (REST polling of the events log, `VIBEZ_HUD_NO_REMOTE=1` kill switch, web-device registration), the 5-min done retention, the `machine` field convention (mirrored across the three plugins + validation.ts), and the LaunchAgent. Commit as `docs: ...`.

---

## Self-Review Notes (already applied)

- Spec coverage: A → Tasks 11-12; B.1 → Task 3; B.2 → Task 5; B.3 → Task 6; B.4 → Task 4; C → Task 4 (+ RemoteReducer in 8); D plumbing → Tasks 1-2, registration/polling → Task 9, merge → Task 7, UI → Task 10, failure modes → Tasks 8-9; E → per-task tests + Task 12 Step 1.
- Type consistency: `snapshot(remote:)` (Task 7) is what Task 10's engine calls; `RemoteEventDoc`/`RemoteReducer`/`FirestoreRESTParser` names match across Tasks 8-10; `machine` param is trailing-defaulted everywhere so existing call sites compile.
- Known intentional scope cuts: no failure-vs-success tool signal, no Codex `end` event, extension untouched, `machine` not in APNs payloads.
