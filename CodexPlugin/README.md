# vibez (Codex)

A Codex plugin that pushes session events to your phone via Firebase Cloud Messaging — so you can step away while Codex works and get pinged the moment it needs you or finishes a task. When it pings you, the Vibez iOS app raises a Screen Time shield over your distracting apps until you come back.

Sibling plugin: the Claude Code version lives in [`ClaudePlugin/`](../ClaudePlugin/). Both plugins share the same Vibez ID file at `~/.config/vibez/vibez-id` (one pairing on your phone covers both agents); the iOS app distinguishes them by the `agent` field in each push (`cx` for Codex, `cc` for Claude Code).

## What it does

| Event | Push? | What you see on your phone |
|---|---|---|
| **SessionStart** (first run only) | Internal | A system message inside Codex with your 4-word Vibez ID. |
| **SessionStart** (subsequent runs) | No | Nothing. |
| **PermissionRequest** | Yes (in `default` / `acceptEdits` / `plan` modes) | Tool name + a short snippet of `tool_input` — e.g. "shell: rm -rf node_modules". |
| **Stop** | Yes | Title with the cwd basename + a ~160-char excerpt of Codex's last message (`last_assistant_message`). |
| **UserPromptSubmit** | Yes | A short excerpt of your reply — also tells the Vibez app to lift the shield for this session. |

PermissionRequest pings are suppressed in `dontAsk` and `bypassPermissions` modes — those modes never show the user a prompt, so a phone ping wouldn't be actionable.

## Install

1. Run the Vibez iOS app on your iPhone — currently a local build (see the [top-level README](../README.md#ios-app); App Store distribution is pending Apple review).
2. Make sure `jq` and `curl` are on your Mac — the hook needs them to build and POST events. `brew install jq` if missing.
3. Add the marketplace and install:

   ```
   codex plugin marketplace add Peter-Zhao-751/Vibez
   codex plugin install vibez@vibez
   ```

   `codex plugin marketplace add` also accepts full Git HTTPS/SSH URLs or a local directory if you're hacking on the plugin (`codex plugin marketplace add /path/to/Vibez`).

4. **Open Codex as normal.** The first session after install auto-generates your private Vibez ID and shows you a system message with it.

5. Ask Codex something like "show me my Vibez ID" to surface it again, or "send a test push to my vibez setup" to verify wiring. Then open Vibez on your phone and type the ID into the Setup card.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `VIBEZ_ID` | from `~/.config/vibez/vibez-id` | Force a specific Vibez ID. Useful for driving several machines from one ID. |
| `VIBEZ_BACKEND_URL` | `https://us-central1-vibez-backend.cloudfunctions.net` | Point the plugin at a different Firebase deployment. |

The Vibez ID lives at `~/.config/vibez/vibez-id`. The plugin also writes a debug log to `~/.config/vibez/log`. If you previously used the Claude Code vibez plugin (pre-0.9), the old `~/.config/claude-ntfy/` directory is migrated in place on first run.

## Skill

- `vibez-setup` — surfaces your Vibez ID, sends a test push, or regenerates the ID. Triggered by asking Codex for your Vibez ID, testing your setup, or rotating the ID.

## Privacy and security

Your Vibez ID is a shared secret: anyone who learns it can push notifications — and raise shields — on your phone. The four words carry ~44 bits of entropy, so it's effectively unguessable, but if it ever appears in a screenshot, log, or shared screen, rotate it with the `vibez-setup` skill (`regenerate`).

Pushes flow through the project's Firebase project; the APNs auth key never ships in the plugin. See the repo's [Privacy Policy](../PRIVACY.md) for what the iOS app and backend handle.

## Failure mode

Hooks are designed never to block Codex. If the backend is unreachable or `curl`/`jq` errors, the script logs to `~/.config/vibez/log` and exits 0 — Codex proceeds, you just don't get the push.

## Layout

```
CodexPlugin/
  .codex-plugin/plugin.json              manifest
  hooks.json                             SessionStart / PermissionRequest / PreToolUse / PostToolUse / Stop / UserPromptSubmit wiring
  scripts/notify.sh                      hook dispatcher (POSTs events to the Firebase /notify function)
  scripts/setup.sh                       vibez-setup skill implementation (Vibez ID generation)
  skills/vibez-setup/SKILL.md            skill definition
  README.md
```
