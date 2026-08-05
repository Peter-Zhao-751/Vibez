# VibezHUD: live accuracy, 5-minute done expiry, cross-device sessions

**Date:** 2026-08-05
**Status:** Approved (design review with Peter, 2026-08-05)

## Problem

1. The HUD on Peter's Mac was launched with `--demo --tune-hover` — the panel shows
   seeded fake data, not real sessions ("it's like a mockup right now"). Beyond that,
   real statuses go stale: granted long-running commands sit in NEEDS YOU until they
   finish, repeated Stops flash done→working→done, resumed sessions show "ended", and
   done rows linger for a full hour.
2. Done rows should expire from the panel 5 minutes after finishing, not 60.
3. Agents running on *other* devices (another Mac sharing the same Vibez ID) are
   invisible. The server already sees their phone-worthy moments; the HUD should
   surface them by comparing server state against the local plugin log.

## Decisions made in review

- Cross-device fidelity: **hostname labels included** — plugins send `machine`,
  backend stores it (backward-compatible additive change).
- Remote rows are **merged into the existing NEEDS YOU / DONE / WORKING columns**
  with a hostname badge; collapsed island counts include them.
- Remote transport: **anonymous Firestore REST polling** (~15s) via URLSession.
  No Firebase SDK dependency, no separate sync daemon.
- Done expiry: **5 minutes**, applies to both `done` and `ended` rows, local and
  remote.

## A. Live mode + launch path

- Kill the `--demo --tune-hover` instance; rebuild; relaunch with no args (live log
  mode is already the default — `main.swift:22`).
- New `VibezHUD/Scripts/install-launch-agent.sh`: installs
  `~/Library/LaunchAgents/lol.vibez.hud.plist` (RunAtLoad, no args) pointing at the
  built app, idempotent, `--uninstall` supported. `--demo` remains a dev-only flag.

## B. Local status-accuracy fixes

1. **Approval-watcher HUD record** (`ClaudePlugin/scripts/notify.sh`,
   `CodexPlugin/scripts/notify.sh`, mirrored per convention): when the watcher
   detects the approved command's process started (the same moment it sends the
   replied/shield:off push), it also writes a `kind=tool` HUD record (tool name from
   the pending marker). The row flips NEEDS YOU → WORKING when the command *starts*,
   not when it finishes. Cursor has no watcher — unaffected.
2. **Sticky done commit** (`SessionStore`): once a provisional done has committed
   (grace elapsed), persist `.done` into the entry. A later `done` event refreshes
   `lastActivityMs` only — it must not re-open the grace window or revert the
   displayed state. Real activity (`prompt`/`tool`/`needs-input`) still transitions
   normally.
3. **`start` resets a finished session** (`SessionStore.apply`): a `start` event on
   an entry whose state is `.ended` or committed `.done` resets state to `.idle`
   (fresh `stateSinceMs`). Resumed sessions no longer show "ended" until the first
   prompt.
4. **Entry eviction** (`SessionStore`): when retention would prune a done/ended row
   from the snapshot, also remove the entry from the dictionary (bounded memory for
   a login-item HUD). Cold-start replay of the 256KB tail re-resolves and re-prunes
   consistently.

Out of scope (noted, deliberate): tool failure vs success is indistinguishable in
the HUD (`post-tool-use-failure` also emits `kind=tool`); Codex sessions never write
`end` (pid liveness covers them locally).

## C. 5-minute done expiry

- `StoreConfig.retentionMs` default: 60 min → **5 min**. Applies to `.done` and
  `.ended` rows, measured from `lastActivityMs` (for a done row that IS the finish
  moment). Remote done rows use the server doc's `createdAtMs` the same way.
- Collapsed green count drops automatically as rows expire (snapshot-driven).
- Known kept quirk: a row expiring while the panel is expanded leaves its allocated
  height until collapse (island sizing is deliberately frozen mid-hover).

## D. Cross-device sessions

### Plumbing (additive, backward-compatible; rollout in this order)

