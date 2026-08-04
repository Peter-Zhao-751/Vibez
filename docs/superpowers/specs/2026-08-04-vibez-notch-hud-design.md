# Vibez Notch HUD — design

**Date:** 2026-08-04
**Status:** approved design, not yet implemented

A macOS companion app that lives in the notch and, on hover, shows every Claude
Code / Codex / Cursor session running on this Mac — what's working, what's blocked
on you, and what just finished. Click a session to jump to its terminal.

Vibez already answers "does something need me?" while you're away from the desk
(phone push + app shielding). This answers the same question while you're *at*
the desk, where a push notification is the wrong instrument.

## Goals

- Glanceable ambient state without hovering: is anything blocked on me right now?
- On hover, the full picture across all three agents in one place.
- Click a session → its terminal comes to the front.
- Native macOS 26 look: Liquid Glass ears, Dynamic-Island-style expansion.
- Correct under concurrency, crashes, and killed terminals — no phantom rows.
- Fast: panel populated in well under 50 ms, no network on the hot path.

## Non-goals

- **Sessions on other machines.** Local only. The transport has a seam for a
  remote source later, but nothing remote ships here.
- **Replacing the phone pipeline.** The HUD is additive; `/notify` is untouched.
- **Reading agents' private transcript formats.** See "Rejected alternatives".
- **Any backend change.** No Firestore writes, no new Cloud Function, no change
  to what the server stores — the App Privacy label ("push token only") stays true.

---

## 1. Architecture

```
notify.sh ×3          ~/.config/vibez/hud/         VibezSessionKit (SPM, pure)      VibezHUD.app
┌──────────────┐      ┌──────────────────┐        ┌──────────────────────┐        ┌─────────────┐
│ hud_record() │─────▶│  events.jsonl    │───────▶│ EventLogReader (tail)│───────▶│ NotchWindow │
│  (mirrored   │append│  (rotates @2 MB) │ FSEvent│ SessionStore(reducer)│  states│ HoverPolicy │
│   ×3)        │      └──────────────────┘        │ LivenessProbe/Clock  │        │ SwiftUI     │
└──────────────┘                                  └──────────┬───────────┘        └─────────────┘
                                                             │
                                                  ┌──────────▼───────────┐
                                                  │ vibez-hud-probe (CLI)│  headless, prints JSON
                                                  └──────────────────────┘  (what e2e tests assert)
```

Four units with hard boundaries:

| Unit | Depends on | Responsibility |
|---|---|---|
| `hud_record()` in `notify.sh` ×3 | nothing | Append one JSON line per lifecycle event |
| `VibezSessionKit` (SPM lib) | Foundation only — **no AppKit** | Tail the log, reduce events to sessions |
| `VibezHUD` (app) | VibezSessionKit, AppKit, SwiftUI | Window, hover, rendering, jumping |
| `vibez-hud-probe` (CLI) | VibezSessionKit | Dump state as JSON for tests |

`VibezSessionKit` having no AppKit dependency is what makes the whole reducer
testable with `swift test`. `Clock` and `LivenessProbe` are protocols, so every
time-based rule is exercised with a fake clock and nothing sleeps.

### Rejected alternatives

**Per-session state files** (`sessions/<sid>.json`, whole-file rewrite). Simpler
to read, no rotation. Rejected because parallel hooks on one session are
last-write-wins: a `needs-input` and a `post-tool-use` in the same second can
silently eat a state transition. That is the exact bug class the backend's `seq`
ordering fix already exists to solve; reintroducing it locally is not worth the
saved rotation logic.

**Reading the agents' own session files** (`~/.claude/projects/*.jsonl`,
`~/.codex/sessions/`, Cursor's store). Would work with no plugin change.
Rejected on three counts: undocumented private formats that churn per release;
Cursor's is the least tractable of the three; and decisively, **"waiting on a
permission prompt" is a UI state that is never written to a transcript** — one
of our four states simply does not exist in that data.

**Backend-synced sessions** (Firestore mirror + subscription). Would cover other
machines. Rejected for v1: it adds 0.5–2 s latency to a hot path that is
currently sub-50 ms, requires a deploy, and starts storing conversation titles
and bodies server-side — a real privacy regression against a shipping App Store
privacy label. Revisit only if multi-machine becomes a genuine need.

---

## 2. Data contract

**Path:** `~/.config/vibez/hud/events.jsonl` (directory `0700`, file `0600` —
matching the existing `~/.config/vibez` permissions).

One JSON object per line:

