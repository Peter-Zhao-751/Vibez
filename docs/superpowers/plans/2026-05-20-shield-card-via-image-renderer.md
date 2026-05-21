# ShieldCard via ImageRenderer + App Group — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the default-looking shield UI with a BlockedOverlay-styled rendered card that reflects live agent context (Claude/Codex, ntfy title/body).

**Architecture:** App Group `group.vibezlol.Vibez` carries a property-list dictionary from host to extension. The extension reads the dict, builds a self-contained SwiftUI `ShieldCard`, rasterizes it via `ImageRenderer`, and slots the `UIImage` into `ShieldConfiguration.icon`. iOS title/subtitle on the surrounding shell are left empty so the rendered image dominates; one primary `Close` button stays.

**Tech Stack:** SwiftUI, FamilyControls, ManagedSettings, ManagedSettingsUI, App Groups (UserDefaults suite), `ImageRenderer`. iOS 26.4 deployment, Xcode 26.4.

**Testing note:** This project has no XCTest target. "Verify" steps in this plan are manual — build success + log output + on-device behavior. Adding a test target is out of scope. Where pure logic could in principle be unit-tested (dict round-trip, stale-cutoff), I've called it out but the actual check is via debug-print + device run.

**Commits:** Steps include `git commit` blocks per the skill's convention. Skip them if Peter says to batch — Peter will tell you when. Don't commit unprompted.

---

## File map

Will create:
- `VibezShield/ShieldCard.swift` — Agent enum, ShieldState struct, theme constants, StaticMascot, ShieldCard view (~250 lines)
- `VibezShield/Assets.xcassets/` + `Codex.imageset/` (PNGs + Contents.json copied from host)

Will modify:
- `Vibez/Vibez.entitlements` — add `com.apple.security.application-groups`
- `VibezShield/VibezShield.entitlements` — add `com.apple.security.application-groups`
- `Vibez/ScreenTimeManager.swift` — `ShieldState` struct (host-side), `writeShieldState(_:)` helper, callsites in `setArmed`, `addTrigger`, `resolveTrigger`, `clearTriggers`
- `Vibez/ContentView.swift` — call `manager.writeShieldState(ShieldState(from: message))` inside `handleIncoming` `case .on`
- `VibezShield/ShieldConfigurationExtension.swift` — rewrite `makeConfiguration` to render `ShieldCard` via `ImageRenderer`

Will NOT modify:
- `Vibez.xcodeproj/project.pbxproj` — the synchronized root group picks up new files automatically.

---

## Canonical string contract (read this before Tasks 2 and 4)

Both host and extension serialize/parse the same dictionary. Keys and value formats are fixed:

| Dict key      | Type            | Allowed values / format                                 |
|---------------|-----------------|---------------------------------------------------------|
| `agent`       | String          | `"claude"`, `"codex"`, `"both"`, `"none"`               |
| `title`       | String?         | any                                                     |
| `body`        | String?         | any                                                     |
| `expiresAt`   | Double?         | `Date.timeIntervalSince1970`                            |
| `dark`        | Bool            | true/false                                              |
| `updatedAt`   | Double          | `Date().timeIntervalSince1970` at write time            |

App Group ID: `group.vibezlol.Vibez`. UserDefaults key: `"shieldState"`.

Stale-state cutoff (reader rejects beyond this): **24 hours**.

---

## Task 1: Add App Group entitlements

**Goal:** Both targets gain the App Group entitlement; Xcode auto-provisions on next build.

**Files:**
- Modify: `Vibez/Vibez.entitlements`
- Modify: `VibezShield/VibezShield.entitlements`

- [ ] **Step 1: Read current `Vibez.entitlements`**

```bash
cat Vibez/Vibez.entitlements
```

Expected: a plist with `com.apple.developer.family-controls = true` and nothing else (or close to that).

- [ ] **Step 2: Add app-groups to host entitlements**

Edit `Vibez/Vibez.entitlements`, inserting these keys inside the top-level `<dict>`:

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.vibezlol.Vibez</string>
</array>
```

- [ ] **Step 3: Add app-groups to extension entitlements**

Edit `VibezShield/VibezShield.entitlements`, inserting the same keys inside its top-level `<dict>`:

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.vibezlol.Vibez</string>
</array>
```

