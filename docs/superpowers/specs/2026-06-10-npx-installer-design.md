# `npx getvibez` installer — design

**Date:** 2026-06-10
**Status:** approved

## Goal

One command — `npx getvibez` — installs the Vibez plugin into every supported agent CLI
(Claude Code, Codex) on the machine. The npm package is a thin wrapper that shells out
to the official plugin commands; the plugins in `ClaudePlugin/` and `CodexPlugin/`
remain the single source of truth. The installer never duplicates hook logic.

## Package

- npm name: **`getvibez`** (bare `vibez` was rejected by npm's typosquat filter as too similar to `vite`/`viem`, and the `vibez` org scope was already taken), published from `installer/` in this repo.
- Zero runtime dependencies, single ESM file `cli.mjs`, `bin: { vibez: "./cli.mjs" }`,
  Node >= 18, MIT.

## Behavior of `npx getvibez`

1. **Detect** agent CLIs on PATH: `claude`, `codex`. Also check prereqs `jq` and `curl`
   (the hooks' `notify.sh` needs them) and warn if missing — non-fatal.
2. **Checklist prompt**: list what was detected; ask per detected CLI
   "Install Vibez for Claude Code? (Y/n)". Undetected CLIs are reported as skipped with
   an install hint. If nothing is detected: friendly message + links, exit 1.
3. **Install** per selection, two commands per CLI run as a unit:
   - Claude Code: `claude plugin marketplace add Peter-Zhao-751/Vibez` then
     `claude plugin install vibez@plugin`
   - Codex: `codex plugin marketplace add Peter-Zhao-751/Vibez` then
     `codex plugin add vibez@vibez` (Codex's install verb is `add`, not `install`)
   - Idempotent: "already added / already installed" outcomes count as success and are
     reported as such. (The Claude marketplace spec is `vibez@plugin`, Codex's is
     `vibez@vibez` — historical naming; the installer hides the inconsistency.)
4. **Summary + pairing steps**: per-CLI result, App Store link, "open a new session to
   get your 4-word Vibez ID", `/vibez:setup`.

## Flags

- `--claude` / `--codex` — narrow targets, skip the prompt
- `-y` / `--yes` — non-interactive, all detected
- `--dry-run` — print the commands that would run, run nothing
- `--help`, `--version`

## Error handling

- A plugin command fails → print its output verbatim, continue with the other CLI,
  exit non-zero at the end.
- Ctrl-C at the prompt → clean exit, nothing half-done.

## Testing

- `installer/test.mjs`: assertions over `--dry-run` output (target selection, flag
  handling, command lines).
- Manual real run on a machine with both CLIs installed (idempotent re-run case).

## Docs

`npx getvibez` becomes the headline install in the root README and both plugin READMEs;
manual `/plugin` commands stay as the fallback.
