# Shield card via ImageRenderer + App Group

## Problem

`VibezShield` (the Shield Configuration Extension) currently returns a `ShieldConfiguration` built from the fixed struct fields — a static title, static subtitle, and a primary button. The result is visually thin: iOS renders its default shield layout with our text/colors slotted in, but nothing about it matches the in-app `BlockedOverlay` (mascot, agent-tinted accent, "BLOCKING IN PROGRESS" eyebrow, ntfy title/body).

The extension also has no access to live agent state — `NtfyMessage` lives in the host process, and the extension runs in its own sandboxed XPC service. Even a static visual refresh wouldn't be able to say *"Claude — Plan plugin distribution"*; the best it could say is *"Vibez is blocking this"*.

## Goal

Bring the shield much closer to `BlockedOverlay`'s look and tone, within `ShieldConfiguration`'s hard API limits. Three changes:

1. Add an App Group (`group.vibezlol.Vibez`) so the host can write the latest ntfy context into shared `UserDefaults`, and the extension can read it.
2. Build a self-contained `ShieldCard` SwiftUI view inside the extension target, mirroring `BlockedOverlay`'s composition (mascot + eyebrow + title + body).
3. At each `configuration(shielding:)` call, rasterize `ShieldCard` to a `UIImage` via `ImageRenderer` and slot it into `ShieldConfiguration.icon`. Surrounding title/subtitle on the iOS shell are left nil so the rendered image dominates; the primary "Close" button stays.