- [ ] **Step 4: Build for device to confirm provisioning**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DD 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`. If you see a "Provisioning profile doesn't include the com.apple.security.application-groups entitlement" error, open Xcode → select Vibez target → Signing & Capabilities → ensure App Group "group.vibezlol.Vibez" appears with a green check, then repeat for VibezShield target.

- [ ] **Step 5: Confirm entitlements landed in the signed binary**

```bash
codesign -d --entitlements - build/DD/Build/Products/Debug-iphoneos/Vibez.app 2>&1 | grep -A2 application-groups
codesign -d --entitlements - build/DD/Build/Products/Debug-iphoneos/Vibez.app/PlugIns/VibezShield.appex 2>&1 | grep -A2 application-groups
```

Expected: Both commands print `[Key] com.apple.security.application-groups` followed by `[String] group.vibezlol.Vibez`. If empty, the entitlement file wasn't picked up — re-check the edit.

- [ ] **Step 6: Commit**

```bash
git add Vibez/Vibez.entitlements VibezShield/VibezShield.entitlements
git commit -m "Add App Group entitlement to host and shield extension"
```

---

## Task 2: Host-side ShieldState struct and writer

**Goal:** `ScreenTimeManager` gains a `ShieldState` struct and a `writeShieldState(_:)` helper that targets the shared App Group defaults.

**Files:**
- Modify: `Vibez/ScreenTimeManager.swift`

- [ ] **Step 1: Read the top of `ScreenTimeManager.swift` to confirm structure**

```bash
sed -n '1,90p' Vibez/ScreenTimeManager.swift
```

Confirm: file already declares `@Observable final class ScreenTimeManager`, has `private let store = ManagedSettingsStore(named: .vibez)` and `private let defaults = UserDefaults.standard` around line 79-80.

- [ ] **Step 2: Add `ShieldState` struct + shared-defaults handle**

Insert this BEFORE the `@Observable final class ScreenTimeManager` declaration (so it's file-scope, near the existing `private let shieldLog`):

```swift
struct ShieldState {
    enum Agent: String {
        case claude, codex, both, none
    }

    var agent: Agent
    var title: String?
    var body: String?
    var expiresAt: Date?
    var dark: Bool

