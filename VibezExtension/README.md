# Vibez — Chrome extension

Vibez for the browser. A big arm/disarm toggle; when armed, it listens to the
same backend as the iOS app and **blocks distracting websites with the same
full-screen overlay** whenever Claude Code or Codex finishes a task or asks for
input. Same UI and color scheme as the iOS app.

Built with **Bun** + **React + TypeScript**. Design spec:
[`docs/superpowers/specs/2026-05-31-vibez-chrome-extension-design.md`](../docs/superpowers/specs/2026-05-31-vibez-chrome-extension-design.md).

## How it works

The phone can't be replaced by Firestore (a suspended iOS app can't be woken by
it), so iOS stays on APNs. The browser is a different platform: the `notify`
Cloud Function now **also** writes each event to a Firestore log
(`events/{vibezId}/items/{id}`) — but only when an extension is registered for
that Vibez ID. The extension's background service worker live-listens with
`onSnapshot`, turns events into a block window, and publishes block state to
`chrome.storage`. A content script shows the overlay on listed sites. Nothing
about the iOS APNs pipeline changes.

```
plugin → notify ─┬─▶ FCM → APNs → iPhone        (unchanged; only if a phone is registered)
                 └─▶ Firestore events log        (new; only if an extension is registered)
                         └─▶ extension SW (onSnapshot) → block state → overlay
```

| Surface | File | Role |
| --- | --- | --- |
| Popup (React) | `src/popup/` | Toggle, pairing, blocked-site list, Today stats, Recent Triggers |
| Background SW | `src/background/` | Firestore listener, block-state machine, registration, alarms |
| Content overlay (React) | `src/content/` | Full-screen block overlay in a shadow root |

## Build & load

```bash
cd VibezExtension
bun install
bun run gen-icons   # one-time: writes icons/icon-{16,48,128}.png
bun run build       # bundles → dist/
# bun run dev       # watch mode
```

Then in Chrome: `chrome://extensions` → enable **Developer mode** → **Load
unpacked** → select `VibezExtension/dist`.

## Pair it

1. On your Mac, get your 4-word Vibez ID: run `/vibez:setup` in Claude Code, or
   ask Codex for it (the `vibez-setup` skill). Both agents share the same ID —
   the same one the phone uses.
2. Click the Vibez toolbar icon, type the Vibez ID into the setup card, **Save**.
   The status dot turns green ("paired") once the backend accepts it.
3. Flip the big toggle **ON**. Edit the blocked-site list as you like.
4. Gear → **Test overlay** previews the block on whatever website you're
   currently viewing — no pairing or arming required, auto-clears after 30s.

   > After loading/reloading the extension, **reload the website tab** you want
   > to test on (content scripts only attach on page load). The preview needs a
   > normal `http(s)` page — it can't show on the New Tab page or `chrome://`
   > pages, where extensions aren't allowed to run.

## Backend (one-time)

The extension needs the additive backend changes deployed:

```bash
cd Backend
npx firebase-tools@latest deploy --only functions,firestore
```

- `functions` ships the updated `notify` (Firestore event write + platform
  gating).
- `firestore` deploys `firestore.tokens.rules` to the **`tokens`** database
  (public read on `events/{vibezId}/items`, server-only writes).

**TTL (recommended):** auto-expire old events by setting a TTL policy on the
`expireAt` field of the `items` collection group in the `tokens` database:

```bash
gcloud firestore fields ttls update expireAt \
  --collection-group=items --database=tokens --enable-ttl
```

## Notes

- Firebase config lives in `src/config.ts` (API keys aren't secret). If reads
  fail with an api-key error, register a **Web** app in the Firebase console and
  paste its config.
- Block durations mirror the app: `done` → 30s, everything else → 15 min;
  a reply (`shield: off`) lifts the block. Dismiss is on by default (gear).
- The background worker is kept warm by a 30s keepalive alarm; because events
  are durable in Firestore, a napping worker replays anything it missed on wake.
