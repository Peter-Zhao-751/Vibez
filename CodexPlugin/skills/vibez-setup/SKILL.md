---
name: vibez-setup
description: Show, regenerate, or test the user's Vibez ID for the vibez plugin's push notifications. Use when the user asks for their Vibez ID, wants to verify push notifications work, or wants to rotate to a new ID.
---

# vibez-setup

The vibez plugin auto-generates the 4-word Vibez ID on first SessionStart and shows it in a system message. Use this skill to surface the Vibez ID again, send a test push, or regenerate it.

The plugin root is two directories up from this `SKILL.md` (i.e., `skills/vibez-setup/../../`). The setup script lives at `<plugin-root>/scripts/setup.sh`.

## Usage

Run the relevant subcommand and show the script's stdout to the user verbatim:

```bash
bash <plugin-root>/scripts/setup.sh show         # default — show the current Vibez ID
bash <plugin-root>/scripts/setup.sh test         # send a test push to the paired phone
bash <plugin-root>/scripts/setup.sh regenerate   # discard the current Vibez ID and create a new one
```

Pick the subcommand from what the user asked for:

- "show me my vibez ID" / "what's my Vibez ID" → `show`
- "test my vibez setup" / "send a test push" → `test`
- "regenerate my Vibez ID" / "rotate it" / "the ID leaked" → `regenerate`

After running, output the script's stdout verbatim as the response. No prose, no formatting around it — the script prints exactly what the user should see.

## Notes

- The Vibez ID lives at `~/.config/vibez/vibez-id` and is shared with the Claude Code vibez plugin, so a single Vibez ID on the phone receives pushes from both agents.
- `regenerate` invalidates the previous pairing; the user must re-enter the new Vibez ID in the app.
- Environment overrides: `VIBEZ_ID` forces a specific Vibez ID, `VIBEZ_BACKEND_URL` points at a different Firebase deployment.