    var asDict: [String: Any] {
        var d: [String: Any] = [
            "agent": agent.rawValue,
            "dark": dark,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let title { d["title"] = title }
        if let body  { d["body"]  = body }
        if let expiresAt { d["expiresAt"] = expiresAt.timeIntervalSince1970 }
        return d
    }
}
```

Then inside the class body, right after `private let defaults = UserDefaults.standard` (around line 80), add:

```swift
private let sharedDefaults = UserDefaults(suiteName: "group.vibezlol.Vibez")
```

- [ ] **Step 3: Add the writer helper**

Inside the class body, after the existing `private func persistArmed()` block (around line 315-317), add:

```swift
private func writeShieldState(_ state: ShieldState?) {
    guard let sharedDefaults else {
        shieldLog.error("App Group defaults unavailable — shield state not written")
        return
    }
    if let state {
        sharedDefaults.set(state.asDict, forKey: "shieldState")
    } else {
        sharedDefaults.removeObject(forKey: "shieldState")
    }
}
```

- [ ] **Step 4: Build to confirm it compiles**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Vibez/ScreenTimeManager.swift
git commit -m "ScreenTimeManager: add ShieldState struct and shared-defaults writer"
```

---

## Task 3: Host-side writer callsites

**Goal:** The host writes a fresh `ShieldState` (or clears) at every shield-lifecycle event.

**Files:**
- Modify: `Vibez/ScreenTimeManager.swift` (3 callsites: `applyShield`, `clearShield`)
- Modify: `Vibez/ContentView.swift` (1 callsite: `handleIncoming` `case .on`)

- [ ] **Step 1: Find `applyShield` and `clearShield`**

```bash
grep -n "private func applyShield\|private func clearShield" Vibez/ScreenTimeManager.swift
```

Expected: hits around line 269 (`applyShield`) and line 286 (`clearShield`).

- [ ] **Step 2: Write a fallback snapshot from `applyShield`**

In `ScreenTimeManager.applyShield()`, at the end of the function (just before the closing brace, after `store.shield.webDomains = ...`), add:

```swift
// Refresh shared state so the shield extension renders the latest
// context. ContentView.handleIncoming may overwrite this immediately
// with a richer per-message snapshot; here we just publish a generic
// "shields are on" baseline so a freshly-toggled-on Vibez (no ping
// yet) shows our card instead of the iOS default.
writeShieldState(ShieldState(
    agent: .none,
    title: nil,
    body: nil,
    expiresAt: nil,
    dark: true
))
```

- [ ] **Step 3: Clear shared state from `clearShield`**

In `ScreenTimeManager.clearShield(reason:)`, at the end of the function, add:

```swift
writeShieldState(nil)
```

- [ ] **Step 4: Find `handleIncoming` `case .on` in ContentView**

```bash
grep -n "case .on:" Vibez/ContentView.swift
```

Expected: hit around line 314.

- [ ] **Step 5: Confirm the message agent type, then add `publishShieldContext(from:)` to ScreenTimeManager**

First identify how `NtfyMessage.agent` and `NtfyMessage.displayTitle` are typed:

```bash
grep -nE "var agent|var displayTitle|enum VibezAgent" Vibez/NotifyClient.swift | head -10
```

Use what you find to fill the switch below. Expect `agent: VibezAgent?` where `VibezAgent` has cases `claude` and `codex`, and a computed `displayTitle: String` on `NtfyMessage`. If reality differs, adapt the cases / accessor (and the build error from Step 7 will tell you).

Then, inside `ScreenTimeManager`, after the `writeShieldState` helper added in Task 2, add:

```swift
/// Bridges a fresh NtfyMessage into a ShieldState and writes it to
/// the App Group. Called from ContentView.handleIncoming so the
/// extension can read the latest agent/title/body next time iOS
/// asks for a shield configuration.
func publishShieldContext(from message: NtfyMessage) {
    let agent: ShieldState.Agent
    if let messageAgent = message.agent {
        switch messageAgent {
        case .claude: agent = .claude
        case .codex:  agent = .codex
        }
    } else {
        // Untagged ntfy ping — no agent context. Use the generic
        // "both" tint so we don't bias the visual toward one agent.
        agent = .both
    }

    var expiry: Date?
    if let sid = message.sessionId,
       let trigger = pendingTriggers[sid] {
        expiry = trigger.expiresAt
    }

    writeShieldState(ShieldState(
        agent: agent,
        title: message.displayTitle,
        body: message.body.isEmpty ? nil : message.body,
        expiresAt: expiry,
        dark: true
    ))
}
```

Note: this method must be on the main actor; the class is `@Observable` and the project defaults to `@MainActor`, so the default is fine — don't add `nonisolated`. `pendingTriggers` is `private` on the class but readable from inside it.

- [ ] **Step 6: Add a writer call from `handleIncoming`**

Inside `case .on:` in `handleIncoming` (in `ContentView.swift`), immediately after `manager.addTrigger(sessionId:durationSeconds:)` (around line 331-332), add:

```swift
manager.publishShieldContext(from: message)
```

- [ ] **Step 7: Verify `pendingTriggers` is reachable**

```bash
grep -nE "pendingTriggers|var.*pendingTriggers" Vibez/ScreenTimeManager.swift | head -5
```

Expected: a `private(set) var pendingTriggers: [String: PendingTrigger]` or similar. If `private` (not `private(set)`), it's still readable from inside the class, so the helper works without further changes.

- [ ] **Step 8: Build**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. If you hit "Value of type 'VibezAgent?' has no member 'claude'" or similar, the `message.agent` enum's case names differ — `grep -n "enum.*Agent\|VibezAgent" Vibez/NotifyClient.swift` to find them and adjust the switch.

- [ ] **Step 9: Commit**

```bash
git add Vibez/ScreenTimeManager.swift Vibez/ContentView.swift
git commit -m "Wire host writers: applyShield/clearShield/handleIncoming publish ShieldState"
```

---

## Task 4: Extension-side reader scaffolding (no view yet)

**Goal:** `VibezShield/ShieldCard.swift` exists with `Agent` enum and `ShieldState.read()` parser. `ShieldConfigurationExtension.swift` reads state and logs it. Still returns the existing static configuration — visual change comes in Task 8.

**Files:**
- Create: `VibezShield/ShieldCard.swift` (initial slice — types only, no view)
- Modify: `VibezShield/ShieldConfigurationExtension.swift` (log state + keep old return)

- [ ] **Step 1: Create `VibezShield/ShieldCard.swift` with types only**

Write this file:

```swift
//
//  ShieldCard.swift
//  VibezShield
//
//  Self-contained model + SwiftUI view rendered to UIImage and slotted
//  into ShieldConfiguration.icon. Mirrors BlockedOverlay's aesthetic
//  within the constraints of the Shield Configuration API: no
//  animations, no live countdown, no interactivity. The image is
//  rasterized once per `configuration(shielding:)` call.
//

import SwiftUI
import os

extension Logger {
    static let shieldExt = Logger(subsystem: "vibezlol.Vibez.Shield", category: "Extension")
}

enum Agent: String {
    case claude, codex, both, none
}

struct ShieldState {
    let agent: Agent
    let title: String?
    let body: String?
    let expiresAt: Date?
    let dark: Bool

    /// Reads the latest snapshot from the shared App Group defaults.
    /// Returns nil when state is missing or older than the 24h
    /// cutoff — callers fall back to `ShieldState.fallback`.
    static func read() -> ShieldState? {
        let group = UserDefaults(suiteName: "group.vibezlol.Vibez")
        guard let dict = group?.dictionary(forKey: "shieldState"),
              let agentRaw = dict["agent"] as? String,
              let agent = Agent(rawValue: agentRaw),
              let updatedAt = dict["updatedAt"] as? Double
        else {
            Logger.shieldExt.info("ShieldState: missing or malformed; using fallback")
            return nil
        }

        let age = Date().timeIntervalSince1970 - updatedAt
        guard age < 60 * 60 * 24 else {
            Logger.shieldExt.info("ShieldState: stale (\(Int(age))s); using fallback")
            return nil
        }

        return ShieldState(
            agent: agent,
            title: dict["title"] as? String,
            body: dict["body"] as? String,
            expiresAt: (dict["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
            dark: (dict["dark"] as? Bool) ?? true
        )
    }

    static let fallback = ShieldState(
        agent: .none,
        title: nil,
        body: nil,
        expiresAt: nil,
        dark: true
    )

    /// Accent color used by ShieldCard and ShieldConfiguration's
    /// primary button. Claude orange / Codex blue / Vibez orange for
    /// the generic case.
    var accentUIColor: UIColor {
        switch agent {
        case .claude, .both, .none:
            return UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)
        case .codex:
            return UIColor(red: 0.29, green: 0.48, blue: 1.00, alpha: 1.0)
        }
    }
}
```

- [ ] **Step 2: Modify `ShieldConfigurationExtension.swift` to log state**

Open `VibezShield/ShieldConfigurationExtension.swift`. Replace the entire `makeConfiguration(name:)` function with:

```swift
private func makeConfiguration(name: String?) -> ShieldConfiguration {
    let state = ShieldState.read() ?? .fallback
    Logger.shieldExt.info("Shield invoked: agent=\(state.agent.rawValue) title=\(state.title ?? "nil")")

    let displayName = name ?? "this app"
    return ShieldConfiguration(
        backgroundBlurStyle: .systemThickMaterial,
        backgroundColor: nil,
        icon: nil,
        title: ShieldConfiguration.Label(
            text: "BLOCKING IN PROGRESS",
            color: state.accentUIColor
        ),
        subtitle: ShieldConfiguration.Label(
            text: "Vibez is keeping you off \(displayName).\n\nOpen Vibez to check what your agent needs.",
            color: .label
        ),
        primaryButtonLabel: ShieldConfiguration.Label(
            text: "Close",
            color: .white
        ),
        primaryButtonBackgroundColor: state.accentUIColor,
        secondaryButtonLabel: nil
    )
}
```

Also delete the old `private let vibezAccent = UIColor(...)` line — `state.accentUIColor` replaces it.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify on device (manual)**

Install on iPhone, toggle Vibez on, send a Claude ntfy ping, tap a blocked app. In Console.app (with the iPhone connected), filter by `subsystem:vibezlol.Vibez.Shield`. Expected log line: `Shield invoked: agent=claude title=Needs you — …` (or similar). If you see `agent=none` even after a ping, the writer in Task 3 isn't firing — re-check `handleIncoming` `case .on`. If you see `missing or malformed`, the App Group isn't shared — re-check Task 1's verification step.

- [ ] **Step 5: Commit**

```bash
git add VibezShield/ShieldCard.swift VibezShield/ShieldConfigurationExtension.swift
git commit -m "VibezShield: read shared state, log per-shield context"
```

---

## Task 5: StaticMascot view in ShieldCard.swift

**Goal:** Append a stripped, non-animated mascot view to `ShieldCard.swift` — same SVG paths as `Mascots.swift` but frozen at the default-frame pose.

**Files:**
- Modify: `VibezShield/ShieldCard.swift` (append)

- [ ] **Step 1: Inspect the source mascot**

```bash
sed -n '62,150p' Vibez/Mascots.swift
```

Note the `MascotForAgent` struct, the `agent`, `listening`, and `size` params, and the inner viewBox dimensions. The Claude mascot is a `ClaudeMascot` subview drawn with `Path` (you'll see the paths inside).

- [ ] **Step 2: Append `StaticMascot` to `ShieldCard.swift`**

Append at the end of the file:

```swift
import UIKit

/// Frozen render of the Claude/Codex/Both mascot. No TimelineView,
/// no breathing, no eye blinks — the shield card is a still image.
/// Codex case uses the bundled `Codex` asset (added to
/// VibezShield/Assets.xcassets in Task 7).
struct StaticMascot: View {
    let agent: Agent
    var size: CGFloat = 110

    var body: some View {
        switch agent {
        case .codex:
            Image("Codex")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        case .claude, .both, .none:
            ClaudePixelMascot(size: size)
        }
    }
}

/// Static copy of the Claude pixel critter (mid-blink, mid-breath
/// pose). Path data copied verbatim from Vibez/Mascots.swift around
/// the existing `ClaudeMascot` body, with TimelineView stripped.
struct ClaudePixelMascot: View {
    let size: CGFloat
    // viewBox dimensions match the source SVG.
    private let viewBoxWidth: CGFloat = 64
    private let viewBoxHeight: CGFloat = 64

    var body: some View {
        Canvas { context, canvasSize in
            let unit = canvasSize.width / viewBoxWidth
            // Body (rounded square, accent fill).
            let bodyRect = CGRect(
                x: 8 * unit, y: 14 * unit,
                width: 48 * unit, height: 44 * unit
            )
            context.fill(
                Path(roundedRect: bodyRect, cornerRadius: 10 * unit),
                with: .color(Color(red: 0.95, green: 0.45, blue: 0.20))
            )
            // Eyes (two black ovals at neutral position).
            let eyeY = 30 * unit
            for ex in [20.0, 44.0] {
                let eye = CGRect(
                    x: (ex - 4) * unit, y: eyeY - 4 * unit,
                    width: 8 * unit, height: 8 * unit
                )
                context.fill(
                    Path(ellipseIn: eye),
                    with: .color(.black)
                )
            }
            // Mouth (small smile).
            var mouth = Path()
            mouth.move(to: CGPoint(x: 26 * unit, y: 44 * unit))
            mouth.addQuadCurve(
                to: CGPoint(x: 38 * unit, y: 44 * unit),
                control: CGPoint(x: 32 * unit, y: 50 * unit)
            )
            context.stroke(
                mouth,
                with: .color(.black),
                lineWidth: 2 * unit
            )
        }
        .frame(width: size, height: size)
    }
}
```

This is a deliberately simplified pose, not a pixel-perfect copy of `ClaudeMascot`. The full SVG in `Mascots.swift` has more detail (antenna, feet); if Peter wants visual parity, copy the full path data from `Mascots.swift` here. Start simple, iterate after seeing it on device.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add VibezShield/ShieldCard.swift
git commit -m "VibezShield: add StaticMascot (Claude pixel critter, Codex asset)"
```

---

## Task 6: ShieldCard view + theme constants

**Goal:** The hero SwiftUI view that composes mascot + eyebrow + title + body into a 360×540 portrait card.

**Files:**
- Modify: `VibezShield/ShieldCard.swift` (append)

- [ ] **Step 1: Append theme + `ShieldCard` to `ShieldCard.swift`**

Append at the end:

```swift
private enum ShieldTheme {
    static let bgDark    = Color(red: 0.047, green: 0.051, blue: 0.071)  // #0C0D12
    static let bgLight   = Color(red: 0.984, green: 0.973, blue: 0.957)  // #FBF8F4
    static let fgOnDark  = Color.white
    static let fgOnLight = Color.black
    static let fgMuteOnDark  = Color.white.opacity(0.65)
    static let fgMuteOnLight = Color.black.opacity(0.55)

    static func accent(_ agent: Agent) -> Color {
        switch agent {
        case .codex: return Color(red: 0.29, green: 0.48, blue: 1.00)
        default:     return Color(red: 0.95, green: 0.45, blue: 0.20)
        }
    }
}

struct ShieldCard: View {
    let state: ShieldState

    private var bg: Color    { state.dark ? ShieldTheme.bgDark : ShieldTheme.bgLight }
    private var fg: Color    { state.dark ? ShieldTheme.fgOnDark : ShieldTheme.fgOnLight }
    private var fgMute: Color {
        state.dark ? ShieldTheme.fgMuteOnDark : ShieldTheme.fgMuteOnLight
    }
    private var accent: Color { ShieldTheme.accent(state.agent) }

    private var titleText: String {
        state.title ?? "Stay focused"
    }

    private var bodyText: String {
        state.body ?? "Tap Close to return to your phone. Your agent is waiting."
    }

    var body: some View {
        ZStack(alignment: .top) {
            bg
                .overlay(
                    RadialGradient(
                        colors: [accent.opacity(state.dark ? 0.28 : 0.20), .clear],
                        center: UnitPoint(x: 0.5, y: 0.30),
                        startRadius: 0,
                        endRadius: 320
                    )
                )

            VStack(spacing: 0) {
                Spacer().frame(height: 56)

                StaticMascot(agent: state.agent, size: 110)
                    .padding(.bottom, 18)

                Text("BLOCKING IN PROGRESS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(accent)
                    .padding(.bottom, 10)

                Text(titleText)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(fg)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)

                Text(bodyText)
                    .font(.system(size: 13))
                    .foregroundStyle(fgMute)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .padding(.horizontal, 32)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 360, height: 540)
    }
}

#Preview("Claude · needs input") {
    ShieldCard(state: ShieldState(
        agent: .claude,
        title: "Needs you — Plan plugin distribution",
        body: "Should I bump the minor version before publishing, or roll the patch and ship a follow-up?",
        expiresAt: nil,
        dark: true
    ))
}

#Preview("Codex · light") {
    ShieldCard(state: ShieldState(
        agent: .codex,
        title: "Wire up SSE handler",
        body: "Need confirmation before I rip out the polling fallback.",
        expiresAt: nil,
        dark: false
    ))
}

#Preview("Fallback") {
    ShieldCard(state: .fallback)
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Open Xcode and preview the card**

Open `VibezShield/ShieldCard.swift` in Xcode, click any of the three `#Preview` blocks. Confirm the layout looks like the design mockup (mascot, eyebrow, title, body, no countdown). If anything looks off (wrong colors, text overflow), tune values inline and re-preview.

- [ ] **Step 4: Commit**

```bash
git add VibezShield/ShieldCard.swift
git commit -m "VibezShield: add ShieldCard view + theme constants + previews"
```

---

## Task 7: Codex asset catalog in extension

**Goal:** The `Codex` image used by `StaticMascot` exists in `VibezShield/Assets.xcassets/`. Without this, the Codex case crashes on render.

**Files:**
- Create: `VibezShield/Assets.xcassets/Contents.json`
- Create: `VibezShield/Assets.xcassets/Codex.imageset/Contents.json`
- Create: `VibezShield/Assets.xcassets/Codex.imageset/*.png` (3 PNGs)

- [ ] **Step 1: Inspect the source imageset**

```bash
ls Vibez/Assets.xcassets/Codex.imageset/
cat Vibez/Assets.xcassets/Codex.imageset/Contents.json
```

Expected: 3 PNGs (e.g. `Codex.png`, `Codex@2x.png`, `Codex@3x.png`) plus a `Contents.json`.

- [ ] **Step 2: Create the asset catalog directory and copy files**

```bash
mkdir -p VibezShield/Assets.xcassets/Codex.imageset
cp Vibez/Assets.xcassets/Codex.imageset/* VibezShield/Assets.xcassets/Codex.imageset/
```

- [ ] **Step 3: Create the top-level `Contents.json` for the catalog**

Write `VibezShield/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. The synchronized root group should pick up the new asset catalog automatically.

- [ ] **Step 5: Verify the asset is in the built appex**

```bash
ls build/DD/Build/Products/Debug-iphonesimulator/Vibez.app/PlugIns/VibezShield.appex/ | grep -E "Codex|Assets"
```

Expected output should mention compiled assets (e.g. `Assets.car` exists or an Asset Catalog blob is present). If neither appears, the asset catalog wasn't picked up — check the `Contents.json` at the catalog root.

- [ ] **Step 6: Commit**

```bash
git add VibezShield/Assets.xcassets/
git commit -m "VibezShield: bundle Codex avatar asset for shield extension"
```

---

## Task 8: ImageRenderer wiring in the extension

**Goal:** Replace the `ShieldConfiguration` text-only return with one that renders `ShieldCard` to a `UIImage` and slots it into `icon`. iOS title/subtitle are nil so the rendered image dominates.

**Files:**
- Modify: `VibezShield/ShieldConfigurationExtension.swift`

- [ ] **Step 1: Read current file**

```bash
cat VibezShield/ShieldConfigurationExtension.swift
```

Confirm it still has `makeConfiguration(name:)` from Task 4.

- [ ] **Step 2: Replace the file**

Overwrite `VibezShield/ShieldConfigurationExtension.swift` with:

```swift
//
//  ShieldConfigurationExtension.swift
//  VibezShield
//
//  Replaces iOS's default "App is Restricted, OK" shield. Reads the
//  latest ShieldState from the App Group, rasterizes a SwiftUI
//  ShieldCard to a UIImage via ImageRenderer, and returns a
//  ShieldConfiguration whose icon slot carries the whole visual.
//
//  iOS's surrounding title/subtitle text are intentionally nil so
//  the rendered card is the focus; the primary "Close" button
//  remains to give the user a way out.
//

import ManagedSettings
import ManagedSettingsUI
import SwiftUI
import UIKit

nonisolated final class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration()
    }

    private func makeConfiguration() -> ShieldConfiguration {
        let state = ShieldState.read() ?? .fallback
        Logger.shieldExt.info("Shield: agent=\(state.agent.rawValue) title=\(state.title ?? "nil")")

        return MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: ShieldCard(state: state))
            renderer.scale = UIScreen.main.scale
            renderer.proposedSize = ProposedViewSize(width: 360, height: 540)

            return ShieldConfiguration(
                backgroundBlurStyle: .systemThickMaterial,
                backgroundColor: state.dark
                    ? UIColor(red: 0.047, green: 0.051, blue: 0.071, alpha: 1)
                    : UIColor(red: 0.984, green: 0.973, blue: 0.957, alpha: 1),
                icon: renderer.uiImage,
                title: nil,
                subtitle: nil,
                primaryButtonLabel: ShieldConfiguration.Label(
                    text: "Close", color: .white
                ),
                primaryButtonBackgroundColor: state.accentUIColor,
                secondaryButtonLabel: nil
            )
        }
    }
}
```

- [ ] **Step 3: Build for simulator**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

If you hit `'assumeIsolated' is unavailable` or similar: this API is iOS 17+, and our deployment is 26.4 so it should work. If for some reason it errors, fall back to a `DispatchQueue.main.sync` wrapper:

```swift
return DispatchQueue.main.sync {
    let renderer = ImageRenderer(content: ShieldCard(state: state))
    // ... as above
}
```

`DispatchQueue.main.sync` is safe because iOS calls extension config methods off-main; if iOS ever changed that, the assumeIsolated path would crash earlier with a clearer message, which is preferable.

- [ ] **Step 4: Build for device**

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DD 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **` plus a `CodeSign` line for `VibezShield.appex`.

