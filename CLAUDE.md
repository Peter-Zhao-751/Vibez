# Vibez

iOS app that blocks distracting apps (Instagram, TikTok, etc.) on Peter's iPhone whenever Claude Code or Codex finishes a task or asks for input — turning agent idle time into focus time instead of doomscroll time.

## Status

- **Family Controls working on device.** Screen Time API integration via `FamilyControls` + `ManagedSettings` runs end-to-end against the iOS 26.4 SDK on Peter's iPhone. Toggle on → selected apps shielded; toggle off → unblocked. State survives app kill. Peter is enrolled in the paid Apple Developer Program, so the `com.apple.developer.family-controls` entitlement provisions cleanly.
- **Firebase-backed push pipeline working end-to-end.** Mac plugin (Claude Code or Codex) POSTs lifecycle events to a Firebase Cloud Function (`/notify`); the function fans out via FCM to every device registered to the user's Vibez ID. Push lands while Vibez is suspended (the whole reason FCM replaces ntfy). The four-word Vibez ID pairs Mac → phone.
- **Shield Configuration Extension shipping.** `VibezShield` reads `ShieldState` from the App Group `group.vibezlol.Vibez` and shows a custom shield (host-rendered mascot PNG + push title/body, tinted accent background, "Close" button). The PNG is rendered on the host (`ShieldCardRenderer`), not in the extension.
- **ntfy is gone.** WebSocket subscription, ntfy URL UI, push-vibez.py, and the topic-based plugin path are all removed. One push path: plugin → Firebase → FCM → APNs → Vibez.
- **Next phase: Family Controls Distribution Request + App Store review.** Backend already runs on Peter's Firebase project; .p8 lives in Firebase Cloud Messaging, never ships to users.

## File map

