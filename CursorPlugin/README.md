# vibez (Cursor)

Cursor companion for the Vibez iOS app — pushes agent session events to your phone via Firebase Cloud Messaging, so you can step away while the Cursor agent works and get pinged the moment it needs you or finishes. When it pings you, the Vibez iOS app raises a Screen Time shield over your distracting apps until you come back.

Sibling plugins: [`ClaudePlugin/`](../ClaudePlugin/) (Claude Code) and [`CodexPlugin/`](../CodexPlugin/) (Codex). All three share the Vibez ID file at `~/.config/vibez/vibez-id` — one pairing on your phone covers every agent; the iOS app distinguishes them by the `agent` field in each push (`cu` for Cursor, `cc` for Claude Code, `cx` for Codex).

## Install

```
npx vibez-cursor
```

That's it. The installer:

1. copies the hook scripts to `~/.cursor/vibez/`,
2. registers them in `~/.cursor/hooks.json` (your existing hooks are preserved; the previous file is backed up to `hooks.json.vibez-backup`),
3. prints your private 4-word Vibez ID.

Get the Vibez iOS app ([free on the App Store](https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780)) and type the ID into its Setup card. Re-run `npx vibez-cursor` anytime to update; `npx vibez-cursor --uninstall` removes the hooks cleanly. `npx getvibez` also detects Cursor and runs this installer for you.

Prereqs: `jq` and `curl` on your Mac (`brew install jq` if missing). Cursor ≥ 1.7 (hooks support). macOS / Linux.

## What it does

Cursor hooks (one argless command for all events — `notify.sh` dispatches on the payload's `hook_event_name`):

| Cursor hook | Push? | Effect |
|---|---|---|
| `sessionStart` | No | First run generates your Vibez ID; background-agent sessions (bugbot etc.) are muted for their whole lifetime. Also does state hygiene. |
| `beforeSubmitPrompt` | Yes (silent) | You replied — `shield:off` unblocks your phone. Always answers `{"continue": true}`; it can never block your prompt. |
| `afterAgentResponse` | No | Stashes the assistant's final text per session (Cursor's `stop` payload carries no text, so this becomes the push body). |
| `stop` | Yes | Agent loop ended — `done` or `needs-input` (question heuristic on the last message) raises the shield. User-initiated aborts don't push: you're at the machine. Errors push as `needs-input`. |
| `sessionEnd` | No | Cleans up that session's stashed state. |

Same-conversation block debounce (5s, `VIBEZ_BLOCK_DEBOUNCE_SECONDS`) matches the other plugins: the first block of a burst banners your phone, followers within the window are dropped, replies always go through.

**Known gap vs the Claude Code plugin:** Cursor exposes no hook at the moment it shows its own tool-approval prompt, so "waiting for approval" can't ping your phone mid-turn. When the agent ends its turn with a question, the `stop` push covers it.

**Cursor CLI (`cursor-agent`):** recent CLI builds (≥ Jan 2026) fire `sessionStart`/`beforeSubmitPrompt`/`stop`, so the block/unblock loop works — but `afterAgentResponse` is a known CLI gap, so CLI stop pushes fall back to a generic "Finished." body and skip the question heuristic. The IDE agent is the primary target.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `VIBEZ_ID` | from `~/.config/vibez/vibez-id` | Force a specific Vibez ID. |
| `VIBEZ_BACKEND_URL` | `https://us-central1-vibez-backend.cloudfunctions.net` | Point at a different Firebase deployment. |
| `VIBEZ_BLOCK_DEBOUNCE_SECONDS` | `5` | Same-conversation block debounce window (`0` disables). |

CLI: `npx vibez-cursor --id` prints your Vibez ID, `--test` sends a test push, `--dry-run` previews changes, `--uninstall` removes the hooks (keeps the shared Vibez ID).

## Privacy and security

Your Vibez ID is a shared secret: anyone who learns it can push notifications — and raise shields — on your phone. The four words carry ~44 bits of entropy, so it's effectively unguessable, but if it ever leaks, rotate it: `bash ~/.cursor/vibez/setup.sh regenerate`, then update the iOS app.

Push bodies contain your prompt/response excerpts (clipped to 200 chars). The backend clamps and validates everything server-side; see the repo's [Privacy Policy](../PRIVACY.md).

## Failure mode

Hooks are designed never to block Cursor. Every path exits 0 (Cursor treats other codes as fail-open anyway, and `beforeSubmitPrompt` always answers `{"continue": true}`); if the backend is unreachable or `jq`/`curl` are missing, the script logs to `~/.config/vibez/log` and Cursor proceeds — you just don't get the push.

## Layout

```
CursorPlugin/
  package.json          npm package "vibez-cursor" (bin: install.js)
  bin/install.js        npx installer — copies scripts, merges ~/.cursor/hooks.json
  scripts/notify.sh     hook dispatcher (POSTs events to the Firebase /notify function)
  scripts/setup.sh      Vibez ID generation / test push (shared wordlist generator)
  test/install.test.js  installer tests against a sandboxed HOME (npm test)
  README.md
```