- [ ] **Step 5: Commit**

```bash
git add VibezShield/ShieldConfigurationExtension.swift
git commit -m "VibezShield: render ShieldCard as ShieldConfiguration.icon"
```

---

## Task 9: Update CLAUDE.md

**Goal:** Reflect that VibezShield + App Group exist so future sessions don't have to rediscover them.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Read the current file map and conventions**

```bash
sed -n '11,40p' CLAUDE.md
```

- [ ] **Step 2: Update the file map**

Replace the existing file map (lines 11-23) with:

```
Vibez/
  VibezApp.swift            SwiftUI @main entry point
  ContentView.swift         Minimal UI: auth status, picker button, on/off toggle,
                            ntfy ingest. Publishes ShieldState on each incoming ping.
  ScreenTimeManager.swift   @Observable backend; owns auth, persisted FamilyActivitySelection,
                            ManagedSettingsStore shield apply/remove, and the App Group
                            writer that hands the latest agent/title/body off to VibezShield.
  Vibez.entitlements        com.apple.developer.family-controls + application-groups
VibezShield/                Shield Configuration Extension. Reads ShieldState from the App
                            Group, rasterizes ShieldCard to a UIImage via ImageRenderer,
                            slots it into ShieldConfiguration.icon. Self-contained — no
                            imports of host-target code.
  ShieldConfigurationExtension.swift  ShieldConfigurationDataSource subclass.
  ShieldCard.swift                    Agent enum, ShieldState reader, theme, SwiftUI view.
  Assets.xcassets/                    Codex avatar copied from host.
  Info.plist                          NSExtensionPointIdentifier = com.apple.ManagedSettingsUI...
  VibezShield.entitlements            family-controls + application-groups
Vibez.xcodeproj/            Uses PBXFileSystemSynchronizedRootGroup — drop a .swift into Vibez/
                            or VibezShield/ and it auto-builds, no project file edits needed.
                            Entitlements still need CODE_SIGN_ENTITLEMENTS wired manually.
```

