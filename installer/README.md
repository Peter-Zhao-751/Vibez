# vibez

One-command installer for the [Vibez](https://github.com/Peter-Zhao-751/Vibez) agent plugins — push Claude Code, Codex, and Cursor session events (permission prompts, questions, task completion) to your iPhone, and shield your distracting apps until you come back.

```sh
npx getvibez
```

Detects which agents you have (`claude`, `codex`, Cursor), asks which to install for, and runs each one's own installer (the CLI plugin managers for Claude Code and Codex; [`npx vibez-cursor`](https://github.com/Peter-Zhao-751/Vibez/tree/main/CursorPlugin) for Cursor, which registers hooks in `~/.cursor/hooks.json`).

**Re-run it anytime to update**: already-installed plugins are refreshed from the marketplace and updated to the latest version.

## Options

| Flag | Effect |
|---|---|
| `--claude` / `--codex` / `--cursor` | Install for one agent only, no prompt |
| `-y`, `--yes` | Install for every detected agent, no prompt |
| `--dry-run` | Print the commands without running them |

## After installing

1. Get the Vibez iOS app — [free on the App Store](https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780).
2. Open a new agent session — it prints your private 4-word Vibez ID (in Claude Code, `/vibez:setup` shows it again; the Cursor install prints it directly, and `npx vibez-cursor --id` repeats it).
3. Enter the ID in the app's Setup card. One ID covers every agent.

Requires Node ≥ 18, plus `jq` and `curl` on the machine (the notification hooks use them; the installer warns if they're missing).

Full plugin docs: [ClaudePlugin](https://github.com/Peter-Zhao-751/Vibez/tree/main/ClaudePlugin) · [CodexPlugin](https://github.com/Peter-Zhao-751/Vibez/tree/main/CodexPlugin) · [CursorPlugin](https://github.com/Peter-Zhao-751/Vibez/tree/main/CursorPlugin)
