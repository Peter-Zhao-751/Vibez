# vibez

A Claude Code plugin that pushes session events to your phone via Firebase Cloud Messaging — so you can step away while Claude works and get pinged the moment it needs you or finishes a task. When it pings you, the Vibez iOS app raises a Screen Time shield over your distracting apps until you come back.

## What it does

| Event | Push? | What you see on your phone |
|---|---|---|
| **SessionStart** (first run only) | Internal | A banner inside Claude Code with your 4-word Vibez ID. |
| **SessionStart** (subsequent runs) | No | Nothing. |
| **Notification / AskUserQuestion** | Yes | What Claude needs — a permission prompt ("Permission required to run npm install") or the question it's asking. Raises the shield (`shield:on`). The 60-second idle reminder is filtered out. |
| **Stop** | Yes | Title with the conversation name + a ~160-char excerpt of Claude's last message. |
| **UserPromptSubmit / tool grant** | Yes | A short excerpt of your reply (or a note that you granted a tool) — also tells the Vibez app to lift the shield for this session (`shield:off`). |

## Install

1. Get the Vibez iOS app on your iPhone — [free on the App Store](https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780).
2. Make sure `jq` and `curl` are on your Mac — the hook needs them to build and POST events. `brew install jq` if missing.
3. Add this plugin — quickest is the installer (also covers Codex if you have it):

   ```
   npx getvibez
   ```

   Or by hand in Claude Code:

   ```
   /plugin marketplace add Peter-Zhao-751/Vibez
   /plugin install vibez@plugin
   ```

   For local development against a checkout, swap the first command for `/plugin marketplace add /path/to/Vibez`. See [Claude Code plugins docs](https://code.claude.com/docs/en/plugins).

4. **Open Claude Code as normal.** The first session after install auto-generates your private Vibez ID and shows you a banner with it.

5. Run `/vibez:setup` to display the Vibez ID again. Open Vibez on your phone and type it into the Setup card.

6. Verify: `/vibez:setup test` — you should get a push within a few seconds.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `VIBEZ_ID` | from `~/.config/vibez/vibez-id` | Force a specific Vibez ID. Useful if you want one ID across multiple machines without copying the file. |
| `VIBEZ_BACKEND_URL` | `https://us-central1-vibez-backend.cloudfunctions.net` | Point the plugin at a different Firebase deployment. |

The Vibez ID lives at `~/.config/vibez/vibez-id`. The plugin also writes a debug log to `~/.config/vibez/log`. (If you installed before 0.9.0, an older directory named `claude-ntfy/` is auto-migrated on first run.)

## Slash commands

- `/vibez:setup` — show your Vibez ID.
- `/vibez:setup test` — send a test push.
- `/vibez:setup regenerate` — discard the current Vibez ID and create a new one. You'll need to re-enter it in the app.

## Privacy and security

Your Vibez ID is a shared secret: anyone who learns it can push notifications — and raise shields — on your phone. The four words carry ~44 bits of entropy, so it's effectively unguessable, but if it ever appears in a screenshot, log, or shared screen, regenerate with `/vibez:setup regenerate`.

Pushes flow through the project's Firebase project; the APNs auth key never ships in the plugin. See the repo's [Privacy Policy](../PRIVACY.md) for what the iOS app and backend handle.

## Failure mode

Hooks are designed never to block Claude. If the backend is unreachable or `curl`/`jq` errors, the script logs to `~/.config/vibez/log` and exits 0 — Claude proceeds, you just don't get the push.

## Layout

```
ClaudePlugin/
  .claude-plugin/plugin.json       manifest
  hooks/hooks.json                 SessionStart / Notification / PreToolUse / PostToolUse / Stop / UserPromptSubmit wiring
  scripts/notify.sh                hook dispatcher (POSTs events to the Firebase /notify function)
  scripts/setup.sh                 /vibez:setup implementation (Vibez ID generation)
  commands/setup.md                slash command definition
  README.md
```