```json
{"v":1,"ts":1754345678901,"sid":"93399689-b83e-414f-b537-c2040e24d7bf","agent":"cc",
 "kind":"needs-input","proj":"Vibez","cwd":"/Users/peter/Desktop/Vibez",
 "title":"Mac notch app","body":"Bash: rm -rf build — awaiting approval",
 "tool":"Bash","agentPid":41234,"agentStart":"Mon Aug  4 20:58:08 2026",
 "appPid":39001,"app":"iTerm2"}
```

| Field | Required | Notes |
|---|---|---|
| `v` | yes | Schema version, currently `1`. Reader ignores lines with unknown `v`. |
| `ts` | yes | Epoch **milliseconds**. Ordering key. |
| `sid` | yes | Session id. Records with an unusable sid (empty / `nosid`) are dropped by the writer, reusing `isUsableSessionId` semantics. |
| `agent` | yes | `cc` / `cx` / `cu`. |
| `kind` | yes | `start` `prompt` `tool` `needs-input` `done` `end`. |
| `proj` | yes | `basename(cwd)`, or the Cursor workspace root's basename. |
| `cwd` | yes | Absolute path. Used for the fallback "reveal in Finder". |
| `title` | yes | Conversation title, clamped to 100 chars (same clamp as the push). |
| `body` | no | Detail line, clamped to 200 chars. |
| `tool` | no | Tool name on `tool` / `needs-input` records. |
| `agentPid` `agentStart` | `start` only | Liveness pair. `agentStart` is `ps -o lstart=` output. |
| `appPid` `app` | `start` only | Owning terminal app, for click-to-jump. |

**Identity fields ride on every record, not just `start`.** After a rotation a
long-running session's `start` line can be gone; carrying `proj`/`cwd`/`title`
everywhere means the reducer self-heals from any single line instead of showing
a nameless orphan. Costs roughly 60 bytes per line.

### Hook → `kind` mapping

| Plugin | Hook | `kind` |
|---|---|---|
| Claude | `SessionStart` | `start` |
| Claude | `UserPromptSubmit` | `prompt` |
| Claude | `PostToolUse`, `PostToolUseFailure` | `tool` |
| Claude | `PreToolUse` (AskUserQuestion), `PermissionRequest` | `needs-input` |
| Claude | `Notification` | `needs-input` (skipped for idle reminders, mirroring the push path) |
| Claude | `Stop` | `done` or `needs-input` — the plugin already classifies this |
| Claude | `SessionEnd` **(new registration)** | `end` |
| Codex | `SessionStart` / `UserPromptSubmit` / `PostToolUse` / `PreToolUse` / `PermissionRequest` / `Stop` | as above |
| Cursor | `sessionStart` | `start` |
| Cursor | `beforeSubmitPrompt` | `prompt` |
| Cursor | `afterAgentResponse` | `tool` |
| Cursor | `stop` | `done` / `needs-input`, or `end` when aborted |
| Cursor | `sessionEnd` | `end` |

**Codex registers no SessionEnd hook** (its `hooks.json` has six: PermissionRequest,
PostToolUse, PreToolUse, SessionStart, Stop, UserPromptSubmit). Codex sessions
therefore reach ENDED via PID liveness only. That is acceptable — liveness is the
fallback for all three agents anyway.

**Claude's `SessionEnd` handler must be trivially fast.** The changelog records
that SessionEnd hooks were historically killed 1.5 s into exit (now tunable via
`CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS`). A single `printf >>` comfortably fits;
the handler must never call `curl`.

### Why the writer forks from `post_vibez`

`hud_record()` is called at the **event site**, not from inside `post_vibez`.

The push path deliberately *suppresses* events — the 5 s same-conversation block
debounce, the `stop_pending_work` gate, the deferred-Stop grace. Those exist to
protect the phone from spam. The HUD wants every transition. Wiring `hud_record()`
into `post_vibez` would silently inherit all three suppressions and the panel
would go stale mid-burst, precisely when it matters most.

The two exceptions where the HUD *does* mirror push logic, because in these cases
the suppression reflects "this isn't a real event" rather than "don't spam":

- Claude's `Notification` idle-reminder skip.
- Ephemeral / background-agent sessions (Codex's ephemeral detection, Cursor's
  bg-agent mute marker). Honoring the same markers keeps one definition of
  "is this a real session" across phone and desktop.

### Concurrency

Claude Code fires hooks in parallel. `hud_record()` is a single `printf >>` to a
file opened `O_APPEND`; POSIX makes the offset-update-plus-write atomic, and
records are far below any interleaving threshold. No lock, no lost writes. This
is the same property the existing `log()` relies on, and it is the reason the
append-only transport was chosen over per-session files.

The atomicity claim is *tested*, not assumed — see Testing layer 2.

