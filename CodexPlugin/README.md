# vibez (Codex)

A Codex plugin that pushes session events to your phone via [ntfy.sh](https://ntfy.sh/) — so you can step away while Codex works and get pinged the moment it needs you or finishes a task.

Sibling plugin: the Claude Code version lives in [`ClaudePlugin/`](../ClaudePlugin/). Both plugins share the same ntfy topic (one subscription on your phone covers both agents); the iOS app routes / badges by an `_vibez:agent:cx` vs `cc` tag.

## What it does

| Event | Push? | What you see on your phone |
|---|---|---|
| **SessionStart** (first run only) | Internal | A system message inside Codex with your subscribe URL. |
| **SessionStart** (subsequent runs) | No | Nothing. |
| **PermissionRequest** | Yes (in `default` / `acceptEdits` / `plan` modes) | Tool name + a short snippet of `tool_input` — e.g. "shell: rm -rf node_modules". |
| **Stop** | Yes | Title with the cwd basename + a ~160-char excerpt of Codex's last message (`last_assistant_message`). |
| **UserPromptSubmit** | Yes | A short excerpt of your reply — also tells the Vibez app to lift the shield for this session. |

PermissionRequest pings are suppressed in `dontAsk` and `bypassPermissions` modes — those modes never show the user a prompt, so a phone ping wouldn't be actionable.

## Install

1. Get the [ntfy app](https://ntfy.sh/app) on your phone (iOS / Android / web).
2. Add the marketplace and install:

   ```
   codex plugin marketplace add Peter-Zhao-751/Vibez
   codex plugin install vibez@vibez
   ```

   `codex plugin marketplace add` also accepts full Git HTTPS/SSH URLs or a local directory if you're hacking on the plugin (`codex plugin marketplace add /path/to/Vibez`).

3. **Open Codex as normal.** The first session after install auto-generates your private topic and shows you a system message with the subscribe URL.

4. Ask Codex something like "show me my vibez URL" to surface it again, or "send a test push to my vibez setup" to verify wiring.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `NTFY_TOPIC` | auto-generated | Override the topic. Useful for sharing one topic across multiple machines. |
| `NTFY_SERVER` | `https://ntfy.sh` | Self-hosted ntfy server URL. |
| `NTFY_AUTH` | unset | Bearer token for protected topics. Sent as `Authorization: Bearer <token>`. |

The auto-generated topic lives at `~/.config/vibez/topic`. The plugin also writes a debug log to `~/.config/vibez/log`. If you previously used the Claude Code vibez plugin (pre-0.9), the old `~/.config/claude-ntfy/` directory is migrated in place on first run.

## Skill

- `vibez-setup` — surfaces the subscribe URL, sends a test push, or rotates the topic. Triggered by asking Codex about your vibez URL, testing your setup, or rotating the topic.

## Privacy and security

ntfy.sh's free public service has no accounts. Anyone who knows your topic name can publish to it AND read your notifications. The plugin generates a 32-character random topic by default (~190 bits of entropy), which is effectively unguessable, but if anyone ever sees your URL — in a screenshot, log, or shared screen — rotate it.

For stricter privacy, [self-host ntfy](https://docs.ntfy.sh/install/) and point `NTFY_SERVER` at it.

## Failure mode

Hooks are designed never to block Codex. If the ntfy server is unreachable or `curl` errors, the script logs to `~/.config/vibez/log` and exits 0 — Codex proceeds, you just don't get the push.

## Layout

```
CodexPlugin/
  .codex-plugin/plugin.json              manifest
  hooks.json                             SessionStart / PermissionRequest / Stop / UserPromptSubmit wiring
  scripts/notify.sh                      hook dispatcher
  scripts/setup.sh                       vibez-setup skill implementation
  skills/vibez-setup/SKILL.md            skill definition
  README.md
```
