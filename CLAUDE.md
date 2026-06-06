# Vibez

iOS app that blocks distracting apps (Instagram, TikTok, etc.) whenever Claude Code or Codex finishes a task or asks for input — turning agent idle time into focus time instead of doomscroll time. Live on the App Store, free, as **"AI Coding Focus - Vibez"** (https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780).

## Status

- **Family Controls working on device.** Screen Time API integration via `FamilyControls` + `ManagedSettings` runs end-to-end against the iOS 26.4 SDK on Peter's iPhone. Toggle on → selected apps shielded; toggle off → unblocked. State survives app kill. Peter is enrolled in the paid Apple Developer Program, so the `com.apple.developer.family-controls` entitlement provisions cleanly.
- **Firebase-backed push pipeline working end-to-end.** Mac plugin (Claude Code or Codex) POSTs lifecycle events to a Firebase Cloud Function (`/notify`); the function fans out via FCM to every device registered to the user's Vibez ID. Push lands while Vibez is suspended (the whole reason FCM replaces ntfy). The four-word Vibez ID pairs Mac → phone.
- **Shield Configuration Extension shipping.** `VibezShield` reads `ShieldState` from the App Group `group.vibezlol.Vibez` and shows a custom shield (host-rendered mascot PNG + push title/body, tinted accent background, "Close" button). The PNG is rendered on the host (`ShieldCardRenderer`), not in the extension.
- **ntfy is gone.** WebSocket subscription, ntfy URL UI, push-vibez.py, and the topic-based plugin path are all removed. One push path: plugin → Firebase → FCM → APNs → Vibez.
- **Shipped: live on the App Store (2026-06-06, v1.0, free).** Family Controls Distribution Request and App Store review were both approved within days. Backend runs on Peter's Firebase project; .p8 lives in Firebase Cloud Messaging, never ships to users.

## File map

