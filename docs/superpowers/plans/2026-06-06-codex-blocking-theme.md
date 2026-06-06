# Codex Identity on Blocking Surfaces — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Codex push engages the in-app blocking overlay or the OS shield, render the Codex logo + blues instead of the Claude critter + orange — everywhere else stays Claude.

**Architecture:** Surgical restore of the per-agent visual branches deleted in commit `dd04407` (2026-06-05), adapted to today's code. The data flow already carries the agent end-to-end (push `agent: "cx"` → `shield-state.json` via both the host's `publishShieldContext` and the NSE's background writer; the overlay already gets `message.agent`) — only the render side changes. Host pre-renders one PNG per agent into the App Group; the shield extension picks by agent with a Claude fallback.

**Tech Stack:** SwiftUI (iOS 26.4 SDK), ManagedSettingsUI shield extension, asset catalogs. No backend, no NSE changes.

**Spec:** `docs/superpowers/specs/2026-06-06-codex-blocking-theme-design.md` (approved 2026-06-06).

---

## Context you must know before starting

1. **Working directory & branch:** Execute at the repo root `/Users/peter/Desktop/Vibez` on `main` (this session is NOT in a managed worktree; per CLAUDE.md real changes belong on `main`).
2. **The working tree is dirty with UNRELATED user changes** (`README.md`s, `Vibez.xcodeproj/project.pbxproj`, a stray `Vibez (standalone) (1).html`). **Never use `git add -A`, `git add .`, or `git commit -a`.** Every commit in this plan names explicit paths. Do not touch `project.pbxproj` — the project uses `PBXFileSystemSynchronizedRootGroup`, so file adds/removals inside target folders and asset catalogs need no pbxproj edits.
3. **No iOS test target exists** (schemes: Vibez, VibezPushService, VibezShield; tests exist only for backend TypeScript). Adding XCTest is out of scope. Verification per task = a clean `xcodebuild` compile; end-to-end visual verification = simulator screenshots in Task 7 (the repo's established playbook). The OS shield itself is a no-op in the simulator (hard constraint) — final shield check is a manual on-device step handed to Peter.
4. **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** is on. Don't add `nonisolated` except where the existing code already has it (the VibezShield files use it deliberately).
5. **The asset is lowercase `codex`** (`Vibez/Assets.xcassets/codex.imageset`, added by Peter, currently staged). The pre-deletion code referenced `Image("Codex")` — that name is dead; always write `Image("codex")`.
6. **Build command** (used in every task; first run is slow, later runs are incremental):
   ```bash
   cd /Users/peter/Desktop/Vibez && xcodebuild -project Vibez.xcodeproj -scheme Vibez -sdk iphonesimulator26.4 -destination 'generic/platform=iOS Simulator' -derivedDataPath build build 2>&1 | tail -3
   ```
   Expected last line: `** BUILD SUCCEEDED **`. The Vibez scheme builds the app plus both embedded extensions (VibezShield, VibezPushService).
7. **Colors (from the deleted design, restored per-surface):**
   - Overlay (in-app): periwinkle `#8c9ce8` → `Theme.codexBlue`
   - Shield (PNG glow, Close button, background wash): vivid blue RGB(0.29, 0.48, 1.00) ≈ `#4A7AFF`
   - Claude stays: overlay `theme.accent` (`#dd7a52`); shield RGB(0.95, 0.45, 0.20)

---

### Task 1: Slim the codex imageset and commit it

The imageset ships the same 57,686-byte PNG three times (1x/2x/3x). One universal entry is enough (the PNG is 500×500 px; largest use is 130 pt). Committing the asset FIRST keeps later commits (which reference `Image("codex")`) self-contained.

**Files:**
- Modify: `Vibez/Assets.xcassets/codex.imageset/Contents.json`
- Delete: `Vibez/Assets.xcassets/codex.imageset/codex 1.png`, `Vibez/Assets.xcassets/codex.imageset/codex 2.png`

- [ ] **Step 1: Confirm the three PNGs are byte-identical** (they should be; if not, STOP and ask Peter which to keep)

```bash
cd /Users/peter/Desktop/Vibez/Vibez/Assets.xcassets/codex.imageset && cmp codex.png "codex 1.png" && cmp codex.png "codex 2.png" && echo IDENTICAL
```

Expected: `IDENTICAL`

- [ ] **Step 2: Rewrite Contents.json to a single universal entry**

Replace the entire contents of `Vibez/Assets.xcassets/codex.imageset/Contents.json` with:

```json
{
  "images" : [
    {
      "filename" : "codex.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Remove the duplicate PNGs** (they are staged-new, so `git rm -f` both unstages and deletes)

```bash
cd /Users/peter/Desktop/Vibez && git rm -f "Vibez/Assets.xcassets/codex.imageset/codex 1.png" "Vibez/Assets.xcassets/codex.imageset/codex 2.png"
```

- [ ] **Step 4: Build to prove the catalog still compiles**

Run the build command from the Context section. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit ONLY the imageset**

```bash
cd /Users/peter/Desktop/Vibez && git add Vibez/Assets.xcassets/codex.imageset && git commit Vibez/Assets.xcassets/codex.imageset -m "feat: add codex logo asset (single universal scale)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

Expected: 2 files changed (Contents.json + codex.png) — the two duplicates must NOT appear.

---

### Task 2: In-app blocking overlay goes Codex-aware

**Files:**
- Modify: `Vibez/Theme.swift:89-90` (add constant)
- Modify: `Vibez/BlockedOverlay.swift` (per-message branch, mascot, eyebrow, glow, preview)

- [ ] **Step 1: Add `Theme.codexBlue` and update Theme.swift's header comment**

In `Vibez/Theme.swift`, replace:

```swift
//  Color palette. Translated from the reference design's
//  `themeFor(agent, dark)` JS function, now pinned to the Claude
//  accent — the Codex theme/mascot is gone (visuals only: Codex
//  *pushes* still flow through the pipeline and block apps).
```

with:

```swift
//  Color palette. Translated from the reference design's
//  `themeFor(agent, dark)` JS function, pinned to the Claude accent.
//  The one Codex color (codexBlue) exists for the blocking surfaces
//  only — BlockedOverlay (and the shield card, which has its own
//  constants) go blue when a Codex push engages them; the rest of
//  the app stays Claude.
```

and replace:

```swift
    static let claudeOrange = Color(hex: 0xdd7a52)
    static let claudeDeep   = Color(hex: 0xb85a36)
```

with:

```swift
    static let claudeOrange = Color(hex: 0xdd7a52)
    static let claudeDeep   = Color(hex: 0xb85a36)
    /// Codex periwinkle — used ONLY by BlockedOverlay's per-message
    /// accent. The app theme stays Claude (Theme.make() has no agent
    /// param on purpose); blocking surfaces go blue per message.
    static let codexBlue    = Color(hex: 0x8c9ce8)
```

- [ ] **Step 2: Add the per-message branch to BlockedOverlay**

In `Vibez/BlockedOverlay.swift`, replace:

```swift
    private var bodyText: String {
        if let msg = message, !msg.body.isEmpty { return msg.body }
        return "Permission requested · 0:42 ago"
    }
```

with:

```swift
    private var bodyText: String {
        if let msg = message, !msg.body.isEmpty { return msg.body }
        return "Permission requested · 0:42 ago"
    }

    private var isCodexMessage: Bool {
        message?.agent == .codex
    }

    /// Per-message accent: Codex pings go periwinkle; everything else
    /// (Claude, untagged) keeps the app's Claude orange. Colors the
    /// radial glow + the "BLOCKING IN PROGRESS" eyebrow only.
    private var accentColor: Color {
        isCodexMessage ? Theme.codexBlue : theme.accent
    }
```

- [ ] **Step 3: Tint the radial glow per message**

In the same file, replace:

```swift
                        colors: [theme.accent.opacity(colorScheme == .dark ? 0.28 : 0.20), .clear],
```

with:

```swift
                        colors: [accentColor.opacity(colorScheme == .dark ? 0.28 : 0.20), .clear],
```

- [ ] **Step 4: Swap the mascot for the Codex logo on Codex pings**

Replace:

```swift
                ClaudeMascot(listening: true, size: 130)
                    .padding(.bottom, 18)
```

with:

```swift
                if isCodexMessage {
                    Image("codex")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .padding(.bottom, 18)
                } else {
                    ClaudeMascot(listening: true, size: 130)
                        .padding(.bottom, 18)
                }
```

- [ ] **Step 5: Tint the eyebrow per message**

Replace:

```swift
                Text("BLOCKING IN PROGRESS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(theme.accent)
```

with:

```swift
                Text("BLOCKING IN PROGRESS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(accentColor)
```

- [ ] **Step 6: Update the Codex preview to document the restored look**

Replace:

```swift
#Preview("Codex ping · Claude visuals · dark") {
    // Codex pushes still arrive ("cx" tag) — they just render with the
    // app's single Claude theme now.
```

with:

```swift
#Preview("Codex ping · logo + periwinkle · dark") {
    // Codex pushes ("cx" tag) render the Codex logo + periwinkle accent
    // on this overlay; the rest of the app stays Claude-themed.
```

(The preview's `BlockedOverlay(...)` arguments are already correct — it passes `agent: .codex`.)

- [ ] **Step 7: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
cd /Users/peter/Desktop/Vibez && git add Vibez/Theme.swift Vibez/BlockedOverlay.swift && git commit Vibez/Theme.swift Vibez/BlockedOverlay.swift -m "feat: Codex logo + periwinkle accent on the in-app blocking overlay

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Shield card renderer goes per-agent

**Files:**
- Modify: `Vibez/ShieldCardRenderer.swift`

- [ ] **Step 1: Make the accent per-agent**

Replace:

```swift
    /// Single Claude accent — every shield renders Claude visuals
    /// regardless of which agent's push engaged it.
    static let accent = Color(red: 0.95, green: 0.45, blue: 0.20)
```

with:

```swift
    /// Per-agent accent: vivid blue behind the Codex logo, Claude
    /// orange for everything else (claude/both/none).
    static func accent(_ agent: ShieldState.Agent) -> Color {
        switch agent {
        case .codex: Color(red: 0.29, green: 0.48, blue: 1.00)
        default:     Color(red: 0.95, green: 0.45, blue: 0.20)
        }
    }
```

- [ ] **Step 2: Pick glow color + mascot by agent in ShieldCardView**

Replace:

```swift
private struct ShieldCardView: View {
    let state: ShieldState

    var body: some View {
        ZStack {
            // Soft circular accent glow behind the mascot — gives the
            // icon a deliberate "branded" feel even at small sizes.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [ShieldCardTheme.accent.opacity(0.28), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )

            ShieldCardClaudePixel(size: 280)
        }
        .frame(width: 400, height: 400)
    }
}
```

with:

```swift
private struct ShieldCardView: View {
    let state: ShieldState

    private var accent: Color { ShieldCardTheme.accent(state.agent) }

    var body: some View {
        ZStack {
            // Soft circular accent glow behind the mascot — gives the
            // icon a deliberate "branded" feel even at small sizes.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.28), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )

            ShieldCardMascot(agent: state.agent, size: 280)
        }
        .frame(width: 400, height: 400)
    }
}

/// Codex renders the logo asset; everything else renders the Claude
/// pixel critter. Mirrors BlockedOverlay's per-message mascot pick.
private struct ShieldCardMascot: View {
    let agent: ShieldState.Agent
    var size: CGFloat = 110

    var body: some View {
        switch agent {
        case .codex:
            Image("codex")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .claude, .both, .none:
            ShieldCardClaudePixel(size: size)
        }
    }
}
```

- [ ] **Step 3: Fix the pixel critter's fill to the now-parameterized accent**

Replace:

```swift
            ClaudeBodyShape()
                .fill(ShieldCardTheme.accent)
```

with:

```swift
            ClaudeBodyShape()
                .fill(ShieldCardTheme.accent(.claude))
```

- [ ] **Step 4: Restore the Codex preview**

Append after the existing `#Preview("Claude · needs input")` block:

```swift
#Preview("Codex · light") {
    ShieldCardView(state: ShieldState(
        agent: .codex,
        title: "Wire up SSE handler",
        body: "Need confirmation before I rip out the polling fallback.",
        expiresAt: nil,
        dark: false
    ))
}
```

- [ ] **Step 5: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
cd /Users/peter/Desktop/Vibez && git add Vibez/ShieldCardRenderer.swift && git commit Vibez/ShieldCardRenderer.swift -m "feat: per-agent shield card (Codex logo + blue glow)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Host pre-renders both agent PNGs

**Files:**
- Modify: `Vibez/ScreenTimeManager.swift:457-496` (`prerenderAgentShieldsIfNeeded`)

- [ ] **Step 1: Render claude + codex PNGs; stop pruning shield-codex.png**

Replace the entire doc comment + function:

```swift
    /// The single Claude mascot PNG, written to the App Group container.
    /// VibezShield (extension) reads `shield-claude.png` and slots it
    /// into `ShieldConfiguration.icon` regardless of which agent's push
    /// engaged the shield — the Codex theme/mascot is gone. Pre-rendering
    /// here means the extension never has to run SwiftUI/ImageRenderer
    /// (which can trap in nonisolated extension contexts) AND
    /// VibezPushService (NSE) doesn't have to render either — both just
    /// write the `shieldState` dict, and the PNG is already on disk.
    ///
    /// Idempotent: skips when the PNG already exists. Bump the
    /// filename (or wipe the App Group container) when the visual
    /// changes.
    private func prerenderAgentShieldsIfNeeded() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return }

        // Legacy files: the pre-per-agent single PNG, and the per-agent
        // renders from when each agent had its own card. Safe to drop —
        // VibezShield only loads shield-claude.png now.
        for stale in ["shield.png", "shield-codex.png", "shield-both.png", "shield-none.png"] {
            try? FileManager.default.removeItem(
                at: container.appendingPathComponent(stale)
            )
        }

        let url = container.appendingPathComponent("shield-claude.png")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let state = ShieldState(
            agent: .claude,
            title: nil,
            body: nil,
            expiresAt: nil,
            dark: true
        )
        if let png = renderShieldCardPNG(state: state) {
            try? png.write(to: url)
            shieldLog.info("prerendered shield-claude.png")
        }
    }
```

with:

```swift
    /// The per-agent mascot PNGs, written to the App Group container.
    /// VibezShield (extension) reads `shield-<agent>.png` and slots it
    /// into `ShieldConfiguration.icon` — Claude pixel critter or Codex
    /// logo + blue glow, picked by the agent that engaged the shield
    /// (untagged pings fall back to the Claude card in the extension).
    /// Pre-rendering here means the extension never has to run
    /// SwiftUI/ImageRenderer (which can trap in nonisolated extension
    /// contexts) AND VibezPushService (NSE) doesn't have to render
    /// either — both just write the `shieldState` dict, and the PNGs
    /// are already on disk.
    ///
    /// Idempotent: skips PNGs that already exist. Bump the filenames
    /// (or wipe the App Group container) when the visuals change.
    private func prerenderAgentShieldsIfNeeded() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return }

        // Legacy files: the pre-per-agent single PNG, and the renders
        // for agents that no longer get their own card (both/none use
        // the extension's Claude fallback).
        for stale in ["shield.png", "shield-both.png", "shield-none.png"] {
            try? FileManager.default.removeItem(
                at: container.appendingPathComponent(stale)
            )
        }

        for agent in [ShieldState.Agent.claude, .codex] {
            let url = container.appendingPathComponent("shield-\(agent.rawValue).png")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            let state = ShieldState(
                agent: agent,
                title: nil,
                body: nil,
                expiresAt: nil,
                dark: true
            )
            if let png = renderShieldCardPNG(state: state) {
                try? png.write(to: url)
                shieldLog.info("prerendered shield-\(agent.rawValue, privacy: .public).png")
            }
        }
    }
```

Migration note (why this is safe with no version bump): devices on the current build delete `shield-codex.png` at every init, so after this update the file is simply absent → rendered fresh on first launch. `shield-claude.png` is visually unchanged → its existing copy stays.

- [ ] **Step 2: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
cd /Users/peter/Desktop/Vibez && git add Vibez/ScreenTimeManager.swift && git commit Vibez/ScreenTimeManager.swift -m "feat: pre-render Claude + Codex shield PNGs into the App Group

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Shield extension picks PNG + colors by agent

**Files:**
- Modify: `VibezShield/ShieldCard.swift:82-106` (accent + background colors)
- Modify: `VibezShield/ShieldConfigurationExtension.swift:57-109` (icon load + comments)

- [ ] **Step 1: Agent-aware accent in ShieldCard.swift**

Replace:

```swift
    /// Single Claude accent — the shield renders Claude visuals no
    /// matter which agent's push engaged it (the `agent` field is kept
    /// as schema data, not a theme switch).
    nonisolated var accentUIColor: UIColor {
        UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)
    }
```

with:

```swift
    /// Per-agent accent — vivid blue for Codex, Claude orange for
    /// everything else (claude/both/none). Colors the Close button.
    nonisolated var accentUIColor: UIColor {
        switch agent {
        case .codex: UIColor(red: 0.29, green: 0.48, blue: 1.00, alpha: 1.0)
        default:     UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)
        }
    }
```

- [ ] **Step 2: Agent-aware background wash in ShieldCard.swift**

Replace:

```swift
    nonisolated var backgroundUIColor: UIColor {
        // Tamed-down accent: 25% Claude orange blended into 75% of the
        // dark/light base — a warm-brown wash without going neon. The
        // flat ShieldConfiguration.backgroundColor slot cannot do
        // gradients, so this single tinted color is the closest
        // approximation.
        let mix: CGFloat = 0.25
        let (ar, ag, ab): (CGFloat, CGFloat, CGFloat) = (0.95, 0.45, 0.20)
        let dr: CGFloat = dark ? 0.047 : 0.984
        let dg: CGFloat = dark ? 0.051 : 0.973
        let db: CGFloat = dark ? 0.071 : 0.957
        return UIColor(
            red:   dr * (1 - mix) + ar * mix,
            green: dg * (1 - mix) + ag * mix,
            blue:  db * (1 - mix) + ab * mix,
            alpha: 1
        )
    }
```

with:

```swift
    nonisolated var backgroundUIColor: UIColor {
        // Tamed-down agent color: 25% accent blended into 75% of the
        // dark/light base. Gives a warm-brown wash for Claude/none/both
        // and a cool-navy wash for Codex without going neon. The flat
        // ShieldConfiguration.backgroundColor slot cannot do gradients,
        // so this single tinted color is the closest approximation.
        let mix: CGFloat = 0.25
        let (ar, ag, ab): (CGFloat, CGFloat, CGFloat)
        switch agent {
        case .codex:
            (ar, ag, ab) = (0.29, 0.48, 1.00)
        default:
            (ar, ag, ab) = (0.95, 0.45, 0.20)
        }
        let dr: CGFloat = dark ? 0.047 : 0.984
        let dg: CGFloat = dark ? 0.051 : 0.973
        let db: CGFloat = dark ? 0.071 : 0.957
        return UIColor(
            red:   dr * (1 - mix) + ar * mix,
            green: dg * (1 - mix) + ag * mix,
            blue:  db * (1 - mix) + ab * mix,
            alpha: 1
        )
    }
```

(⚠️ Copy carefully — each channel blends its OWN base with its OWN accent component: `db * (1 - mix) + ab * mix` for blue.)

- [ ] **Step 3: Per-agent PNG load in ShieldConfigurationExtension.swift**

Replace:

```swift
        // Icon comes from the host-pre-rendered PNG — always the Claude
        // card, regardless of which agent's push engaged the shield.
        // Rendered once in ScreenTimeManager.init, so both the host and
        // VibezPushService (NSE) can engage the shield without doing any
        // rendering at engagement time.
        let icon: UIImage? = loadCachedShieldImage()
        Logger.shieldExt.info("Icon: \(icon == nil ? "none" : "shield-claude.png")")

        // No blur — backgroundColor is the tamed-down Claude tint
        // (warm brown).
```

with:

```swift
        // Icon comes from the host-pre-rendered per-agent PNG — Claude
        // pixel critter or Codex logo, picked by the agent that engaged
        // the shield. Rendered once in ScreenTimeManager.init, so both
        // the host and VibezPushService (NSE) can engage the shield
        // without doing any rendering at engagement time.
        let icon: UIImage? = loadCachedShieldImage(for: state.agent)
        Logger.shieldExt.info("Icon: \(icon == nil ? "none" : "loaded") agent=\(state.agent.rawValue)")

        // No blur — backgroundColor is the tamed-down agent tint (warm
        // brown for Claude, cool navy for Codex).
```

- [ ] **Step 4: The loader with the Claude fallback chain**

Replace:

```swift
    private func loadCachedShieldImage() -> UIImage? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return nil }
        let imageURL = containerURL.appendingPathComponent("shield-claude.png")
        return UIImage(contentsOfFile: imageURL.path)
    }
```

with:

```swift
    private func loadCachedShieldImage(for agent: Agent) -> UIImage? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return nil }
        // Only the Claude and Codex cards are pre-rendered. Untagged
        // pings (both/none) — and a missing Codex render (host hasn't
        // relaunched since the update that introduced it) — fall back
        // to the Claude card; text-only shield only if that's gone too.
        if agent == .codex,
           let codex = UIImage(contentsOfFile:
               containerURL.appendingPathComponent("shield-codex.png").path) {
            return codex
        }
        let claudeURL = containerURL.appendingPathComponent("shield-claude.png")
        return UIImage(contentsOfFile: claudeURL.path)
    }
```

- [ ] **Step 5: Update ShieldConfigurationExtension.swift's header comment**

Replace:

```swift
//  Replaces iOS's default "App is Restricted, OK" shield. Reads the
//  latest ShieldState from the App Group and a host-rendered PNG
//  card from the App Group container. If the PNG is present, slots
//  it into ShieldConfiguration.icon for the rich visual. Otherwise
//  falls back to a Vibez-branded text-only shield.
```

with:

```swift
//  Replaces iOS's default "App is Restricted, OK" shield. Reads the
//  latest ShieldState from the App Group and a host-rendered per-agent
//  PNG card (shield-claude.png / shield-codex.png) from the App Group
//  container. If a PNG is present, slots it into
//  ShieldConfiguration.icon for the rich visual. Otherwise falls back
//  to a Vibez-branded text-only shield.
```

- [ ] **Step 6: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
cd /Users/peter/Desktop/Vibez && git add VibezShield/ShieldCard.swift VibezShield/ShieldConfigurationExtension.swift && git commit VibezShield/ShieldCard.swift VibezShield/ShieldConfigurationExtension.swift -m "feat: shield extension picks per-agent PNG + colors (Codex blue, Claude fallback)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: CLAUDE.md refresh

**Files:**
- Modify: `CLAUDE.md` (file-map entries that still describe the all-Claude visual regime)

CLAUDE.md was recently edited (App Store launch notes) — **Read it first** and adapt anchors if the quoted text drifted. Update these five entries (keep the file map's two-column indentation style):

- [ ] **Step 1: `Mascots.swift` entry** — replace the "all Codex theming are deleted" sentence block:

Old (approximately):

```
  Mascots.swift               Vector mascot — Claude (pixel critter). The Codex cloud-bot
                              and all Codex theming are deleted (2026-06-05): the app renders
                              Claude visuals regardless of which agent pings. Codex pushes
                              still flow ("cx" tag, recent-trigger chips, blocking) — only
                              the visual identity is gone.
```

New:

```
  Mascots.swift               Vector mascot — Claude (pixel critter). The Codex cloud-bot
                              VECTOR stays deleted (2026-06-05), but the Codex identity is
                              back on the two blocking surfaces (2026-06-06): BlockedOverlay
                              and the shield card render the codex.imageset logo + blues
                              when a "cx" push engages them. Everywhere else stays Claude.
```

- [ ] **Step 2: `Theme.swift` entry**

Old: `Color palette, pinned to the Claude accent (Theme.make(), no agent param; the Agent enum is gone).`

New: `Color palette, pinned to the Claude accent (Theme.make(), no agent param; the Agent enum is gone). Theme.codexBlue (#8c9ce8) is the one Codex constant — BlockedOverlay's per-message accent.`

- [ ] **Step 3: `ScreenTimeManager.swift` entry** — last sentence:

Old: `Pre-renders the single Claude shield PNG (shield-claude.png) into the App Group at init; prunes the legacy per-agent PNGs.`

New: `Pre-renders the per-agent shield PNGs (shield-claude.png, shield-codex.png) into the App Group at init; prunes legacy renders (shield.png, -both, -none).`

- [ ] **Step 4: `ShieldCardRenderer.swift` entry**

Old: `Host-side SwiftUI→UIImage renderer for the shield card. Writes the Claude PNG into the App Group container so VibezShield (and the NSE) can engage the shield without running ImageRenderer.`

New: `Host-side SwiftUI→UIImage renderer for the shield card. Writes the per-agent PNGs (Claude pixel critter / Codex logo + blue glow) into the App Group container so VibezShield (and the NSE) can engage the shield without running ImageRenderer.`

- [ ] **Step 5: `VibezShield/` directory entry** — the parenthetical about the agent field:

Old: `...loads the host-rendered Claude PNG from the App Group container into ShieldConfiguration.icon (the dict's ``agent`` field is parsed but no longer drives visuals).`

New: `...loads the host-rendered per-agent PNG (shield-claude.png / shield-codex.png) from the App Group container into ShieldConfiguration.icon — the agent field drives icon, Close-button accent, and background wash (Codex = blue/navy, 2026-06-06). Missing Codex PNG / untagged pings fall back to the Claude card.`

- [ ] **Step 6: `BlockedOverlay.swift` entry**

Old: `Full-screen in-app overlay shown when an agent pings; live countdown bound to ScreenTimeManager.pendingTriggers.`

New: `Full-screen in-app overlay shown when an agent pings; live countdown bound to ScreenTimeManager.pendingTriggers. Codex pings render the codex logo + periwinkle accent; everything else stays Claude.`

- [ ] **Step 7: Commit**

```bash
cd /Users/peter/Desktop/Vibez && git add CLAUDE.md && git commit CLAUDE.md -m "docs: CLAUDE.md — Codex identity restored on blocking surfaces

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: End-to-end visual verification (simulator) + device handoff

The OS shield is a no-op in the simulator, but everything else is verifiable there: the pre-rendered PNGs land in the sim's App Group container, and a `simctl push` raises the real in-app overlay.

**Files:** none (verification only)

- [ ] **Step 1: Build for a concrete simulator and install**

```bash
cd /Users/peter/Desktop/Vibez
UDID=$(xcrun simctl list devices available | grep iPhone | grep -m1 -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b
xcodebuild -project Vibez.xcodeproj -scheme Vibez -sdk iphonesimulator26.4 -destination "id=$UDID" -derivedDataPath build build 2>&1 | tail -3
xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/Vibez.app
```

Expected: `** BUILD SUCCEEDED **`, install silent.

- [ ] **Step 2: Launch with seeded state** (paired offline ID, armed toggle, onboarding done, faked Screen Time auth — see the sim-verification playbook in CLAUDE.md/memory)

```bash
xcrun simctl launch "$UDID" vibezlol.Vibez -vibez.vibezId test -vibez.manualBlocking.v1 YES -vibez.onboardingCompleted YES -vibez.debug.fakeScreenTimeAuth YES
```

- [ ] **Step 3: Verify BOTH agent PNGs were pre-rendered into the App Group**

```bash
sleep 3 && find ~/Library/Developer/CoreSimulator/Devices/"$UDID"/data/Containers/Shared/AppGroup -name "shield-*.png" 2>/dev/null
```

Expected: exactly two hits — `shield-claude.png` AND `shield-codex.png`. Then view `shield-codex.png` with the Read tool: it must show the cloud logo over a blue radial glow (not the orange critter).

- [ ] **Step 4: Push a Codex ping and screenshot the overlay**

```bash
cat > /tmp/codex-push.apns <<'EOF'
{
  "Simulator Target Bundle": "vibezlol.Vibez",
  "aps": { "alert": { "title": "Wire up SSE handler", "body": "Need confirmation before I rip out the polling fallback." } },
  "event": "needs-input",
  "shield": "on",
  "session": "sim-verify-codex",
  "agent": "cx"
}
EOF
xcrun simctl push "$UDID" vibezlol.Vibez /tmp/codex-push.apns && sleep 2
xcrun simctl io "$UDID" screenshot /tmp/overlay-codex.png
```

View `/tmp/overlay-codex.png` with the Read tool. Expected: full-screen overlay with the **cloud logo** (not the critter), **periwinkle** "BLOCKING IN PROGRESS" eyebrow + glow, title "Needs you — Wire up SSE handler", countdown running.

- [ ] **Step 5: Clear the Codex overlay, then regression-check the Claude path**

```bash
cat > /tmp/codex-off.apns <<'EOF'
{
  "Simulator Target Bundle": "vibezlol.Vibez",
  "aps": { "alert": { "title": "Wire up SSE handler", "body": "replied" } },
  "event": "replied",
  "shield": "off",
  "session": "sim-verify-codex",
  "agent": "cx"
}
EOF
xcrun simctl push "$UDID" vibezlol.Vibez /tmp/codex-off.apns && sleep 2
cat > /tmp/claude-push.apns <<'EOF'
{
  "Simulator Target Bundle": "vibezlol.Vibez",
  "aps": { "alert": { "title": "Plan plugin distribution", "body": "Bump minor before publishing?" } },
  "event": "needs-input",
  "shield": "on",
  "session": "sim-verify-claude",
  "agent": "cc"
}
EOF
xcrun simctl push "$UDID" vibezlol.Vibez /tmp/claude-push.apns && sleep 2
xcrun simctl io "$UDID" screenshot /tmp/overlay-claude.png
```

View `/tmp/overlay-claude.png`. Expected: the **orange pixel critter** and orange eyebrow — i.e., the Claude path is unchanged. Afterwards send the matching `shield:off` (session `sim-verify-claude`, event `replied`) to clean up.

- [ ] **Step 6: Hand the device check to Peter**

The shield itself can only be verified on hardware. Tell Peter:

1. Build/install to the iPhone from Xcode.
2. Launch Vibez once (pre-renders `shield-codex.png`), toggle ON.
3. From the Mac, have **Codex** finish a task or ask a question (or curl `/notify` with his real Vibez ID, `agent: "cx"`, `shield: "on"`, a session id, and a title).
4. Open a blocked app: the shield should show the **cloud logo on a navy wash with a blue Close button**. A Claude ping should still show the orange critter card.

- [ ] **Step 7: Final clean-tree check (work files only)**

```bash
cd /Users/peter/Desktop/Vibez && git status --short -- Vibez VibezShield CLAUDE.md docs
```

Expected: no output (all plan files committed). Peter's unrelated files (`README.md`s, pbxproj, the standalone HTML) may still show — leave them alone.
