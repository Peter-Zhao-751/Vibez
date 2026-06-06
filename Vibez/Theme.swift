//
//  Theme.swift
//  Vibez
//
//  Color palette. Translated from the reference design's
//  `themeFor(agent, dark)` JS function, pinned to the Claude accent.
//  The one Codex color (codexBlue) exists for the blocking surfaces
//  only — BlockedOverlay (and the shield card, which has its own
//  constants) go blue when a Codex push engages them; the rest of
//  the app stays Claude.
//

import SwiftUI
import UIKit

/// Order in which stacked overlays surface to the user when more than
/// one block is pending at once.
///
/// - `stack` (LIFO): newest ping is shown on top; dismissing reveals the
///   next-most-recent unresolved block. Good when the latest interruption
///   is usually the one you care about.
/// - `queue` (FIFO): the oldest unresolved block stays visible until
///   dismissed; new pings line up behind it. Good when you want to clear
///   work in arrival order without skipping ahead.
enum OverlayOrder: String, CaseIterable, Identifiable {
    case stack
    case queue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stack: "Newest first"
        case .queue: "Oldest first"
        }
    }
}

enum AppearancePref: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    func effectiveDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: systemIsDark
        case .light: false
        case .dark: true
        }
    }

    /// The single source of truth for appearance, fed to SwiftUI's
    /// `.preferredColorScheme(_:)`. Driving the whole hierarchy this way —
    /// instead of pinning `window.overrideUserInterfaceStyle` — leaves the
    /// trait collection free for iOS to toggle when it renders the light
    /// *and* dark App Switcher snapshots, so the cached card stays in step
    /// with the live UI. `nil` follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

struct Theme {
    let bg: Color
    let bgPanel: Color
    let bgWidget: Color
    let bgChip: Color
    let fg: Color
    let fgMute: Color
    let fgFaint: Color
    let hairline: Color
    let accent: Color
    let accentDeep: Color
    let pillGradient: LinearGradient
    /// Track color of the big toggle when it's off.
    let pillOff: Color
    let onAccent: Color

    static let claudeOrange = Color(hex: 0xdd7a52)
    static let claudeDeep   = Color(hex: 0xb85a36)
    /// Codex periwinkle — used ONLY by BlockedOverlay's per-message
    /// accent. The app theme stays Claude (Theme.make() has no agent
    /// param on purpose); blocking surfaces go blue per message.
    static let codexBlue    = Color(hex: 0x8c9ce8)

    static func make() -> Theme {
        let accent = claudeOrange
        let accentDeep = claudeDeep

        let pillGradient = LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        // Every neutral resolves its own light/dark variant from the live
        // trait collection. accent/accentDeep/pillGradient are identical
        // in both schemes, so they stay static.
        return Theme(
            bg:       .dynamic(light: Color(hex: 0xfbf8f4), dark: Color(hex: 0x0c0d12)),
            bgPanel:  .dynamic(light: .white,               dark: Color(hex: 0x15161c)),
            bgWidget: .dynamic(light: .white,               dark: Color(hex: 0x1c1f27)),
            bgChip:   .dynamic(light: Color(hex: 0xf1ede5), dark: Color(hex: 0x16181f)),
            fg:       .dynamic(light: Color(hex: 0x1a0e08), dark: Color(hex: 0xf5f1ec)),
            fgMute:   .dynamic(light: Color(hex: 0x6e655c), dark: Color(hex: 0x8d8a96)),
            fgFaint:  .dynamic(light: Color(hex: 0xa8a097), dark: Color(hex: 0x56545e)),
            hairline: .dynamic(light: Color(hex: 0xece4d8), dark: Color(hex: 0x272832)),
            accent: accent,
            accentDeep: accentDeep,
            pillGradient: pillGradient,
            pillOff:  .dynamic(light: Color(hex: 0xe6dfd5), dark: Color(hex: 0x1d1f27)),
            onAccent: .white
        )
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// A color that resolves its light/dark variant from the active
    /// `UITraitCollection` at render time — including the off-screen passes
    /// iOS uses to cache the light *and* dark App Switcher snapshots. A
    /// value chosen up front from a stored bool can't track that, because
    /// the OS toggles the trait, not our state — which is exactly what left
    /// the cached card stuck in the wrong appearance.
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
