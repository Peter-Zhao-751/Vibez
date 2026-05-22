# Vibez

iOS app that blocks distracting apps (Instagram, TikTok, etc.) on Peter's iPhone whenever Claude Code or Codex finishes a task or asks for input — turning agent idle time into focus time instead of doomscroll time.

## Status

- **Family Controls working on device.** Screen Time API integration via `FamilyControls` + `ManagedSettings` runs end-to-end against the iOS 26.4 SDK on Peter's iPhone. Toggle on → selected apps shielded; toggle off → unblocked. State survives app kill. Peter is enrolled in the paid Apple Developer Program, so the `com.apple.developer.family-controls` entitlement provisions cleanly.
- **Firebase-backed push pipeline working end-to-end.** Mac plugin (Claude Code or Codex) POSTs lifecycle events to a Firebase Cloud Function (`/notify`); the function fans out via FCM to every device registered to the user's Vibez ID. Push lands while Vibez is suspended (the whole reason FCM replaces ntfy). The four-word Vibez ID pairs Mac → phone.
- **Shield Configuration Extension shipping.** `VibezShield` reads `ShieldState` from the App Group `group.vibezlol.Vibez` and renders a custom shield (mascot + push title/body, tinted accent background, "Close" button).
- **ntfy is gone.** WebSocket subscription, ntfy URL UI, push-vibez.py, and the topic-based plugin path are all removed. One push path: plugin → Firebase → FCM → APNs → Vibez.
- **Next phase: Family Controls Distribution Request + App Store review.** Backend already runs on Peter's Firebase project; .p8 lives in Firebase Cloud Messaging, never ships to users.

## File map

```
Vibez/
  VibezApp.swift              SwiftUI @main; AppDelegate calls FirebaseApp.configure(),
                              registers for remote notifications, sets Messaging delegate,
                              forwards APN→FCM, and delivers pushes via NotifyClient.shared.
  ContentView.swift           Home screen: mascot, big toggle, VibezSetupCard, analytics,
                              recent triggers. `setupNeeded` gates on
                              `registrar.vibezId.isEmpty || registrar.state != .registered`.
  VibezSetupCard.swift        Pairing card — user types in the 4-word Vibez ID, calls
                              registrar.setVibezId(...). Replaces the old NotificationSetupCard.
  PushTokenRegistrar.swift    @Observable singleton; FCM MessagingDelegate. Holds the
                              FCM token + user's Vibez ID, persists vibezId in UserDefaults
                              under "vibez.vibezId", calls the registerPushToken Cloud
                              Function on every fresh token OR ID change.
  NotifyClient.swift          Push inbox. WebSocket is gone; class still exists because
                              AppDelegate routes incoming FCM userInfo through
                              acceptPushUserInfo → lastMessage → ContentView.handleIncoming.
                              Owns VibezEvent / VibezShield / VibezAgent / NtfyMessage types.
  ScreenTimeManager.swift     @Observable; auth, persisted FamilyActivitySelection,
                              ManagedSettingsStore shield apply/remove, App Group writer.
  Vibez.entitlements          aps-environment=development + family-controls + application-groups
  GoogleService-Info.plist    Firebase config for bundle vibezlol.Vibez, project vibez-backend.
VibezShield/                  Shield Configuration Extension. Reads ShieldState from the App
                              Group, rasterizes ShieldCard to a UIImage via ImageRenderer,
                              slots it into ShieldConfiguration.icon. Self-contained.
  ShieldConfigurationExtension.swift  ShieldConfigurationDataSource subclass.
  ShieldCard.swift                    Agent enum, ShieldState reader, theme, SwiftUI view.
  VibezShield.entitlements            family-controls + application-groups
Backend/                      Firebase project: vibez-backend.
  firebase.json               Cloud Functions deploy config (codebase=default).
  .firebaserc                 default project = vibez-backend.
  functions/src/index.ts      Two functions:
    - registerPushToken (callable, public): {fcmToken, vibezId, platform} →
      Firestore "tokens" db, "devices" collection, doc id = fcmToken.
    - notify (HTTP, public): {vibezId, title, body, event?, shield?, session?, agent?} →
      queries devices where vibezId == X, fans out via sendEachForMulticast.
ClaudePlugin/                 Claude Code plugin source.
  scripts/setup.sh            Generates the 4-word Vibez ID, embeds the 2016-word wordlist,
                              prints instructions. /vibez:setup invokes this.
  scripts/notify.sh           Hook script. POSTs lifecycle events to /notify with the
                              user's Vibez ID. Handles session-start, stop, pre/post-tool-use
                              (AskUserQuestion), user-prompt-submit. Falls back to setup.sh
                              for first-run ID generation.
  hooks/hooks.json            Registers notify.sh against the Claude Code lifecycle hooks.
CodexPlugin/                  Codex plugin source. Parallel structure to ClaudePlugin.
  scripts/setup.sh            Same Vibez ID generator as the Claude plugin (shared
                              ~/.config/vibez/vibez-id file so one ID covers both agents).
  scripts/notify.sh           Codex-flavored hook script — adds permission-request,
                              ephemeral-session detection, "cx" agent tag.
.claude-plugin/marketplace.json  Plugin marketplace manifest.
Vibez.xcodeproj/              PBXFileSystemSynchronizedRootGroup — drop a .swift into
                              Vibez/ or VibezShield/ and it auto-builds. Entitlements still
                              need CODE_SIGN_ENTITLEMENTS wired manually.
```