---

## 3. State model

Four states. `IDLE` exists internally (a session that has started but never run)
and renders in no column.

| State | Entered by | Meaning |
|---|---|---|
| `WORKING` | `prompt`, `tool` | Tools are firing. |
| `NEEDS_YOU` | `needs-input` | Blocked on you right now — permission prompt or a question on screen. |
| `DONE` | `done` (after grace) | Finished its turn cleanly, nothing pending. |
| `ENDED` | `end`, dead PID, or staleness | Process is gone. |

`NEEDS_YOU` and `DONE` are kept separate rather than merged into "waiting"
because "approve this Bash command now" and "finished twenty minutes ago, read
it when you like" are different urgencies, and the plugins already distinguish
them (`needs-input` vs `done`).

### Ordering

Each session tracks `lastAppliedTs`. A record older than that does not change
state (it still contributes to history). Without this, a stale `tool` heartbeat
landing after a `needs-input` would knock a blocked session back to WORKING.
Same discipline as `isStalePush` in the NSE.

On an exact millisecond tie, priority decides: `needs-input` > `done` > `prompt`
> `tool`. If a permission request and a tool completion land in the same
millisecond, "blocked on you" is the truthful state.

### Provisional DONE

Claude Code fires `Stop` at every turn boundary, including turns the harness
resumes by itself ~1 s later — so a `done` is not always a done. The push path
solves this with a deferred grace window; the HUD solves it **client-side**:

A `done` record is *provisional* for `STOP_GRACE_SECONDS` (default 3, read from
the same `VIBEZ_STOP_GRACE_SECONDS` env var). During the window the session holds
its previous state; any newer record for that session discards the provisional
done. It commits to `DONE` only if the window elapses in silence.

This is pure logic, fake-clock testable, and requires no bash change.

### Liveness

`start` records carry `agentPid` **and** `agentStart` (from `ps -o lstart=`).
`LivenessProbe.isAlive` checks `kill(pid, 0)` *and* compares the recorded start
time. macOS recycles PIDs; without the start-time comparison a dead session
eventually resurrects as an unrelated process. Polled every 5 s for
non-terminal sessions only.

Unlike `proj`/`cwd`/`title`, the liveness pair rides on `start` records **only**
— it is fixed for the life of the session and would be dead weight on every
heartbeat. Consequence: a session whose `start` line has rotated away has no PID
to probe, and reaches `ENDED` through the staleness rule instead. Sessions in
that condition are by definition already very old, so the slower path is
acceptable; the reducer must simply treat a missing PID as "unknown", never as
"dead".

### Staleness, retention, rotation

- **Stale → ENDED:** no record in 30 min *and* PID not alive.
- **Retention:** `DONE`/`ENDED` rows stay visible 60 min, then drop from the list.
  In-memory only; the log remains the durable record.
- **Rotation:** at 2 MB → `events.jsonl.1`, one backup. Matches the existing
  `log()` policy and its `VIBEZ_LOG_MAX_BYTES` convention.
- **Reader:** keyed on `(inode, offset)`. Size < offset → truncated, re-read from
  0. Inode changed → drain the old file's tail, then switch.
- **Cold start:** seek to `size − 256 KB`, discard the partial first line, replay
  forward. Bounded work regardless of log size. A session with no record in that
  window (~1,300 events) scrolls off — acceptable, because anything that quiet is
  already caught by the staleness rule.

### Configuration

Read from `UserDefaults` with env-var fallback where the plugins already define one.

| Key | Default |
|---|---|
| `vibez.hud.retentionMinutes` | 60 |
| `vibez.hud.staleMinutes` | 30 |
| `vibez.hud.livenessPollSeconds` | 5 |
| `VIBEZ_STOP_GRACE_SECONDS` | 3 (shared with the plugins) |
| `VIBEZ_HUD_LOG_MAX_BYTES` | 2097152 |

---

## 4. Window & interaction

### The panel

