<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/wordmark/wordmark-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/wordmark/wordmark-light.svg">
  <img src="assets/wordmark/wordmark-light.svg" alt="Vibez" width="360">
</picture>

**Block distracting apps when your coding agent needs you back.**

Vibez connects Claude Code, Codex, and Cursor lifecycle events to an iOS Screen Time shield. When your agent stops, asks for permission, or needs a reply, your selected apps lock until you return.

<sub>iOS Screen Time API · Claude Code plugin · Codex plugin · Cursor plugin · Firebase Cloud Messaging</sub>

<br><br>

<a href="ClaudePlugin/README.md"><img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude_Code-plugin-d97757?style=flat-square&labelColor=1a0e08"></a>
<a href="CodexPlugin/README.md"><img alt="Codex plugin" src="https://img.shields.io/badge/Codex-plugin-d97757?style=flat-square&labelColor=1a0e08"></a>
<a href="CursorPlugin/README.md"><img alt="Cursor plugin" src="https://img.shields.io/badge/Cursor-plugin-d97757?style=flat-square&labelColor=1a0e08"></a>
<a href="https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780"><img alt="iOS app on the App Store" src="https://img.shields.io/badge/iOS_app-App_Store-d97757?style=flat-square&labelColor=1a0e08"></a>

<br><br>

<img src="assets/carousel/slide-1-pitch.png" width="18%" alt="“Claude's done. Stop scrolling.” — Vibez blocks distracting apps when Claude Code or Codex needs you">
<img src="assets/carousel/slide-2-ping.png" width="18%" alt="“Agent pings. Phone locks.” — a question or a finished task blocks your feeds until you reply">
<img src="assets/carousel/slide-3-agents-left.png" width="18%" alt="All your agents, one app — a Claude Code block, tinted orange">
<img src="assets/carousel/slide-4-agents-right.png" width="18%" alt="…and a Codex block, tinted blue — orange pings from Claude, blue from Codex">
<img src="assets/carousel/slide-5-setup.png" width="18%" alt="“One command. You're paired.” — npx getvibez prints a private 4-word ID that pairs your Mac to your phone">

</div>

## What It Does

Coding agents create a weird failure mode: the work is automated, but your attention is still the bottleneck. Vibez turns agent idle states into a phone-side block signal.

| Agent event | Vibez plugin | iOS app |
|---|---|---|
| First session after install | Generates a private 4-word Vibez ID and prints it. | Enter the ID once in the Setup card to pair this Mac with your phone. |
| Permission request, question, or idle prompt | Sends a `needs-input` push with `shield:on`. | Records the trigger, shows the message, and applies the Screen Time shield. |
| Agent stops after a response | Sends a `done` push with a short assistant excerpt and `shield:on`. | Keeps selected apps blocked for the configured window. |
| You submit the next prompt | Sends a `replied` push with `shield:off`. | Clears that session's trigger and lifts the shield when no triggers remain. |

The Claude Code, Codex, and Cursor plugins share one Vibez ID at `~/.config/vibez/vibez-id`, so a single pairing on your phone covers every agent.

## Components

| Path | Status | Purpose |
|---|---|---|
| [`ClaudePlugin/`](ClaudePlugin/) | Working | Claude Code plugin for `SessionStart`, `Notification`, `PreToolUse`, `PostToolUse`, `Stop`, and `UserPromptSubmit` hooks. |
| [`CodexPlugin/`](CodexPlugin/) | Working | Codex plugin for `SessionStart`, `PermissionRequest`, `PreToolUse`, `PostToolUse`, `Stop`, and `UserPromptSubmit` hooks. |
| [`CursorPlugin/`](CursorPlugin/) | Working | Cursor agent hooks (`sessionStart`, `beforeSubmitPrompt`, `afterAgentResponse`, `stop`, `sessionEnd`), installed via `npx vibez-cursor`. |
| [`Vibez/`](Vibez/) | [On the App Store](https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780) | SwiftUI iOS app that receives FCM pushes, records recent triggers, and applies Family Controls / Managed Settings shields. |
| [`Backend/`](Backend/) | Working | Firebase Cloud Functions (`registerPushToken`, `notify`, `dispatchUnblock`) that pair devices and fan out pushes via FCM. |
| [`VibezExtension/`](VibezExtension/) | Local build | Chrome (MV3) extension that mirrors the block on desktop browsers. |
| [`assets/`](assets/) | Working assets | Logo, glyph, icon, and README artwork. |

