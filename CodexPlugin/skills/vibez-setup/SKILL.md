---
name: vibez-setup
description: Show, regenerate, or test the user's ntfy subscribe URL for the vibez plugin. Use when the user asks for their vibez URL, wants to verify push notifications work, or wants to rotate to a new topic.
---

# vibez-setup

The vibez plugin auto-generates the ntfy subscribe URL on first SessionStart and shows it in a system message. Use this skill to surface the URL again, send a test push, or rotate the topic.

The plugin root is two directories up from this `SKILL.md` (i.e., `skills/vibez-setup/../../`). The setup script lives at `<plugin-root>/scripts/setup.sh`.

## Usage

Run the relevant subcommand and show the script's stdout to the user verbatim:

```bash
bash <plugin-root>/scripts/setup.sh show         # default — show the current subscribe URL
bash <plugin-root>/scripts/setup.sh test         # send a test push to the configured topic
bash <plugin-root>/scripts/setup.sh regenerate   # discard the current topic and create a new one
```

Pick the subcommand from what the user asked for:

- "show me my vibez URL" / "what's my ntfy URL" → `show`
- "test my vibez setup" / "send a test push" → `test`
- "regenerate my topic" / "rotate it" / "the URL leaked" → `regenerate`

After running, output the script's stdout verbatim as the response. No prose, no formatting around it — the script prints exactly what the user should see.

## Notes

- The topic file lives at `~/.config/vibez/topic` and is shared with the Claude Code vibez plugin, so a single ntfy subscription on the phone receives pushes from both agents.
- `regenerate` invalidates the previous subscription; the user must re-subscribe on their phone.
- Environment overrides: `NTFY_TOPIC` forces a specific topic, `NTFY_SERVER` points at a self-hosted ntfy instance, `NTFY_AUTH` sends a bearer token.
