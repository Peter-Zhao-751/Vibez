# Vibez Chrome Extension — Design

**Date:** 2026-05-31
**Status:** Implemented (`VibezExtension/`). Backend deploy + Firestore TTL pending.

## Goal

Port the Vibez idea to the desktop browser: a Chrome (MV3) extension that
**blocks distracting websites** with the same full-screen overlay the iOS app
uses, driven by the **same backend events** (Claude Code / Codex going idle or
asking for input). Same UI language and color scheme as the iOS app.

Built with **Bun** (install + bundler) and **React + TypeScript**.

## What "exactly like the app" means here

The extension reacts to the *same events* as the phone, but over the transport
that suits a browser. The iPhone stays 100% on APNs (Firestore cannot wake a
suspended iOS app — unchanged). The extension consumes a **Firestore event
log**. Both are fed by the same `notify` Cloud Function and the same Vibez ID.

## Architecture

```
                 ┌─▶ FCM → APNs → iPhone           (EXISTING, untouched)
plugin → notify ─┤   (only if an iOS device is registered)
                 └─▶ write events/{vibezId}/items/{id}   (NEW, additive)
                     (only if an extension is registered)
                          │
                          ▼
          extension background SW  ── onSnapshot ──▶ block-state machine
                          │                                │
                          │ chrome.storage + messaging     │
                          ▼                                ▼
                    popup (React UI)              content script overlay
                                                  (React in a shadow root)
```

### Three extension surfaces

1. **Popup (React)** — the iOS home-screen analog. Wordmark top bar, mascot,
   WARP-style pill toggle (arm/disarm), setup card (enter Vibez ID), the
   blocked-sites list, a "Today" analytics panel, and a Recent Triggers list.
2. **Background service worker** — the only Firebase client. Owns the Firestore
   `onSnapshot` listener, the block-state machine, registration, analytics, and
   a keepalive alarm. Publishes block state to `chrome.storage` and messages
   tabs.
3. **Content script (React overlay)** — injected on all sites, dormant until a
   block applies to the current host; then renders the `BlockedOverlay` analog
   into a shadow root (so page CSS can't bleed in).

The background SW is the single source of truth. Popup and content script never
touch Firebase directly — they read `chrome.storage` and exchange runtime
messages with the SW.

## Backend changes (additive, iOS untouched)

`Backend/functions/src/index.ts`:

- **`notify`** — after fetching the device snapshot for the Vibez ID, partition
  by `platform`:
  - Send the existing FCM multicast **only to non-`web` tokens** (so the iOS
    path is unchanged *and* a web client id is never mis-sent to FCM).
  - If **any** device has `platform == "web"`, additionally write an event doc
    to `events/{vibezId}/items/{autoId}` in the `tokens` database:
    `{ title, body, event?, shield?, session?, agent?, createdAt: serverTimestamp(), expireAt: now+24h }`.
  - This is the "nothing wasted" gating: APNs only if a phone is registered,
    Firestore only if an extension is registered, both if both.
- **`registerPushToken`** — no signature change. The extension registers a
  "device" with `platform: "web"` and a 32-char random client id as the doc id
  (satisfies the existing `length >= 20` check; needs no FCM token because it
  listens to Firestore).
- **Security rules** (`firestore.tokens.rules`, wired in `firebase.json`):
  `events/{vibezId}/items/{id}` is publicly readable (the Vibez ID is in the
  path — ~44-bit secret, no enumeration possible) and client-unwritable. The
  server writes via the Admin SDK, which bypasses rules. Everything else
  (`devices`, …) stays server-only.
- **TTL** — a Firestore TTL policy on the `expireAt` field auto-expires events
  after ~24h (configured via console/gcloud; documented in the extension
  README).

## Block semantics (mirror the app)

- `event: done` → 30s block. `needs-input` / untagged → 900s (15 min).
- `shield: off` (user replied) → lift the block for that session.
- Per-session pending map (like `ScreenTimeManager.pendingTriggers`); a block is
  active while any session is pending. The overlay shows the most recent event.
- Countdown shown in the overlay; **Dismiss** button (configurable, default on).
- Accent follows the producing agent (`cc` → Claude orange, `cx` → Codex blue).

## Blocking mechanism

- The user maintains a domain list (seeded with common distractions:
  instagram, tiktok, youtube, reddit, x/twitter, facebook — fully editable).
- Matching: a host matches a listed domain if `host === domain` or
  `host.endsWith("." + domain)`.
- While a block is active, any tab on a matched host shows the overlay:
  - **New navigations** are caught at navigation time (robust even if the SW
    just woke and replayed).
  - **Already-open tabs** are covered when the SW receives the event (kept
    fresh by the listener + a ~25s keepalive alarm).
- The overlay covers the viewport, disables scroll/interaction, and clears when
  the block expires or is dismissed.

## Why Firestore is fine for the extension (but not iOS)

A Chrome MV3 service worker is revived by browser events — including web
navigation — and Firestore events are **durable**, so a slept worker replays
missed events on wake. The block gate is effectively evaluated at navigation
time. A suspended iPhone genuinely cannot run code until APNs wakes it, which is
why iOS keeps APNs and the extension uses Firestore.

## Toolchain / build

- `VibezExtension/` at repo root. Bun for install + bundling.
- `build.ts` uses `Bun.build` to bundle three entries → `dist/`:
  - `popup.js` (ESM, loaded by `popup.html` as a module script),
  - `background.js` (ESM, manifest `type: "module"`),
  - `content.js` (injected directly as a **classic content script** — the
    bundle has no ESM syntax, so it runs in the isolated world CSP-exempt;
    avoids a page-context dynamic import that strict sites like instagram/x
    would block via CSP),
  - plus copies `manifest.json`, `popup.html`, CSS, and icons into `dist/`.
- `bun run build` (one-shot) and `bun run dev` (watch). Load `dist/` unpacked.
- Firebase **Web SDK** (`firebase/app`, `firebase/firestore`, `firebase/functions`)
  used only in the background SW; Firestore initialized with
  `experimentalForceLongPolling: true` for service-worker reliability, pointed
  at the named database `tokens`.

## Color scheme (ported from `Theme.swift`)

- Dark: bg `#0c0d12`, panel `#16171d`, widget `#1f2027`, chip `#16171d`,
  fg `#f5f1ec`, fgMute `#6f6c7a`, fgFaint `#56545e`, hairline `#272832`.
- Light: bg `#fbf8f4`, panel `#ffffff`, widget `#e4dfd6`, chip `#f1ede5`,
  fg `#1a0e08`, fgMute `#6e655c`, fgFaint `#a8a097`, hairline `#ece4d8`.
- Accents: Claude `#dd7a52`/`#b85a36`, Codex `#8c9ce8`/`#5d6fbc`. "Both" lerps.
- Default appearance: dark; agent accent follows incoming events (default Claude).

## Out of scope (v1)

- FCM web push / VAPID transport (Firestore chosen for robustness).
- Cross-browser (Firefox/Safari) packaging.
- Migrating iOS to read events from Firestore (no reason to disturb it).
```