`NSPanel`, `[.borderless, .nonactivatingPanel]`, `level = .statusBar + 2`, clear
background, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
.stationary, .ignoresCycle]`. Non-activating: it never steals focus from your editor.

**Geometry** is a pure `NotchGeometry` struct — screen metrics in, rects out, so
it unit-tests with no display attached. `NSScreen.safeAreaInsets.top > 0` detects
a notch; notch width derives from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
Non-notch Macs and external displays get a fallback pill centered under the menu
bar in the same visual language. The HUD lives on the menu-bar screen, re-resolved
on `didChangeScreenParameters`.

**Hover without focus:** `NSTrackingArea` with `.activeAlways` — that flag is the
whole trick, it fires for inactive apps — plus a global `.mouseMoved` monitor as
backstop. Mouse monitors require no permissions; only keyboard monitoring would.

**`HoverPolicy`** is extracted as a pure struct driven by a `Clock`: 120 ms to
open, 350 ms to close, close cancelled on re-entry. Without hysteresis you lose
the panel every time the pointer crosses a seam. Being pure makes the flakiest
part of any hover UI deterministic in tests.

The collapsed hit zone is deliberately larger than the visible ears so "hover the
notch" works on the first try.

### Day-one spike

macOS 26 changed menu-bar rendering, so whether `.statusBar + 2` actually
composites above the menu bar in the notch region must be **proven, not assumed**.
The first commit is a ~40-line spike that draws a colored rect over the notch and
screenshots it. If the level is wrong that is a one-line fix found in ten minutes
rather than after the UI is built on top of it.

### Click → jump

At `start`, `notify.sh` walks the process tree upward from `$PPID`, collecting
every ancestor whose executable resolves inside a `.app` bundle, and records the
**outermost** one. Taking the first would land on `Cursor Helper.app` for
VS Code / Cursor integrated terminals; the outermost correctly resolves to
`Cursor.app`. `agentPid` (liveness) and `appPid` (jumping) are recorded separately.

Jump is `NSRunningApplication(processIdentifier:)?.activate()` — no permissions.
Optional upgrade: with Accessibility granted, raise the specific window among
several terminal windows via the AX API, degrading silently to app-level
activation when not granted. If `appPid` is dead, fall back to revealing `cwd`
in Finder.

---

## 5. Visual design

Decided by mockup review; the mockups live in `.superpowers/brainstorm/` (gitignored).

### Collapsed — two glass ears

Real Liquid Glass (`.glassEffect`), flanking the notch in the auxiliary areas.

- **Left ear:** count of NEEDS YOU, with a pulsing `#FF9F0A` dot. Hidden at zero.
- **Right ear:** count of WORKING, with a three-bar equalizer. Hidden at zero.
- Nothing running and nothing waiting → both ears retract, notch is bare.

### Expanded — a black bubble

The panel is **opaque black**, starts at the screen's top edge, and is wider than
the notch, so it swallows it: no seam, no border between notch and panel. It
reads as one object growing rather than a window appearing below a notch.

- Width `min(1040 pt, 84% of screen width)`; bottom corner radius 30 pt.
- Max height 62% of screen height — columns absorb overflow, the bubble never grows past it.
- The only glass treatment is a specular gradient over the top ~42% (`white @ 5.5%`
  → transparent) and a `0.5 pt` rim at `white @ 13%`, so it reads as lit rather than flat.
- **Light mode: the bubble stays black.** The Dynamic Island is black on iPhone
  regardless of appearance, and a light bubble makes the notch seam visible,
  which destroys the continuous-object effect. Light/dark adaptation lives in the
  tiles inside, not the shell.

### Columns

Order is **Needs you → Done → Working**. Each column has a pinned header (state
dot, label, count), scrolls independently, and fades content at top and bottom so
cut-off rows read as "more below" rather than as clipping.

There are four states but three columns: **`ENDED` sessions render inside the Done
column**, below the `DONE` ones, dimmed, with an italic `ended` detail line. They
are not a fourth column — "the process is gone" is a footnote on a finished
session, not a category you scan for. The Done header count includes them.

### Tiles

Every tile uses the **same neutral material** — `white @ 7.5%` fill, `white @ 8.5%`
border, 11 pt radius — regardless of state. Apple does not tint whole rows on a
black surface; the column already states the state, so a row wash says the same
thing twice. A NEEDS YOU tile gets a single 2 pt `#FF9F0A` hairline on its left
edge, and nothing else.

Row content: agent chip · project name (truncating) · elapsed · title · detail line
(tool + argument in monospace). DONE/ENDED rows render at 48% opacity.

### Color

State colors are Apple's dark-mode system values, and each means exactly one thing:

| Token | Value | Use |
|---|---|---|
| Needs you | `#FF9F0A` | header dot, ear dot, tile hairline |
| Done | `#30D158` | header dot |
| Working | `#64D2FF` | header dot, equalizer |
| Ended | `#98989D` | the `ended` label on a dimmed row (no header dot — ENDED has no column of its own) |

Working uses system **teal**, not system blue, specifically so it doesn't collide
with Codex's brand blue.

Agent identity keeps Vibez's existing brand chips — Claude `#d97757`, Codex
`#4A7AFF`, Cursor `#A5A5B9` — matching the phone app, the shield card, and the
Chrome extension. The alternative (monochrome glyph, agent named in text) was
considered and rejected: the agent is the thing you scan for, and seeing it beats
reading it.

