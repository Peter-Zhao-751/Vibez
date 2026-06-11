# Cursor plugin (`CursorPlugin/` + `vibez-cursor` npm) — design

**Date:** 2026-06-11
**Status:** implemented

## Goal

Vibez support for Cursor: the phone blocks distracting apps while the Cursor
agent works and unblocks the moment the user replies — the same loop the
Claude Code and Codex plugins provide. Distribution is `npx vibez-cursor`
(Cursor has no plugin marketplace or plugin-manager CLI), and `npx getvibez`
detects Cursor and delegates to it.

## Why Cursor is different

Cursor's extension surface is **agent hooks** (Cursor ≥ 1.7): shell commands
registered in `hooks.json`, fed JSON on stdin per lifecycle event
(https://cursor.com/docs/hooks). Three structural differences from the
Claude/Codex hook models drove this design:

1. **No marketplace.** Hooks are installed by editing `~/.cursor/hooks.json`.
   The npm installer owns that merge.
2. **The `stop` payload carries no text** — only `{status, loop_count}`. The
   push body must come from `afterAgentResponse` (`{text}`), stashed per
   session between hook invocations.
3. **No "waiting for approval" event.** Nothing fires when Cursor shows its
   own tool-approval prompt, so mid-turn needs-input pushes (the Claude
   plugin's Notification hook, Codex's PermissionRequest) have no equivalent.
   Accepted gap: a turn that *ends* with a question is still classified
   `needs-input` by the shared `last_turn_is_asking` heuristic at `stop`.

## Event mapping

One argless command is registered for all five events; `notify.sh`
dispatches on the payload's `hook_event_name` (dodges any ambiguity about
argument parsing in the `command` string). Session key = `conversation_id`.

| Cursor hook | Action |
|---|---|
| `sessionStart` | `is_background_agent:true` → write a `cursorbg.<sid>` marker; every later hook for that sid is mute (bugbot/background runs aren't a human waiting). First run mints the Vibez ID via setup.sh and returns `{additional_context}` so the agent can surface it. Hygiene: log rotation + stale stash sweep (`-mtime +1`). |
| `beforeSubmitPrompt` | User replied → `replied`/`shield:off`. First real prompt is stashed as the session's push title (`cursortitle.<sid>`). Slash commands don't push. **Every path answers `{"continue": true}`** — this hook may block prompts and must never. |
| `afterAgentResponse` | Stash `.text` to `cursorlast.<sid>` (16 KB cap). No network. |
| `stop` | `aborted` → silent (the user pressed Stop; they're at the machine). `error` → `needs-input`/`on`. `completed` → `last_turn_is_asking(stash)` ? `needs-input` : `done`, body = stashed text. |
| `sessionEnd` | Delete the session's stash + debounce stamp. |

Shared with the other plugins, behavior-identical: `post_vibez` (stamp
policy), 5s same-conversation block debounce, 72/160 clip + 100/200 clamp,
`last_turn_is_asking`, log rotation, `~/.config/vibez/vibez-id` (one ID for
all agents), `VIBEZ_ID`/`VIBEZ_BACKEND_URL`/`VIBEZ_BLOCK_DEBOUNCE_SECONDS`.

Agent tag: **`cu`**, added to the backend whitelist
(`Backend/functions/src/validation.ts` AGENTS — deployed 2026-06-11). The
iOS app needs no change: `VibezAgent(rawValue: "cu")` is nil → Claude-themed
card/banner, which is the documented untagged fallback. Cursor-specific
theming is a possible later cosmetic pass.

## npm packages

**`vibez-cursor`** (new, published from `CursorPlugin/`): zero-dependency
ESM installer, `bin/install.js`.

- Copies `notify.sh` + `setup.sh` to `~/.cursor/vibez/` (npx caches are
  ephemeral — scripts must live somewhere stable), chmod 755.
- Merges the five registrations into `~/.cursor/hooks.json`: foreign hooks
  preserved, stale Vibez entries (old paths) replaced, previous file backed
  up to `hooks.json.vibez-backup`. Unparseable file or non-array event value
  → abort loudly, change nothing. Idempotent re-run → "already registered".
  Entries carry an explicit `"timeout": 30` (the platform default is
  undocumented; notify.sh worst case is ~6s) and the file always carries
  `"version": 1` (configs without it have failed to load in some 3.x
  builds). Cursor watches hooks.json, so no restart is normally needed.
- Confirms on a TTY (Y/n); `--yes` skips; also `--uninstall` (removes our
  entries + `~/.cursor/vibez/`, keeps the shared Vibez ID), `--dry-run`,
  `--id`, `--test`, `--help`, `--version`. Windows: refused (hooks are bash).

**`getvibez`** 0.2.0 → 0.3.0: third target `--cursor`. Detection =
`cursor` on PATH **or** `~/.cursor` exists (many installs never add the
shell command), non-win32. Install = delegate to
`npx -y vibez-cursor@latest --yes`, and surface its output (it contains the
Vibez ID — the pairing surface for Cursor, which has no `/vibez:setup`).

Publish order matters: `vibez-cursor` first, then `getvibez` 0.3.0 (it
shells out to the former).

## Testing

- `scripts/notify.sh _selftest` — 49 helper-level cases (asking heuristic,
  debounce + stamp policy ported from the Codex plugin, stash roundtrips,
  title resolution, jq_get, log rotation).
- `test/hooks.e2e.sh` — 17 cases: realistic payloads piped into the real
  dispatch path against a sandboxed HOME and a local stub `/notify` that
  captures request bodies (asserts shield/event/agent/session/title/body per
  hook, bg-session muting, abort silence, `{"continue": true}` invariants).
- `test/install.test.js` (node:test, `npm test`) — 10 installer cases
  against sandboxed HOMEs (fresh/merge/idempotent/corrupt/uninstall/dry-run).
- `installer/test.mjs` — getvibez dry-run assertions incl. the new target.
- Backend: `validation.test.ts` agent-tag case; live-probed post-deploy
  (`cu` → 200, unknown agent → 400, per-ID burst still 429s).

## Out of scope (deliberate)

- Cursor-themed shield/banner identity on iOS (falls back to Claude theme).
- Cloud agents (they never see `~/.cursor/hooks.json` and can't reach the
  user's `~/.config/vibez` anyway) and Windows.
- Mid-turn approval pushes (no hook exists — see gap above).
