# App Store carousel — design spec (2026-06-11)

Approved interactively via the visual-companion review (20 iterations, final:
`.superpowers/brainstorm/53748-1781159115/content/final-set-review-20.html`).

## Output

Five portrait screenshots for the 6.9" App Store slot, **1320×2868 px** each, in
this order:

1. `slide-1-pitch.png`
2. `slide-2-ping.png`
3. `slide-3a-agents-left.png` ┐ one 2640×2868 composition split down the
4. `slide-3b-agents-right.png`┘ middle — objects cross the boundary Twitch-style
5. `slide-4-setup.png`

Built as Remotion stills in `carousel/` (`npx remotion still`). The spread is one
double-wide comp; ffmpeg crops the halves so the seam is pixel-exact.

## Design system

- Canvas: Paper Editorial cream `#faf4ea`. No wordmark/logo on any slide (the
  store listing carries the brand; decided after trying wordmark + glyph).
- Headline: SF/-apple-system weight 900, ink `#1a1410`, tracking ≈ −0.04 em,
  two lines, second line (or key phrase) in Claude orange `#d97757`.
  Codex words use periwinkle `#7287e0`.
- Subline: 60 % ink, weight 500, sits directly under the headline.
- Phones: real simulator captures inside a CSS bezel (near-black `#1d1d1f`
  ring, ~32 px outer radius at preview scale), bottom-cropped, soft shadow.
- All preview geometry is in 280×608 “preview units”; multiply by **4.714**
  for the 1320×2868 render (the Remotion comps share a SCALE constant).

## Slides

| # | Headline (line 2 = accent) | Subline | Art |
|---|---|---|---|
| 1 | Claude's done. / **Stop scrolling.** | Blocks distracting apps when Claude Code or Codex needs you. | `shot-home-armed-light4.png` — armed light home, Recent Triggers shows cx “Migrate the billing webhooks” (just now) + cc “Fix the flaky auth tests”. Bezel w 204, bottom −30. |
| 2 | Agent pings. / **Phone locks.** | A question — or a finished task — blocks your feeds until you reply. | `shot-overlay-cc-done-dark.png` — DONE overlay, “Done — Fix the flaky auth tests / All 142 tests green — pushed to your branch.”, crisp **27s** countdown. Bezel w 212, bottom −45. |
| 3ab | **Claude Code** (pane A) / **Codex.** (pane B, no “&”) | A: “All your agents, one app” · B: “orange pings from Claude, blue from Codex.” | One 574×608-unit scene: orange→periwinkle wash, two glow orbs, phones tightly overlapped at center fanned **∓16°** (origin bottom-center): light `shot-overlay-cc-light3.png` (“Needs you — Refactor the payments module”, 14:57) w 229 @ (140,244) BEHIND dark `shot-overlay-cx-dark2.png` (“Migrate the billing webhooks”, 14:57) w 236 @ (202,254). Light phone is 3 % smaller on purpose (irradiation illusion). Text is split-safe: each pane fully contains its half (A right-aligned ending x≈276, B left-aligned from x≈298) — nothing falls into the gutter. |
| 4 | One command. / **You're paired.** | Free, no accounts — a private 4-word ID pairs your Mac to your phone. | Mac terminal card (traffic lights, mono: `$ npx getvibez` → “Detected: Claude Code, Codex / Installing Vibez plugin… done ✓ / Your Vibez ID: **moss-pine-fox-jazz**”) above `shot-setup-light2.png` (unpaired Connect Vibez card; field placeholder matches the terminal's ID). Bezel w 198, bottom −132. |

## Asset provenance (re-render runbook)

All captures from the iPhone 17 Pro Max sim (iOS 26.4,
`A26A62A8-9A63-4FAC-B668-F4ED79AC9945`), native 1320×2868, status bar
`simctl status_bar override --time 9:41 --batteryLevel 100 ...`. Signed Debug
build (`SYMROOT=/tmp/vibez_sym2`, NO `CODE_SIGNING_ALLOWED=NO` — unsigned strips
the App Group and the shield PNGs/seq files never render). Common launch args:
`-vibez.vibezId test -vibez.debug.skipOnboarding YES -vibez.debug.fakeScreenTimeAuth YES
-vibez.manualBlocking.v1 YES -vibez.appearance light|dark`.

- Overlays: launch armed foreground, `simctl push` the payload (`/tmp/push-*.json`
  shapes: aps.alert + event/shield/session/agent/seq), wait 2.5 s, then a
  **burst of 4 shots 0.73 s apart** — the countdown ticks once per second and
  single shots catch mid-tick blur; pick a crisp frame.
- Trigger-history seeding: pushes persist rows in TriggerStore; send
  `shield:off` (replied) per session so needs-input blocks don't re-raise the
  overlay on relaunch; done blocks expire in 30 s on their own. Re-seed
  distinct titles, never the same one twice (looked terrible).
- Shield replica (not in the final set, but kept): `-vibez.debug.shieldReplica
  YES [-vibez.debug.shieldReplicaAgent cx] [-vibez.debug.shieldReplicaDark NO]`
  — DEBUG-only scene branch in `VibezApp.swift` + `Vibez/ShieldReplicaView.swift`
  mirroring VibezShield's exact colors/slots over a generic blurred feed
  (ManagedSettings shields never fire on a sim).
- zsh gotcha: unquoted `$1` does NOT word-split — pass launch args via arrays
  or explicit commands, never through a quoted function arg.

Final chosen captures live in `/tmp/vibez-carousel-assets/` during a session and
are copied into `carousel/public/` for rendering (the repo copy is canonical).

## Decisions log (don't relitigate)

- Paper Editorial direction chosen over Midnight Glow / Orange Billboard.
- Slide-1 headline: “Claude's done. Stop scrolling.” over 3 alternatives.
- Tight-5 arc chosen; shield slide CUT after seeing it (out of 5 → 4 concepts,
  then the agents slide split into the 2-pane spread → 5 files).
- No wordmark anywhere; headline starts at top (y≈46 preview units) on all
  slides — uniform top edge across the set.
- Slide 2 must show a **done** event (not needs-input) for variety.
- Spread: one poster split in half; phones overlap deeply at center; text in
  two seam-hugging parts so no glyphs are lost to the gutter.
