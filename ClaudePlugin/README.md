# vibez-ntfy

A Claude Code plugin that pushes session events to your phone via [ntfy.sh](https://ntfy.sh/) — so you can step away while Claude works and get pinged the moment it needs you or finishes a task.

## What it does

| Event | Push? | What you see on your phone |
|---|---|---|
| **SessionStart** (first run only) | Internal | A banner inside Claude Code with your subscribe URL. |
| **SessionStart** (subsequent runs) | No | Nothing. |
| **Notification** | Yes (high priority) | The actual message Claude is asking about — e.g. "Permission required to run npm install" or "Claude is waiting for your input". |
| **Stop** | Yes (default priority) | Title with the project name + a ~160-char excerpt of Claude's last message. |

## Install

1. Get the [ntfy app](https://ntfy.sh/app) on your phone (iOS / Android / web).
2. Install [`qrencode`](https://fukuchi.org/works/qrencode/) on your Mac (optional, for the inline QR): `brew install qrencode`.
3. Add this plugin in Claude Code:

   ```
   /plugin marketplace add Peter-Zhao-751/Vibez
   /plugin install vibez-ntfy@vibez
   ```

   For local development against a checkout, swap the first command for `/plugin marketplace add /path/to/Vibez`. See [Claude Code plugins docs](https://code.claude.com/docs/en/plugins).

4. **Open Claude Code as normal.** The first session after install auto-generates your private topic and shows you a banner with the subscribe URL.

5. Run `/ntfy-setup` to display the URL again with an inline QR code. Open ntfy on your phone, tap **+**, paste the URL (or scan the QR), done.

6. Verify: `/ntfy-setup test` — you should get a push within a few seconds.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `NTFY_TOPIC` | auto-generated | Override the topic. Useful if you want one topic across multiple machines. |
| `NTFY_SERVER` | `https://ntfy.sh` | Self-hosted ntfy server URL. |
| `NTFY_AUTH` | unset | Bearer token for protected topics. Sent as `Authorization: Bearer <token>`. |

The auto-generated topic lives at `~/.config/claude-ntfy/topic`. The plugin also writes a debug log to `~/.config/claude-ntfy/log`.

## Slash commands

- `/ntfy-setup` — show subscribe URL + QR.
- `/ntfy-setup test` — send a test push.
- `/ntfy-setup regenerate` — discard the current topic and create a new one. You'll need to resubscribe on your phone.

## Privacy and security

ntfy.sh's free public service has no accounts. Anyone who knows your topic name can publish to it AND read your notifications. The plugin generates a 32-character random topic by default (~190 bits of entropy), which is effectively unguessable, but if anyone ever sees your URL — in a screenshot, log, or shared screen — regenerate.

For stricter privacy, [self-host ntfy](https://docs.ntfy.sh/install/) and point `NTFY_SERVER` at it.

## Failure mode

Hooks are designed never to block Claude. If the ntfy server is unreachable or `curl` errors, the script logs to `~/.config/claude-ntfy/log` and exits 0 — Claude proceeds, you just don't get the push.

## Layout

```
ClaudePlugin/
  .claude-plugin/plugin.json       manifest
  hooks/hooks.json                 SessionStart / Notification / Stop wiring
  scripts/notify.sh                hook dispatcher
  scripts/ntfy-setup.sh            /ntfy-setup implementation
  commands/ntfy-setup.md           slash command definition
  README.md
```
