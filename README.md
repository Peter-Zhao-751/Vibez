<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/wordmark/wordmark-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/wordmark/wordmark-light.svg">
  <img src="assets/wordmark/wordmark-light.svg" alt="Vibez" width="360">
</picture>

**Block distracting apps when your coding agent needs you back.**

Vibez connects Claude Code and Codex lifecycle events to an iOS Screen Time shield. When your agent stops, asks for permission, or needs a reply, your selected apps lock until you return.

<sub>iOS Screen Time API · Claude Code plugin · Codex plugin · ntfy bridge</sub>

<br><br>

<a href="ClaudePlugin/README.md"><img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude_Code-plugin-dd7a52?style=flat-square&labelColor=1a0e08"></a>
<a href="CodexPlugin/README.md"><img alt="Codex plugin" src="https://img.shields.io/badge/Codex-plugin-dd7a52?style=flat-square&labelColor=1a0e08"></a>
<a href="#ios-app"><img alt="iOS app" src="https://img.shields.io/badge/iOS_app-local_build-fff5e8?style=flat-square&labelColor=1a0e08"></a>

</div>

## What It Does

Coding agents create a weird failure mode: the work is automated, but your attention is still the bottleneck. Vibez turns agent idle states into a phone-side block signal.

| Agent event | Vibez plugin | iOS app |
|---|---|---|
| First session after install | Generates a private ntfy topic and shows the subscribe URL. | Subscribes to the same topic. |
| Permission request or explicit notification | Sends a `needs-input` push with `shield:on`. | Records the trigger, shows the message, and applies the Screen Time shield. |
| Agent stops after a response | Sends a `done` push with a short assistant excerpt and `shield:on`. | Keeps selected apps blocked for the configured window. |
| You submit the next prompt | Sends a `replied` push with `shield:off`. | Clears that session's trigger and lifts the shield when no triggers remain. |

The Claude Code and Codex plugins share one topic at `~/.config/vibez/topic`, so one phone subscription can cover both agents.

## Components

| Path | Status | Purpose |
|---|---|---|
| [`ClaudePlugin/`](ClaudePlugin/) | Working | Claude Code plugin for `SessionStart`, `Notification`, `Stop`, and `UserPromptSubmit` hooks. |
| [`CodexPlugin/`](CodexPlugin/) | Working | Codex plugin for `SessionStart`, `PermissionRequest`, `Stop`, and `UserPromptSubmit` hooks. |
| [`Vibez/`](Vibez/) | Local build | SwiftUI iOS app that listens to ntfy, records recent triggers, and applies Family Controls / Managed Settings shields. |
| [`assets/`](assets/) | Working assets | Logo, glyph, icon, and README artwork. |

## Install Agent Plugins

Install either plugin, or install both. They share the same ntfy topic automatically.

### Claude Code

```sh
/plugin marketplace add Peter-Zhao-751/Vibez
/plugin install vibez@plugin
```

Then open Claude Code. The first session prints your private subscribe URL. Run `/vibez:setup` to show it again with a QR code, or `/vibez:setup test` to send a test push.

Full details: [`ClaudePlugin/README.md`](ClaudePlugin/README.md)

### Codex

```sh
codex plugin marketplace add Peter-Zhao-751/Vibez
codex plugin install vibez-codex@vibez
```

Then open Codex. The first session prints your private subscribe URL. You can later ask Codex to show your Vibez URL or send a test push.

Full details: [`CodexPlugin/README.md`](CodexPlugin/README.md)

## iOS App

The iOS app is built around Apple's `FamilyControls` and `ManagedSettings` frameworks:

1. Paste or scan your ntfy subscribe URL.
2. Grant notification permission.
3. Grant Screen Time / Family Controls permission.
4. Pick the apps, categories, or websites to shield.
5. Leave Vibez enabled while your agent works.

Distribution is still gated by Apple. Local device builds need a paid Apple Developer Program team because Apple does not grant the `family-controls` entitlement to personal teams. App Store distribution also requires Apple's Family Controls Distribution Request review. The simulator is useful for compile checks, but Screen Time shields are no-ops there.

## Configuration

Both plugins read the same environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `NTFY_TOPIC` | Auto-generated | Override the shared topic. Useful when you want multiple machines on one subscription. |
| `NTFY_SERVER` | `https://ntfy.sh` | Use a self-hosted ntfy server. |
| `NTFY_AUTH` | unset | Bearer token for protected ntfy topics. |

The generated topic and plugin log live in `~/.config/vibez/`.

## Privacy

Public ntfy topics are secret-by-name. Anyone with the topic URL can publish to it and read messages from it. Vibez generates a 32-character random topic by default, but you should rotate it if it appears in a screenshot, stream, log, or shared terminal.

For stricter privacy, self-host ntfy and set `NTFY_SERVER` and `NTFY_AUTH`.

## Repo Layout

```text
Vibez/
├── Vibez/                  iOS app (SwiftUI, Screen Time API)
├── ClaudePlugin/           Claude Code plugin
├── CodexPlugin/            Codex plugin
├── assets/                 Logos, icons, lockups, glyphs
├── docs/                   Design notes and implementation plans
├── Vibez.xcodeproj/
└── CLAUDE.md               Project context for agent sessions
```

## Current Status

- Claude Code plugin: working.
- Codex plugin: working.
- iOS app: Screen Time shield flow implemented for local builds.
- App Store release: pending paid developer enrollment and Family Controls distribution approval.

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

<sub>Built by <a href="https://github.com/Peter-Zhao-751">@Peter-Zhao-751</a>.</sub>

</div>
