# vibez

One-command installer for the [Vibez](https://github.com/Peter-Zhao-751/Vibez) agent plugins — push Claude Code and Codex session events (permission prompts, questions, task completion) to your iPhone, and shield your distracting apps until you come back.

```sh
npx getvibez
```

Detects which agent CLIs you have (`claude`, `codex`), asks which to install for, and runs each CLI's own plugin manager:

- **Claude Code** → `claude plugin marketplace add Peter-Zhao-751/Vibez` + `claude plugin install vibez@plugin`
- **Codex** → `codex plugin marketplace add Peter-Zhao-751/Vibez` + `codex plugin add vibez@vibez`

Safe to re-run; already-installed plugins are detected and skipped.

## Options

| Flag | Effect |
|---|---|
| `--claude` / `--codex` | Install for one CLI only, no prompt |
| `-y`, `--yes` | Install for every detected CLI, no prompt |
| `--dry-run` | Print the commands without running them |

## After installing

1. Get the Vibez iOS app — [free on the App Store](https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780).
2. Open a new agent session — it prints your private 4-word Vibez ID (in Claude Code, `/vibez:setup` shows it again).
3. Enter the ID in the app's Setup card. One ID covers both agents.

Requires Node ≥ 18, plus `jq` and `curl` on the machine (the notification hooks use them; the installer warns if they're missing).

Full plugin docs: [ClaudePlugin](https://github.com/Peter-Zhao-751/Vibez/tree/main/ClaudePlugin) · [CodexPlugin](https://github.com/Peter-Zhao-751/Vibez/tree/main/CodexPlugin)
