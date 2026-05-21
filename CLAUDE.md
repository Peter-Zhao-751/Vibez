# Vibez

iOS app that blocks distracting apps (Instagram, TikTok, etc.) on Peter's iPhone whenever Claude Code or Codex finishes a task or asks for input — turning agent idle time into focus time instead of doomscroll time.

## Status

- **Family Controls working on device.** Screen Time API integration via `FamilyControls` + `ManagedSettings` runs end-to-end against the iOS 26.4 SDK on Peter's iPhone. Toggle on → selected apps shielded; toggle off → unblocked. State survives app kill. Peter is enrolled in the paid Apple Developer Program, so the `com.apple.developer.family-controls` entitlement provisions cleanly.
- **Next phase (active): Claude ↔ phone bridge.** A way for `claude` / `codex` running on Peter's Mac to flip the toggle on his iPhone when the agent stops or asks a question. Approach not yet decided.

## File map

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

## Hard constraints (don't relitigate)

- **No bundle-ID presets.** Apple does not let apps specify "Instagram + TikTok" by name. The user picks via `FamilyActivityPicker`; the returned `ApplicationToken`s are opaque. The only model is "user selects once → app toggles their selection on/off."
- **Real device only.** `ManagedSettingsStore` shields are no-ops in the simulator. `xcodebuild` against `iphonesimulator26.4` is fine for compile checks but the feature itself only works on hardware.
- **Paid ADP required for development on device, not just for App Store.** Peter is enrolled. App Store distribution additionally needs the Family Controls Distribution Request form (~3-week review) — not yet submitted.
- **iOS 16+ for the frameworks.** Project deploys 26.4 so all APIs are available.

## Conventions

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on — assume MainActor by default; only add `nonisolated` deliberately.
- Bundle ID: `vibezlol.Vibez`. Team: `QW64TZKUAF` (paid Apple Developer Program).
- App Group: `group.vibezlol.Vibez`. Carries the live shield context (agent, ntfy title/body,
  expiry, dark/light) from host to VibezShield. Key: `"shieldState"`, value is a property-list
  dict — see `Vibez/ScreenTimeManager.swift` (`ShieldState.asDict`) and
  `VibezShield/ShieldCard.swift` (`ShieldState.read`).
- Selection persists in standard `UserDefaults` via `PropertyListEncoder`. If we add a Shield Action / Device Activity Monitor extension later, we'll need an App Group for shared defaults.
- Shield store name: `vibez.shield` (so other Family-Controls apps on the device don't clobber our restrictions).

## Worktree workflow

The repo runs Claude Code sessions inside `.claude/worktrees/<name>/` on a `claude/<name>` branch. Real changes belong on `main` in the repo root (`/Users/peter/Desktop/Vibez/`). After committing on the worktree branch, fast-forward merge into `main` so files appear in Peter's working checkout. Don't manually delete worktrees — the harness owns them.

## Open question for next session

How should the Mac-side agent trigger the iPhone toggle? Two candidates, both undecided:

1. **Vibez runs a local listener** (HTTP on LAN, or a `vibez://` URL via push). Claude Code hook posts to it on Stop/Notification.
2. **Apple Shortcuts bridge.** Mac-side hook calls `shortcuts run "Block Apps"`, an iCloud-synced shortcut runs on the iPhone and either calls Vibez via its URL scheme or uses Shortcuts' built-in "Set App Limit" action directly (which would let us skip Vibez entirely for the MVP).

Pick before writing code. Option 2 lets Peter prototype without paying for ADP first.