### Motion

Expansion springs from exact notch dimensions — width and height both — with a
slight overshoot, roughly `.spring(response: 0.42, dampingFraction: 0.78)`, about
0.58 s. Content fades in 160 ms behind the shape so text never stretches during
the morph. `GlassEffectContainer` + `glassEffectID` carry the ears into the
bubble as one continuous element rather than a cross-fade.

---

## 6. Testing

The repo currently has no XCTest target; pure logic is tested by hand-invoking
`swiftc -parse-as-library`. Putting the logic in an SPM package removes that
friction entirely — `swift test` just works. That is a primary reason
`VibezSessionKit` is split out of the app target.

**Layer 0 — notch spike.** Before anything else. Proves the window level
composites above the macOS 26 menu bar. Manual + screenshot.

**Layer 1 — reducer & parsing.** `swift test`, milliseconds, zero I/O, fake clock.
- Parsing: malformed JSON, truncated final line, unknown `kind` / `agent` / `v`,
  missing fields, emoji in titles, a 10 KB line, empty file, newlines-only file.
- Transition matrix: 6 kinds × 5 states, table-driven — all 30, not the happy 6.
- Ordering: inverted timestamps, millisecond ties resolving by priority,
  duplicate records idempotent.
- Provisional done: `done`→silence commits after grace; `done`→`tool` inside the
  grace stays WORKING. (The false-DONE flash, pinned as a test.)
- Liveness: alive, dead, and PID-reused (same pid, different `agentStart` → ENDED).
- Self-heal: a session whose `start` line was rotated away still renders with its
  project name.
- Retention and staleness boundaries; list ordering.

**Layer 2 — reader against real files.** Append-while-tailing, rotate mid-tail,
truncate mid-tail, and a torn write (half a line on disk — the reader must wait,
not consume it). Then 50 concurrent appenders asserting zero lost and zero
interleaved lines. This test exists specifically to *prove* the `O_APPEND`
atomicity the transport is built on.

**Layer 3 — writer, in bash.** Extends the `test/hooks.e2e.sh` harness each plugin
already has (realistic payloads → real dispatch path → `curl` shadowed). Asserts
every hook writes exactly one record, every record is `jq -e` valid, and — most
importantly — **a HUD record is written even when the push is debounced,
suppressed by `stop_pending_work`, or deferred by the Stop grace.** That coupling
is the thing most likely to silently rot.

**Layer 4 — headless end-to-end.** A scripted realistic session (start → prompt →
3 tools → permission request → approval → tools → stop) driven through the real
`notify.sh`, then `vibez-hud-probe` dumps state and it is diffed against a golden
snapshot. All three plugins. ~2 seconds, no UI.

**Layer 5 — replay real history.** `~/.config/vibez/log` holds ~940 KB of genuine
events back to May, covering cases no invented fixture would contain. Transcode
and replay, asserting invariants: never crashes, never produces an impossible
state, `lastActivity` monotonic per session, pruning bounded. Plus randomized
sequence fuzzing on the same invariants.

**Layer 6 — UI, headless where possible.** `NotchGeometry` with fake screen
metrics (notch MBP / non-notch iMac / external / config change), no display
attached. `HoverPolicy` with a fake clock. A `--demo` launch argument seeds one
session in every state so all four render in one second.

**One command:** `./Tests/run-all.sh` → `swift test` + three bash suites + probe e2e.

**Not automatable, stated honestly:** that the panel visually composites over the
menu bar, and whether hover *feels* right. Both are eyeball checks — hence the
day-one spike and `--demo`.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| `.statusBar + 2` doesn't composite over the macOS 26 menu bar | Day-one spike, before any other work |
| Claude's `SessionEnd` killed on exit before the append lands | Handler is one `printf`, never `curl`; PID liveness is the backstop regardless |
| Process-tree walk misidentifies the terminal for exotic setups (tmux, ssh, multiplexers) | Outermost-`.app` rule handles Electron helpers; falls back to revealing `cwd` when `appPid` is dead or absent |
| Log growth on a heavy day | 2 MB rotation + 256 KB cold-start tail bound both disk and startup |
| Three copies of `hud_record()` drift apart | Mirrored-code convention already used throughout this repo; layer-3 tests run per plugin |

## 8. Out of scope for v1

Multi-machine sessions; quick actions beyond jump (mute, reveal, open in editor);
Cursor-specific theming (`cu` renders with the Claude fallback today, matching the
phone); keyboard navigation; menu-bar-only mode for non-notch Macs beyond the
fallback pill.