## Hard constraints (don't relitigate)

- **No bundle-ID presets.** Apple does not let apps specify "Instagram + TikTok" by name. The user picks via `FamilyActivityPicker`; the returned `ApplicationToken`s are opaque.
- **Real device only for shielding.** `ManagedSettingsStore` shields are no-ops in the simulator. `xcodebuild` against `iphonesimulator26.4` is fine for compile checks but the feature itself only works on hardware.
- **Paid ADP required for development on device, not just for App Store.** Peter is enrolled. App Store distribution additionally needs the Family Controls Distribution Request form (~3-week review) — not yet submitted.
- **APNs auth key must be enabled for BOTH Sandbox and Production at Apple Developer Center.** Single-environment keys cause `messaging/third-party-auth-error` → `BadEnvironmentKeyInToken` on debug builds (sandbox tokens). Always create keys with both environments enabled.

## Conventions

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on — assume MainActor by default; only add `nonisolated` deliberately.
- Bundle ID: `vibezlol.Vibez`. Team: `QW64TZKUAF`. Firebase project: `vibez-backend`.
- App Group: `group.vibezlol.Vibez`. Carries the live shield context (agent, push title/body,
  expiry, dark/light) from host to VibezShield. Key: `"shieldState"`, value is a property-list
  dict — see `Vibez/ScreenTimeManager.swift` (`ShieldState.asDict`) and
  `VibezShield/ShieldCard.swift` (`ShieldState.read`).
- Selection persists in standard `UserDefaults` via `PropertyListEncoder`. Shield store name: `vibez.shield`.
- **Vibez ID format:** `^[a-z]{3,5}(-[a-z]{3,5}){3}$` — 4 hyphen-separated 3-5 letter lowercase words. ~44 bits of entropy. Enforced both client and server-side. Same regex constant in `PushTokenRegistrar.vibezIdPattern` and the backend's `VIBEZ_ID_PATTERN`.
- **Firestore database is named "tokens" (non-default).** Always use `getFirestore("tokens")` on the server; the iOS app never touches Firestore directly — it goes through `registerPushToken`.
- **All Cloud Functions are deployed with `{invoker: "public"}`.** Gen-2 functions are Cloud Run services that default to authenticated; we explicitly open them.

## Worktree workflow

The repo runs Claude Code sessions inside `.claude/worktrees/<name>/` on a `claude/<name>` branch. Real changes belong on `main` in the repo root (`/Users/peter/Desktop/Vibez/`). After committing on the worktree branch, fast-forward merge into `main` so files appear in Peter's working checkout. Don't manually delete worktrees — the harness owns them.

## End-to-end push pipeline (current, working)

```
┌──────────────┐  HTTPS POST  ┌──────────────────────┐    FCM     ┌──────────────┐
│ Mac plugin   │─────────────▶│ Firebase Function    │───────────▶│ User's       │
│ notify.sh    │ /notify      │ /notify              │  via APNs  │ iPhone       │
│              │ {vibezId,    │ (queries Firestore)  │            │ (Vibez)      │
│              │  title,body, │                      │            │              │
│              │  event,...}  │                      │            │              │
└──────────────┘              └──────────────────────┘            └──────────────┘
                                       ▲
                                       │ callable
                                       │ registerPushToken
                              ┌────────┴───────────┐
                              │ PushTokenRegistrar │
                              │ {fcmToken, vibezId}│
                              └────────────────────┘
```

### What happens on first run

1. Mac: user runs `/vibez:setup` (Claude Code) or invokes the `vibez-setup` skill (Codex). `setup.sh` generates a 4-word Vibez ID (`moss-pine-fox-jazz` style), stores it at `~/.config/vibez/vibez-id`, prints it.
2. Phone: user enters that Vibez ID into the home-screen Setup card. `PushTokenRegistrar.setVibezId(...)` validates the format, persists to `UserDefaults["vibez.vibezId"]`, and calls `registerPushToken({fcmToken, vibezId, platform})`.
3. Server: `registerPushToken` writes `{fcmToken, vibezId, createdAt, lastSeen}` to Firestore `tokens` db / `devices` collection, doc id = fcmToken.
4. Mac: every subsequent hook (Stop, AskUserQuestion, etc.) calls `post_vibez` → POST to `/notify` with the Vibez ID and lifecycle payload.
5. Server: `/notify` queries Firestore for all devices where `vibezId == X`, fans out via `getMessaging().sendEachForMulticast()`. APNs delivers to the phone, AppDelegate parses the payload, `NotifyClient.acceptPushUserInfo` publishes `lastMessage`, `ContentView.handleIncoming` raises overlay + shield.

### Roadmap to App Store ship

1. Family Controls Distribution Request (~3-week Apple review). Not yet submitted.
2. App Check on the Cloud Functions (currently `invoker: "public"`; Vibez ID is the only secret).
3. App Store review (~1-week typical).