```
Vibez/                        Main iOS app target.
  VibezApp.swift              SwiftUI @main; AppDelegate calls FirebaseApp.configure(),
                              registers for remote notifications, sets Messaging delegate,
                              forwards APN→FCM, and delivers pushes via NotifyClient.shared.
  ContentView.swift           Home screen: mascot, big toggle, VibezSetupCard, analytics,
                              recent triggers. Owns the overlay queue and the incoming-push
                              handler (handleIncoming). `setupNeeded` gates on
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
                              Owns VibezEvent / VibezShield / VibezAgent / NtfyMessage types
                              (NtfyMessage name kept deliberately — renaming churns many files).
  ScreenTimeManager.swift     @Observable; auth, persisted FamilyActivitySelection,
                              ManagedSettingsStore shield apply/remove, App Group writer.
                              Pre-renders one shield PNG per agent into the App Group at init.
  ShieldCardRenderer.swift    Host-side SwiftUI→UIImage renderer for the shield card. Writes
                              a per-agent PNG into the App Group container so VibezShield (and
                              the NSE) can engage the shield without running ImageRenderer.
  Components.swift            Shared design-system views (pill toggle, top bar, blocked-app
                              card, recent-trigger row) + the TriggerEvent model.
  BlockedOverlay.swift        Full-screen in-app overlay shown when an agent pings; live
                              countdown bound to ScreenTimeManager.pendingTriggers.
  SettingsView.swift          Settings sheet: app picker, block durations, re-pair the Vibez
                              ID, appearance override.
  Mascots.swift               Vector mascots — Claude (pixel critter) + Codex (cloud bot).
  Theme.swift                 Color palette + agent→accent mapping.
  AnalyticsTracker.swift      Per-day usage stats (conversations, replies, ping counts);
                              resets at local midnight. Feeds ContentView's analytics panel.
  TriggerStore.swift          Persists recent triggers (capped at 100) for the Recent
                              triggers list; clears needs-reply when a shield:off push lands.
  IgnoreStore.swift           Persists mute rules (e.g. ignore one conversation by sid) so
                              muted sessions don't raise overlays/shields.
  Vibez.entitlements          aps-environment=development + family-controls + application-groups
  VibezRelease.entitlements   Release variant — aps-environment=production.
  GoogleService-Info.plist    Firebase config for bundle vibezlol.Vibez, project vibez-backend.
VibezShield/                  Shield Configuration Extension (separate target). Reads
                              ShieldState from the App Group and loads the host-rendered
                              per-agent PNG from the App Group container into
                              ShieldConfiguration.icon. Deliberately NO SwiftUI/ImageRenderer
                              here (MainActor-isolated, traps in the extension); all rendering
                              lives in the host's ShieldCardRenderer. Falls back to a
                              text-only shield when the PNG is missing.
  ShieldConfigurationExtension.swift  ShieldConfigurationDataSource subclass; per-open tally.
  ShieldCard.swift                    Agent enum, ShieldState reader, theme constants.
  VibezShield.entitlements            family-controls + application-groups
VibezPushService/             Notification Service Extension (separate target). Runs on every
                              push marked mutable-content:1, BEFORE iOS shows the banner — the
                              only reliable place to engage the shield while Vibez is suspended
                              (the host AppDelegate isn't called when backgrounded on iOS 26).
                              Reads selection/armed/pendingTriggers/blockSeconds from the App
                              Group, writes via ManagedSettingsStore("vibez.shield"), and prunes
                              per-session on a shield:off / reason:timeout push.
  NotificationService.swift   UNNotificationServiceExtension subclass.
  VibezPushService.entitlements  family-controls + application-groups
  Info.plist
Backend/                      Firebase project: vibez-backend.
  firebase.json               Cloud Functions deploy config (codebase=default).
  .firebaserc                 default project = vibez-backend.
  firestore.tokens.rules      Security rules for the non-default "tokens" Firestore database.
  functions/src/index.ts      Three functions (pure helpers in scheduling.ts):
    - registerPushToken (callable, public): {fcmToken, vibezId, platform,
      blockSecondsDone?, blockSecondsNeedsInput?} → Firestore "tokens" db,
      "devices" collection, doc id = fcmToken. The phone publishes its two
      block durations here so /notify can time the timeout unblock.
    - notify (HTTP, public): {vibezId, title, body, event?, shield?, session?, agent?} →
      queries devices where vibezId == X, fans out via sendEachForMulticast.
      For a block (shield≠off + has session) it also enqueues a Cloud Task per
      device to dispatchUnblock at that device's duration + buffer.
    - dispatchUnblock (Cloud Tasks onTaskDispatched): sends a per-session
      shield:off carrying reason:"timeout". The NSE drops the shield only if
      that session is actually due, so stale/duplicate dispatches no-op — the
      server-side backup under the on-device prune (the precise primary).
  functions/src/scheduling.ts Pure, unit-tested helpers (clampDuration, APNs payload build,
                              task scheduling math). Tests in functions/test/scheduling.test.ts.
VibezExtension/               Chrome (MV3) browser companion (TypeScript). Mirrors the iOS
                              block on the desktop: watches the backend for this Vibez ID's
                              block state via Firestore and overlays a block screen on
                              configured sites. Built with build.ts → dist/ (gitignored).
  src/background/             Service worker — Firestore listener, block state, alarms.
  src/content/                Content script + injected block overlay.
  src/popup/                  React popup (toggle, setup card, analytics, recent triggers).
  src/config.ts               Shared config; mirrors VIBEZ_ID_PATTERN (see Conventions).
ClaudePlugin/                 Claude Code plugin source.
  scripts/setup.sh            Generates the 4-word Vibez ID, embeds the 2016-word wordlist,
                              prints instructions. /vibez:setup invokes this.
  scripts/notify.sh           Hook script. POSTs lifecycle events to /notify with the
                              user's Vibez ID. Handles session-start, stop, notification,
                              pre/post-tool-use (AskUserQuestion + tool-grant),
                              user-prompt-submit. Falls back to setup.sh for first-run ID gen.
  hooks/hooks.json            Registers notify.sh against 6 Claude Code lifecycle hooks.
  commands/setup.md           /vibez:setup slash-command definition.
CodexPlugin/                  Codex plugin source. Parallel structure to ClaudePlugin
                              (independently distributed — the two plugins can't share files).
  scripts/setup.sh            Same Vibez ID generator as the Claude plugin (shared
                              ~/.config/vibez/vibez-id file so one ID covers both agents).
  scripts/notify.sh           Codex-flavored hook script — adds permission-request,
                              ephemeral-session detection, "cx" agent tag.
  skills/vibez-setup/SKILL.md Codex skill that surfaces/tests/regenerates the Vibez ID.
.claude-plugin/marketplace.json  Claude Code plugin marketplace manifest (→ ClaudePlugin).
.agents/plugins/marketplace.json Codex plugin marketplace manifest (→ CodexPlugin).
Vibez.xcodeproj/              PBXFileSystemSynchronizedRootGroup — drop a .swift into a target
                              folder and it auto-builds. Entitlements still need
                              CODE_SIGN_ENTITLEMENTS wired manually.
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
  expiry, dark/light) plus the host-rendered shield PNGs. The `"shieldState"` plist dict schema
  is mirrored across three sites — keep them in sync: `Vibez/ScreenTimeManager.swift`
  (`ShieldState.asDict`, writer), `VibezShield/ShieldCard.swift` (`ShieldState.read`, reader),
  and `VibezPushService/NotificationService.swift` (the NSE, which also engages the shield).
- Selection persists in standard `UserDefaults` via `PropertyListEncoder`. Shield store name: `vibez.shield`.
- **Vibez ID format:** `^[a-z]{3,5}(-[a-z]{3,5}){3}$` — 4 hyphen-separated 3-5 letter lowercase words. ~44 bits of entropy (2016-word list). Enforced client- and server-side. The pattern is mirrored across four runtimes — keep them in sync: `PushTokenRegistrar.vibezIdPattern` (Swift), `Backend/functions/src/index.ts` `VIBEZ_ID_PATTERN` (TS), `VibezExtension/src/config.ts` `VIBEZ_ID_PATTERN` (TS), and the plugins' `setup.sh` wordlist generator (bash).
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
