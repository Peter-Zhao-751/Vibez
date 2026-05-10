---
description: Show your ntfy.sh subscribe URL and QR code (also: /ntfy-setup test, /ntfy-setup regenerate)
argument-hint: "[show|test|regenerate]"
allowed-tools: Bash
---

Run the ntfy setup script with the user's argument and show its full output verbatim. Do not summarize — the user wants to see the URL and the QR code as printed.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ntfy-setup.sh" $ARGUMENTS
```

After showing the output, briefly tell the user what they should do next based on which action ran:
- `show` (default) — open the ntfy app on their phone, tap subscribe, paste the URL or scan the QR.
- `test` — they should hear/see a notification on their phone within a few seconds. If not, check that they actually subscribed and that their phone is online.
- `regenerate` — they need to resubscribe in the ntfy app to the NEW URL; the old one stops working.