**Non-goals.** A live countdown (`ShieldConfiguration` is cached by iOS; we can't drive a timer). Animations or gradients across the full screen (Apple owns the surrounding layout). Tap-anywhere-to-dismiss. A shared Mascots/Theme module across targets — we hand-copy a simplified static mascot rather than refactoring host code.

## Approach

### App Group

- New entitlement `com.apple.security.application-groups = ["group.vibezlol.Vibez"]` added to both `Vibez/Vibez.entitlements` and `VibezShield/VibezShield.entitlements`.
- Automatic signing (Peter's on paid ADP) will provision the App Group on first build. No App ID configuration in the portal required for development.

### Shared state contract

A single key `"shieldState"` in `UserDefaults(suiteName: "group.vibezlol.Vibez")`, value is a Property List dictionary. Each side parses independently — no shared Swift type, no cross-target file membership.

| Key         | Type    | Meaning                                                  |
|-------------|---------|----------------------------------------------------------|
| `agent`     | String  | `"claude"` / `"codex"` / `"both"` / `"none"`             |
| `title`     | String? | ntfy display title (e.g. `"Needs you — Plan plugin..."`) |
| `body`      | String? | ntfy body                                                |
| `expiresAt` | Double? | `timeIntervalSince1970` of the trigger expiry            |
| `dark`      | Bool    | which palette to render                                  |
| `updatedAt` | Double  | host write timestamp (used by extension to detect stale) |

**Host writer (in `ScreenTimeManager`):**

```swift
private let group = UserDefaults(suiteName: "group.vibezlol.Vibez")

func writeShieldState(_ state: ShieldState?) {
    if let state {
        group?.set(state.asDict, forKey: "shieldState")
    } else {
        group?.removeObject(forKey: "shieldState")
    }
}
```

Called from three sites:

- `applyShields()` — write the current ntfy context if one is active, otherwise write a generic snapshot (`agent: .none`, no title/body).
- The ntfy handler whenever a new `NtfyMessage` arrives while shields are on — overwrite.
- `removeShields()` — clear the key.

`ShieldState` lives in `Vibez/ScreenTimeManager.swift` (or a sibling file in `Vibez/`) — host-side only. The extension defines its own independent `ShieldState` in `VibezShield/ShieldCard.swift`; both sides share the *dictionary keys*, not the Swift type. The host fills `dark` from its current SwiftUI `colorScheme` (or its persisted theme preference) at write time.

**Reader (in extension):**

```swift
struct ShieldState {
    let agent: Agent
    let title: String?
    let body: String?
    let expiresAt: Date?
    let dark: Bool

    static func read() -> ShieldState? {
        let group = UserDefaults(suiteName: "group.vibezlol.Vibez")
        guard let dict = group?.dictionary(forKey: "shieldState"),
              let updatedAt = dict["updatedAt"] as? Double,
              Date().timeIntervalSince1970 - updatedAt < 60 * 60 * 24
        else { return nil }
        // ... parse fields
    }

    static let fallback = ShieldState(
        agent: .both, title: nil, body: nil, expiresAt: nil, dark: true
    )
}
```

Stale-state cutoff: 24 hours. Beyond that, render the generic fallback card.

### ShieldCard SwiftUI view

New file `VibezShield/ShieldCard.swift`, fully self-contained. No imports of host-target code. Three sub-pieces:

1. **`ShieldCard`** — the top-level view. Renders at 360×540 pt portrait.
2. **`StaticMascot`** — a stripped, frozen copy of `MascotForAgent` from `Mascots.swift`. Same SVG paths, but no `TimelineView` and no eye-blink cycling. Roughly 100 lines.
3. **`Agent` enum + `ShieldState` struct** — extension-side copy. `Agent` has the four cases (`claude`, `codex`, `both`, `none`). `ShieldState` includes `accentHex`, computed from `agent`.
4. **Theme constants** — hardcoded:
   ```
   accentClaude = #F2A45C
   accentCodex  = #4A7AFF
   bgDark       = #0C0D12
   bgLight      = #FBF8F4
   fg/fgMute    derived from dark flag
   ```

**Composition (top to bottom):**

```
┌────────────────────────────────┐
│   [radial accent glow @ ~30%]  │
│                                │
│        ◯ mascot (110pt)        │
│                                │
│   BLOCKING IN PROGRESS         │  11pt mono, tracking 2.4, accent
│                                │
│   Needs you — Plan plugin      │  22pt bold, fg
│   distribution                 │
│                                │
│   Should I bump the minor      │  13pt regular, fgMute
│   version before publishing?   │
│                                │
└────────────────────────────────┘
```

Static remaining time is **omitted**. A frozen "14:32" would mislead the user any time they tap a blocked app more than a few seconds after iOS cached the shield image.

For the Codex case: `Image("Codex")` from a new `VibezShield/Assets.xcassets/Codex.imageset/`. The three PNGs are copied verbatim from `Vibez/Assets.xcassets/Codex.imageset/`. ~30 KB.

### ImageRenderer wiring

`ShieldConfigurationExtension.swift` is rewritten (still ~60 lines):

```swift
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
        let state = ShieldState.read() ?? ShieldState.fallback
        return MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: ShieldCard(state: state))
            renderer.scale = UIScreen.main.scale
            renderer.proposedSize = ProposedViewSize(width: 360, height: 540)
            return ShieldConfiguration(
                backgroundBlurStyle: .systemThickMaterial,
                backgroundColor: UIColor(hex: state.dark ? 0x0C0D12 : 0xFBF8F4),
                icon: renderer.uiImage,
                title: nil,
                subtitle: nil,
                primaryButtonLabel: ShieldConfiguration.Label(
                    text: "Close", color: .white
                ),
                primaryButtonBackgroundColor: UIColor(hex: state.accentHex),
                secondaryButtonLabel: nil
            )
        }
    }
}
```

`MainActor.assumeIsolated` is safe because iOS dispatches extension calls onto the main thread by contract for `ShieldConfigurationDataSource`. `ImageRenderer` requires main-actor isolation.

## Files touched

| File                                            | Change                              |
|-------------------------------------------------|-------------------------------------|
| `Vibez/Vibez.entitlements`                      | Add app-groups                      |
| `VibezShield/VibezShield.entitlements`          | Add app-groups                      |
| `Vibez/ScreenTimeManager.swift`                 | `writeShieldState(_:)` + 3 callers  |
| `VibezShield/ShieldConfigurationExtension.swift`| Rewrite — read state, render icon   |
| `VibezShield/ShieldCard.swift`                  | New — SwiftUI card view + state model |
| `VibezShield/Assets.xcassets/Codex.imageset/`   | New — 3 PNGs copied from host       |

No `project.pbxproj` edits required: the synchronized root group picks up the new Swift file and asset catalog automatically. Entitlements files are already referenced.

## Verification

Manual, on device (Family Controls is no-op in simulator):

1. Build and install. Confirm Xcode auto-provisioned the App Group (Signing & Capabilities pane shows the group with a green check on both targets).
2. Toggle Vibez on with no pings in flight. Tap a blocked app. Expect: generic fallback card (`agent: .both`, "Stay focused"-style copy, dark palette).
3. Send a Claude ntfy ping while shields are on. Tap a blocked app. Expect: Claude mascot, orange accent, real ntfy title and body baked into the rendered icon.
4. Repeat with a Codex ping. Expect: Codex avatar, blue accent.
5. Toggle Vibez off. Confirm the shared-defaults key is cleared (the next time shields turn on without a ping, we should see the fallback again, not stale agent state).