## Install Agent Plugins

One command — it detects Claude Code, Codex, and Cursor and installs for each:

> ## `npx getvibez`

Then open a new agent session: it prints your private 4-word Vibez ID — enter it once in the iOS app and you're paired (one ID covers every agent). To see the ID again, run `/vibez:setup` in Claude Code, `$vibez-setup` in Codex, or `npx vibez-cursor --id`; `/vibez:setup test` sends a test push. **Re-run `npx getvibez` anytime to update.** Requires Node ≥ 18; Codex asks you to trust the plugin's hooks on first launch — that's expected.

Full details: [`ClaudePlugin/README.md`](ClaudePlugin/README.md) · [`CodexPlugin/README.md`](CodexPlugin/README.md) · [`CursorPlugin/README.md`](CursorPlugin/README.md)

<details>
<summary>Manual install (without npx)</summary>

**Claude Code**

```sh
/plugin marketplace add Peter-Zhao-751/Vibez
/plugin install vibez@plugin
```

**Codex**

```sh
codex plugin marketplace add Peter-Zhao-751/Vibez
codex plugin add vibez@vibez
```

**Cursor**

```sh
npx vibez-cursor
```

(Cursor has no plugin manager — the installer registers the hooks in `~/.cursor/hooks.json` directly; `npx vibez-cursor --uninstall` removes them.)

</details>

## iOS App

**[AI Coding Focus — Vibez](https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780)** is free on the App Store.

The app is built around Apple's `FamilyControls` and `ManagedSettings` frameworks:

1. Enter your 4-word Vibez ID.
2. Grant notification permission.
3. Grant Screen Time / Family Controls permission.
4. Pick the apps, categories, or websites to shield.
5. Leave Vibez enabled while your agent works.

Building from source instead needs a paid Apple Developer Program team because Apple does not grant the `family-controls` entitlement to personal teams. The simulator is useful for compile checks, but Screen Time shields are no-ops there.

## Configuration

All plugins read the same optional environment overrides:

| Variable | Default | Purpose |
|---|---|---|
| `VIBEZ_ID` | from `~/.config/vibez/vibez-id` | Force a specific Vibez ID — e.g. to drive several machines from one ID without copying the file. |
| `VIBEZ_BACKEND_URL` | `https://us-central1-vibez-backend.cloudfunctions.net` | Point the plugins at a different Firebase deployment. |

The generated Vibez ID and a debug log live in `~/.config/vibez/`.

## Privacy

Your Vibez ID is a shared secret: anyone who learns it can push notifications — and raise shields — on your phone. The four-word ID carries ~44 bits of entropy, enough to make guessing impractical, but rotate it with `/vibez:setup regenerate` if it ever appears in a screenshot, stream, log, or shared terminal.

The push pipeline runs on the project owner's Firebase project. The APNs auth key (`.p8`) lives in Firebase Cloud Messaging and never ships to clients.

See the full [Privacy Policy](PRIVACY.md) for what data the iOS app handles and what stays on your device.

## Repo Layout

```text
Vibez/
├── Vibez/                  iOS app (SwiftUI, Screen Time API)
├── VibezShield/            Shield Configuration Extension (custom shield UI)
├── VibezPushService/       Notification Service Extension (engages the shield pre-banner)
├── ClaudePlugin/           Claude Code plugin
├── CodexPlugin/            Codex plugin
├── CursorPlugin/           Cursor hooks plugin (npm: vibez-cursor)
├── Backend/                Firebase Cloud Functions (push fan-out + scheduling)
├── VibezExtension/         Chrome (MV3) browser companion
├── assets/                 Logos, icons, lockups, glyphs, app mockups
├── docs/                   Design notes and implementation plans
├── Vibez.xcodeproj/
└── CLAUDE.md               Project context for agent sessions
```

## Current Status

- Claude Code plugin: working.
- Codex plugin: working.
- Cursor plugin: working.
- iOS app: [free on the App Store](https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780).

## License

TBD.

<div align="center">

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/glyph/pixel-z-cream.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/glyph/pixel-z-ink.svg">
  <img src="assets/glyph/pixel-z-ink.svg" width="42" alt="">
</picture>

<br>

<sub>Built by <a href="https://github.com/Peter-Zhao-751">@Peter-Zhao-751</a>. Original idea by <a href="https://github.com/yiguozhang822">@yiguozhang822</a>.</sub>

</div>