1. **Backend** (`Backend/functions/src/validation.ts`, `index.ts`): accept optional
   `machine` in `/notify` bodies — pattern `^[A-Za-z0-9.-]{1,64}$`, dropped if
   invalid. Stamp it into the Firestore event doc (`events/{vibezId}/items`). It is
   NOT added to the APNs payload — zero iOS churn. Deploy before plugins change.
2. **Plugins** (all three `scripts/notify.sh`, mirrored): `post_vibez` payload gains
   `machine: $(hostname -s)`, sanitized to the same pattern. HUD sidecar records are
   unchanged (local log needs no machine field).
3. **HUD registration**: on launch, if `~/.config/vibez/vibez-id` exists, ensure a
   persisted random client id at `~/.config/vibez/hud/web-client-id` and call the
   `registerPushToken` callable with `{fcmToken: <clientId>, vibezId,
   platform: "web"}`. This flips the server's `hasWeb` gate so `/notify` starts
   persisting event docs for this Vibez ID (same mechanism as the Chrome
   extension; consumes one of the 10 device slots, reused forever).

### RemoteSessionSource (new, VibezSessionKit)

- Every 15s, POST an anonymous Firestore REST `runQuery`: collection
  `events/{vibezId}/items`, `orderBy createdAtMs desc`, `limit 50`.
- Reduce docs per `session` id (newest wins, `createdAtMs` ordering):
  - `event: needs-input` (shield not off) → **needsYou**
  - `event: done` → **done**
  - `event: replied` or `shield: off` → **working** (the user replied; the agent
    resumed)
  - docs without a usable session id (`nosid`/empty) are skipped.
- Produces remote `Session` values: `agentPid = nil`, `machine` label from the doc
  (absent → "remote"), agent tag from the doc, title/body as detail.

### Merge rules (SessionStore)

- **Local wins:** a remote session whose sid exists in the local store is dropped —
  the local log is strictly richer. This is the "compare server to local" rule.
- Remote rows ride the existing resolution paths: no pid → the 30-min no-pid
  staleness ends them; the 5-min done retention prunes them; needsYou sorting by
  wait applies.
- Click-to-jump is a no-op for remote rows (no local pid/cwd).

### UI

- Remote tiles show a small hostname badge (e.g. `mbp-air`) alongside the agent
  chip; everything else renders like a local row.
- Collapsed island: amber/green flank counts include remote rows — the amber count
  means "an agent needs you *somewhere*".

### Failure modes & controls

- Network/HTTP error → keep last remote state; staleness ages it out naturally.
- No `~/.config/vibez/vibez-id` → remote feature entirely off.
- Kill switch: `VIBEZ_HUD_NO_REMOTE=1` environment variable.
- Honest limitation: the server only records phone-worthy moments — a remote
  session that is merely working and has never pinged is invisible until its first
  needs-input/done.

## E. Testing

- **VibezSessionKit unit tests:** 5-min retention + eviction; sticky done (no
  re-opened grace, no flash); start-resets-ended; remote doc→event mapping; local-
  wins dedupe; hostname fallback; remote rows aging out via staleness.
  `RemoteSessionSource` is protocol-seamed so tests inject canned REST JSON — no
  network in tests.
- **Probe:** `vibez-hud-probe` rows gain `machine` (and implicitly remote rows) so
  the cross-plugin e2e can assert merges; probe stays offline (fixture-injected
  remote docs).
- **Plugin suites:** extend `hooks.e2e.sh` stub-capture cases to assert `machine`
  in `/notify` payloads and the approval watcher's new `kind=tool` HUD record.
- **Backend:** `validation.test.ts` cases for `machine` (valid, invalid, absent).
- `Tests/run-all.sh` remains the single verdict; final verification is a real
  session pass with the live HUD.

## Rollout

1. Backend deploy (accepts + stores `machine`).
2. Plugin changes + cache sync (rsync for Claude cache; Codex reinstalls pushed
   HEAD — commit/push required for its cache).
3. HUD build + LaunchAgent install; kill the demo instance.

Each step is backward-compatible with the previous one.
