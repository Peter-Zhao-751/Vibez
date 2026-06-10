//
//  Mascots.swift
//  Vibez
//
//  The Claude mascot — "Clawd," the pixel critter. This is the thin,
//  canonical entry point every screen uses; the animation itself lives
//  in ClawdTheater (SpriteSheetView.swift), the sprite-sheet show that
//  also drives the home-screen hero. ClaudeMascot adapts the old
//  vector-mascot call signature (listening / size / focused / animate)
//  onto the sprite theater, so every existing call site renders the
//  animated critter unchanged.
//
//  The old inline-SVG vector critter (drawn body + eyes + sleeping z's)
//  is gone. Every surface now draws the real sprite: the shield-card PNG
//  renderer and the recent-trigger badge both render ClawdRestingSprite
//  (2026-06-09), so the hand-traced ClaudeBodyShape vector is retired.
//

import SwiftUI

// MARK: - Claude — pixel critter (Clawd)

/// The Claude mascot. Renders the ClawdTheater sprite show, framed to a
/// `size × size*0.9` footprint (matching the old vector mascot's box) so
/// it drops into every existing layout unchanged.
///
/// Parameter mapping onto ClawdTheater:
/// - `listening` → `animating`: plays the idle-plus-acts show vs. freezing
///   with sleepy line-eyes.
/// - `focused` → `focused`: rests with a persistent `> <` squint.
/// - `animate` → `quiet` (inverted): `animate: false` keeps the critter at
///   rest with awake, blinking eyes but suppresses the activity bursts —
///   the calm placement the old `animate: false` (no body-bob) gave.
/// - `oneShot` → `oneShot`: play one random act ~0.3 s after appearing,
///   then idle (blink/squint only) — the in-app block screen's behavior.
/// - `squintTrigger` → one brief, forced resting-pose `> <` blink.
struct ClaudeMascot: View {
    let listening: Bool
    let size: CGFloat
    var focused: Bool = false
    var animate: Bool = true
    var oneShot: Bool = false
    var squintTrigger: Int = 0

    /// The sprite cells carry transparent air around the critter, so the
    /// sheet is drawn wider than the footprint and then framed back down
    /// to it (feet at the bottom, head room overflowing upward). 2.6 is
    /// the calibration that lands the critter at ~`size` wide — the same
    /// apparent size the old vector mascot had. Matches the home hero.
    private var spriteWidth: CGFloat { size * 2.6 }

    var body: some View {
        ClawdTheater(
            width: spriteWidth,
            animating: listening,
            focused: focused,
            quiet: !animate,
            oneShot: oneShot,
            squintTrigger: squintTrigger
        )
        .frame(width: size, height: size * 0.9, alignment: .bottom)
    }
}

#if DEBUG
#Preview("Mascot states") {
    HStack(spacing: 24) {
        VStack { ClaudeMascot(listening: true, size: 110); Text("listening").font(.caption2) }
        VStack { ClaudeMascot(listening: true, size: 110, focused: true); Text("focused").font(.caption2) }
        VStack { ClaudeMascot(listening: false, size: 110); Text("sleeping").font(.caption2) }
        VStack { ClaudeMascot(listening: true, size: 110, animate: false); Text("quiet").font(.caption2) }
    }
    .padding()
    .preferredColorScheme(.dark)
}
#endif