```
Vibez/                        Main iOS app target.
  VibezApp.swift              SwiftUI @main; AppDelegate calls FirebaseApp.configure(),
                              registers for remote notifications, sets Messaging delegate,
                              forwards APN→FCM, and delivers pushes via NotifyClient.shared.
  ContentView.swift           Home-screen root: shared state, scene-lifecycle plumbing
                              (App Group drains, scenePhase re-checks), setup-card
                              presentation dance. `setupNeeded` gates on no Vibez ID or
                              a registration error (in-flight states stay unlocked); it also
                              seeds the initial layout state in init so a paired cold start
                              renders the expanded layout on frame 1 — no reflow, hint and
                              mascot appear together. The rest of the screen lives in the
                              ContentView+* sibling files (extensions — shared members are
                              internal on purpose, `private` is file-scoped).
  ContentView+Home.swift      Home layout half: hero/mascot, big toggle, setup card, Recent
                              triggers sheet, focus-mode tap flow + its app-picker detour.
  ContentView+Incoming.swift  Push-routing half: handleIncoming + the overlay queue and the
                              per-ping block-duration policy.
  ContentView+Previews.swift  Seeded preview environments for the home screen.
  OnboardingLaunchGate.swift  Cold-launch onboarding gate (ViewModifier), extracted from
                              ContentView: decides once per launch whether OnboardingFlow
                              presents, owns the fullScreenCover + the
                              "vibez.onboardingCompleted" flag, and arms the toggle after a
                              completed (not skipped) walkthrough. Onboarding owns the
                              permission prompts (the old auto-requesting .task is gone).
  VibezSetupCard.swift        Pairing card — user types in the 4-word Vibez ID, calls
                              registrar.setVibezId(...). Replaces the old NotificationSetupCard.
  OnboardingState.swift       @Observable step engine for the onboarding flow. Gate is
                              live state (notif status + FC auth + Vibez ID present),
                              hardened by "vibez.onboardingCompleted": FC's
                              authorizationStatus can read .notDetermined for a beat
                              after cold launch even when granted, so a completed install
                              re-presents ONLY on a definite failure (unpaired or an
                              explicit .denied — hasDefiniteFailure), never on that
                              ambiguity (no settle stall, no flash). FC-only failures on
                              never-completed installs settleAndRecheck() for up to ~2s.
                              Steps snapshot at begin(); advance() auto-skips steps
                              satisfied mid-flow, and OnboardingFlow live-verifies each
                              permission step as it becomes current (self-skips if the
                              permission is already granted). DEBUG launch arg
                              -vibez.debug.fakeScreenTimeAuth YES fakes the FC gate
                              for sim verification (FC can't be granted on a sim).
  OnboardingFlow.swift        fullScreenCover container: forward-only transitions, progress
                              dots, Skip, scenePhase re-check for Settings round-trips.
                              Presented by ContentView (launch) and SettingsView (Tutorial).
  OnboardingSteps.swift       The six pages: welcome, notifications + Screen Time
                              (practice-tap mock dialogs w/ denied-state remediation),
                              plugin install (shows BOTH agents' commands), Vibez ID
                              pairing, how-it-works + app version. The agent-pick page
                              and the "vibez.agent" pref are gone — Claude theme always.
  MockSystemDialog.swift      Practice-tap replica of the iOS permission alert — confirm
                              fires the real prompt; Don't Allow wiggles + hints. System
                              look on purpose (not app theme).
  PushTokenRegistrar.swift    @Observable singleton; FCM MessagingDelegate. Holds the
                              FCM token + user's Vibez ID, persists vibezId in UserDefaults
                              under "vibez.vibezId", calls the registerPushToken Cloud
                              Function on every fresh token OR ID change. The literal ID
                              "test" is an offline escape hatch: paired locally (state
                              .registered, toggle/shield usable), never calls the server.
  NotifyClient.swift          Push inbox. WebSocket is gone; class still exists because
                              AppDelegate routes incoming FCM userInfo through
                              acceptPushUserInfo → lastMessage → ContentView.handleIncoming.
                              Owns VibezEvent / VibezShield / VibezAgent / NtfyMessage types
                              (NtfyMessage name kept deliberately — renaming churns many files).
  ScreenTimeManager.swift     @Observable; auth, persisted FamilyActivitySelection,
                              ManagedSettingsStore shield apply/remove, App Group writer.
                              Pre-renders the per-agent shield PNGs (shield-claude.png,
                              shield-codex.png) into the App Group at init; prunes legacy
                              renders (shield.png, -both, -none).
  ShieldCardRenderer.swift    Host-side SwiftUI→UIImage renderer for the shield card. Writes
                              the per-agent PNGs (Claude pixel critter / Codex logo + blue
                              glow) into the App Group container so VibezShield (and the NSE)
                              can engage the shield without running ImageRenderer.
  Components.swift            Shared design-system views (pill toggle, top bar, blocked-app
                              card, recent-trigger row) + the TriggerEvent model.
  BlockedOverlay.swift        Full-screen in-app overlay shown when an agent pings; live
                              countdown bound to ScreenTimeManager.pendingTriggers. Codex
                              pings render the codex logo + periwinkle accent; everything
                              else stays Claude.
  SettingsView.swift          Settings sheet: app picker, block durations, re-pair the Vibez
                              ID, appearance override.
  Mascots.swift               Vector mascot — Claude (pixel critter). The Codex cloud-bot
                              VECTOR stays deleted (2026-06-05), but the Codex identity is
                              back on the two blocking surfaces (2026-06-06): BlockedOverlay
                              and the shield card render the codex.imageset logo + blues
                              when a "cx" push engages them. Everywhere else stays Claude.
  Theme.swift                 Color palette, pinned to the Claude accent (Theme.make(), no
                              agent param; the Agent enum is gone). Theme.codexBlue (#8c9ce8)
                              is the one Codex constant — BlockedOverlay's per-message accent.
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
                              per-agent PNG (shield-claude.png / shield-codex.png) into
                              ShieldConfiguration.icon; the dict's `agent` field drives icon,
                              Close-button accent, and background wash again (Codex = blue/navy,
                              2026-06-06). A missing Codex PNG or an untagged ping falls back
                              to the Claude card. Deliberately NO SwiftUI/ImageRenderer here
                              (MainActor-isolated, traps in the extension); all rendering lives
                              in the host's ShieldCardRenderer. Falls back to a text-only
                              shield when the PNG is missing.
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
  functions/src/ratelimit.ts  Pure token-bucket + lazy-escalation math (LazyLimiter,
                              BoundedMap, sanitizeBucketState); Firestore glue lives
                              in index.ts. Tests in functions/test/ratelimit.test.ts.
  functions/src/validation.ts Pure request validation: caps, enum whitelists, clamps;
                              owns the server-side VIBEZ_ID_PATTERN. Tests in
                              functions/test/validation.test.ts.
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
- **Paid ADP required for development on device, not just for App Store.** Peter is enrolled. The Family Controls Distribution Request is granted for all three bundle IDs (approval took ~1 minute, not the commonly-reported weeks) — don't re-request it.
- **APNs auth key must be enabled for BOTH Sandbox and Production at Apple Developer Center.** Single-environment keys cause `messaging/third-party-auth-error` → `BadEnvironmentKeyInToken` on debug builds (sandbox tokens). Always create keys with both environments enabled.

## Conventions

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on — assume MainActor by default; only add `nonisolated` deliberately.
- Bundle ID: `vibezlol.Vibez`. Team: `QW64TZKUAF`. Firebase project: `vibez-backend`.
- App Group: `group.vibezlol.Vibez`. Carries the live shield context (agent, push title/body,
  expiry, dark/light) plus the host-rendered shield PNGs. The `"shieldState"` plist dict schema
  is mirrored across three sites — keep them in sync: `Vibez/ScreenTimeManager.swift`
  (`ShieldState.asDict`, writer), `VibezShield/ShieldCard.swift` (`ShieldState.read`, reader),
  and `VibezPushService/NotificationService.swift` (the NSE, which also engages the shield).
- **Agent accent colors are mirrored across two targets** — Codex RGB(0.29, 0.48, 1.00)
  and Claude RGB(0.95, 0.45, 0.20) live in BOTH `Vibez/ShieldCardRenderer.swift`
  (`ShieldCardTheme`) and `VibezShield/ShieldCard.swift` (`accentUIColor` /
  `backgroundUIColor`). Separate targets can't share source — keep them in sync when
  changing either. (`Theme.codexBlue` #8c9ce8 is deliberately different: the in-app
  overlay's softer periwinkle.)
- Selection persists in standard `UserDefaults` via `PropertyListEncoder`. Shield store name: `vibez.shield`.
- **Vibez ID format:** `^[a-z]{3,5}(-[a-z]{3,5}){3}$` — 4 hyphen-separated 3-5 letter lowercase words. ~44 bits of entropy (2016-word list). Enforced client- and server-side. The pattern is mirrored across four runtimes — keep them in sync: `PushTokenRegistrar.vibezIdPattern` (Swift), `Backend/functions/src/validation.ts` `VIBEZ_ID_PATTERN` (TS), `VibezExtension/src/config.ts` `VIBEZ_ID_PATTERN` (TS), and the plugins' `setup.sh` wordlist generator (bash).
- **Same-conversation block debounce (both plugins, mirrored):** `notify.sh` skips a
  `shield:on` send when an AGENT event (`shield:on`, sent or suppressed) for the same
  session landed within `VIBEZ_BLOCK_DEBOUNCE_SECONDS` (default 5s, rolling window, `0`
  disables; stamp file `~/.config/vibez/lastevent.<sid>`, claimed before the curl,
  rolled back on send failure). `shield:off` (replies) is invisible to the debounce in
  BOTH directions: it always sends (it unblocks the phone) and never touches the stamp,
  so an ask/`done` landing seconds after a reply still banners + blocks. (Changed
  2026-06-05 — replies used to refresh the stamp, which silenced the trailing ask/done
  and made rapid test cycles look like a dead pipeline; policy is selftest-covered via
  the `stamp-*` cases.) First ask of a burst still blocks + banners with the full
  timer. Known accepted edge: concurrent shield:on hooks can race the claim (worst
  case = one extra banner).
- **Firestore database is named "tokens" (non-default).** Always use `getFirestore("tokens")` on the server; the iOS app never touches Firestore directly — it goes through `registerPushToken`.
- **All Cloud Functions are deployed with `{invoker: "public"}`.** Gen-2 functions are Cloud Run services that default to authenticated; we explicitly open them.
- **Backend abuse limits (design spec 2026-06-04):** `/notify` and
  `registerPushToken` are rate limited per Vibez ID (token bucket, burst 5,
  refill 1/sec, lazy Firestore escalation in the `rateLimits` collection,
  24h TTL), per client IP (20-burst/5 per sec, in-memory, derived from the
  LAST X-Forwarded-For entry — `req.ip` is the proxy), and per instance
  (200-burst/100 per sec load-shed). Caps: title 100 / body 200 chars
  (clamped server-side), 8 KB request, event/shield/agent whitelisted,
  session `^[A-Za-z0-9._:-]{1,128}$`, ≤10 devices per ID, FCM dry-run
  validates new non-web tokens (fails open on transient FCM errors).
  `/notify` always answers `{ok: true}` — no claimed/unclaimed oracle.
  `maxInstances: 3` caps compute. APNs payloads carry title/body ONLY in
  `aps.alert`; the NSE App Group drain file keeps flat title/body keys and
  `NotifyClient.acceptPushUserInfo` parses both shapes.

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

### App Store status

Shipped 2026-06-06: free, v1.0, listed as **"AI Coding Focus - Vibez"**
(https://apps.apple.com/us/app/ai-coding-focus-vibez/id6775433780). Family Controls
Distribution Request and App Store review were both approved within days of submission.
Update submissions are the ordinary flow: archive (Release, Any iOS Device), upload,
submit — keep the aps-environment Debug/Release entitlements split intact.

Remaining post-launch hardening:

1. App Check on the Cloud Functions (currently `invoker: "public"`; Vibez ID is the only secret).
