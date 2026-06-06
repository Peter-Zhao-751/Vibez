# Codex visual identity on blocking surfaces — design

**Date:** 2026-06-06
**Status:** Approved by Peter

## Context

Commit `dd04407` (2026-06-05) deliberately deleted all Codex theming: the
`Codex.imageset` asset (both targets), the cloud-bot vector in
`Mascots.swift`, the `Agent` enum / `Theme.make(agent:)` param, and the
per-agent branches in `BlockedOverlay`, `ShieldCardRenderer`,
`ScreenTimeManager`, and the `VibezShield` extension. Since then the app
renders Claude visuals regardless of which agent pings.

Peter wants the Codex identity back on **exactly two surfaces** — the
in-app blocking overlay and the OS shield deployed over other apps — while
the rest of the app (home screen, onboarding, settings) stays
Claude-themed. He re-added the logo asset as `codex.imageset` (lowercase;
the old one was `Codex`).

The push data flow is fully intact and needs **no changes**: a Codex push
carries `agent: "cx"`, and both writers of `shield-state.json` — the
host's `ScreenTimeManager.publishShieldContext` (foreground) and the NSE's
`publishShieldContext` in `VibezPushService/NotificationService.swift`
(background) — already map it to `codex`. The in-app overlay already
receives `message.agent == .codex`. Only the read/render side ignores the
agent today.

## Approach

Surgical restore from git history (`dd04407^`), adapted to the current
architecture. No `Agent` enum revival, no `Theme.make(agent:)` param, no
vector cloud-bot — the logo is the re-added PNG asset. No NSE or backend
changes.

Rejected alternatives:

- **Full revert of the theming half of `dd04407`** — drags back app-wide
  agent-theming machinery (agent pick, themed home screen) that should
  stay deleted.
- **Shared `AgentVisuals` abstraction across targets** — the codebase
  deliberately mirrors constants across targets (same convention as the
  `shieldState` dict schema) instead of sharing files.

## Design

### Colors (restored per-surface, from `dd04407^`)

| Surface | Codex accent | Used for |
|---|---|---|
| In-app overlay | periwinkle `#8c9ce8` (`Theme.codexBlue`) | radial glow, "BLOCKING IN PROGRESS" eyebrow |
| Shield card + extension | vivid blue `#4A7AFF` = RGB(0.29, 0.48, 1.00) | PNG glow, Close button, cool-navy background wash (25% blend) |

Claude surfaces keep the existing orange (`#dd7a52` overlay accent via
theme; RGB(0.95, 0.45, 0.20) on the shield).

### 1. In-app blocking overlay

- `Vibez/Theme.swift`: re-add `static let codexBlue = Color(hex: 0x8c9ce8)`
  on `Theme` — a constant only; `Theme.make()` keeps its no-param
  signature.
- `Vibez/BlockedOverlay.swift`: re-add the per-message branch —
  `isCodexMessage` (`message?.agent == .codex`) and
  `gradientColor` (`isCodexMessage ? Theme.codexBlue : theme.accent`).
  When Codex: `Image("codex")` (resizable, fit, 130×130) replaces
  `ClaudeMascot`; glow + eyebrow use `gradientColor`. Title, body,
  countdown, Dismiss are unchanged. Non-Codex and untagged pings render
  exactly as today.
- Restore a "Codex ping" preview exercising the blue path.

### 2. Shield card PNG (host-rendered)

- `Vibez/ShieldCardRenderer.swift`: restore
  `ShieldCardTheme.accent(_ agent:)` (codex → `#4A7AFF`, default →
  orange) and `ShieldCardMascot` (codex → `Image("codex")`; claude /
  both / none → Claude pixel critter). Restore the Codex preview.
- `Vibez/ScreenTimeManager.swift` `prerenderAgentShieldsIfNeeded()`:
  render **two** PNGs — `shield-claude.png` and `shield-codex.png` —
  idempotent by file existence. Remove `shield-codex.png` from the
  stale-prune list; keep pruning `shield.png`, `shield-both.png`,
  `shield-none.png` (the old both/none renders were Claude duplicates;
  the extension falls back instead).

### 3. Shield extension

- `VibezShield/ShieldCard.swift`: restore agent-aware `accentUIColor`
  (codex → `#4A7AFF`, else orange) and `backgroundUIColor` (same 25%
  accent-into-base blend, picking the codex or claude accent by agent).
- `VibezShield/ShieldConfigurationExtension.swift`: restore
  `loadCachedShieldImage(for: state.agent)` loading
  `shield-<agent>.png`, with a fallback chain:
  `both`/`none`/missing file → `shield-claude.png` → `nil` (text-only
  shield, existing behavior). The extension still never touches the
  asset catalog or renders SwiftUI.

### Asset cleanup

`Vibez/Assets.xcassets/codex.imageset/` currently duplicates the same
57 KB PNG at 1x/2x/3x. Slim to a single universal-scale entry
(`codex.png`), deleting `codex 1.png` / `codex 2.png` (~115 KB bundle
savings).

### Docs

Update CLAUDE.md (`Mascots.swift`, `Theme.swift`, `ShieldCardRenderer`,
`ScreenTimeManager`, `VibezShield` notes): Claude visuals app-wide,
**except** the two blocking surfaces, which are agent-aware again
(Codex logo + blues when a `cx` push engages them).

## Edge cases

- **Mixed concurrent sessions** (Claude + Codex triggers pending): the
  shield shows the most recent push's identity — last-writer-wins on
  `shield-state.json`. Same as pre-deletion behavior.
- **First launch after update**: `shield-codex.png` doesn't exist →
  prerender creates it; unchanged `shield-claude.png` stays put.
- **Asset rename**: code must reference lowercase `Image("codex")` —
  the old code's `Image("Codex")` would fail against the re-added asset.
- **Untagged pings** (`both`/`none` in shield state): Claude visuals
  everywhere, as today.

## Testing

- Unit-less visual verification via restored SwiftUI previews (overlay +
  shield card, Codex and Claude variants).
- Compile check: `xcodebuild` against `iphonesimulator26.4` for all
  three targets.
- Sim run with seeded state (`-vibez.vibezId test`) to eyeball the
  overlay's Codex path.
- On-device: `cx`-tagged test push to confirm the OS shield shows the
  Codex card (sim shields are no-ops — hard constraint).

## Files touched

```
Vibez/Theme.swift                                 (+1 constant)
Vibez/BlockedOverlay.swift                        (per-message branch + preview)
Vibez/ShieldCardRenderer.swift                    (per-agent accent + mascot + preview)
Vibez/ScreenTimeManager.swift                     (prerender 2 PNGs, prune list)
VibezShield/ShieldCard.swift                      (agent-aware colors)
VibezShield/ShieldConfigurationExtension.swift    (per-agent PNG + fallback)
Vibez/Assets.xcassets/codex.imageset/             (slim to 1x universal)
CLAUDE.md                                         (status/notes refresh)
```