- [ ] **Step 3: Add an App Group line to Conventions**

In the Conventions section (around line 32-37), after the Bundle ID line, insert:

```
- App Group: `group.vibezlol.Vibez`. Carries the live shield context (agent, ntfy title/body,
  expiry, dark/light) from host to VibezShield. Key: `"shieldState"`, value is a property-list
  dict — see `Vibez/ScreenTimeManager.swift` (`ShieldState.asDict`) and
  `VibezShield/ShieldCard.swift` (`ShieldState.read`).
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "CLAUDE.md: document VibezShield, App Group, ShieldCard wiring"
```

---

## Task 10: Manual device verification

**Goal:** End-to-end sanity check on the actual iPhone — the only place this can be properly validated.

**Files:** none (manual)

- [ ] **Step 1: Install on device from Xcode**

In Xcode, pick the iPhone destination and Cmd-R. Wait for the app to launch.

- [ ] **Step 2: Toggle Vibez on with no pings**

Flip the in-app toggle on. Tap a shielded app from the home screen.

Expected: Vibez's card appears. Mascot is the Claude pixel critter (the `.both`/`.none` fallback uses Claude orange). Eyebrow reads "BLOCKING IN PROGRESS" in orange. Title: "Stay focused". Body: the fallback copy. No countdown. "Close" button in orange.

If you see the old grey "App is Restricted / OK" shield: the appex didn't ship — check `xcodebuild` output for a `CodeSign` line on `VibezShield.appex`. Also confirm the Info.plist `NSExtensionPointIdentifier` ends in `ManagedSettingsUI.shield-configuration-service` (not `ManagedSettings.shield-configuration-service`).

- [ ] **Step 3: Send a Claude ntfy ping while shields are on**

From the Mac, `curl -d "Plan plugin distribution" https://ntfy.sh/<your-topic>` (or use the agent's actual notify hook). Wait for the iPhone notification.

Tap a shielded app.

Expected: Claude mascot, orange accent, title = "Needs you — Plan plugin distribution" (or whatever you sent), body = the ntfy body. Console.app filtered by `subsystem:vibezlol.Vibez.Shield` should show `Shield: agent=claude title=Needs you — Plan plugin distribution`.

- [ ] **Step 4: Send a Codex ntfy ping**

Same drill but with a message tagged for Codex.

Expected: Codex avatar (the imageset from Task 7), blue accent, real title/body.

If the Codex image is missing or all-grey: the imageset wasn't bundled. Check `ls build/DD/Build/Products/Debug-iphoneos/Vibez.app/PlugIns/VibezShield.appex/` — there should be an `Assets.car`. If not, Task 7's catalog wasn't picked up.

- [ ] **Step 5: Toggle Vibez off**

Flip the toggle off. Tap a previously-shielded app — it should open normally (no shield at all).

Toggle on again — the fallback card from Step 2 should reappear (no agent context until the next ping).

- [ ] **Step 6: Stress test — kill and relaunch host**

Force-quit Vibez from the app switcher (with shields still on). Tap a blocked app. Expected: shield still shows with the last-written ShieldState (the dict in App Group persists across host kills).

- [ ] **Step 7: No commit**

Manual verification — nothing to commit. If you tuned anything inline (colors, spacing, fallback copy), commit those separately:

```bash
git status
git diff
# … if there are tweaks worth keeping:
git add -p
git commit -m "VibezShield: post-device-test polish"
```
