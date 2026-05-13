//
//  Theme.swift
//  Vibez
//
//  Color palette and agent → accent mapping. Translated 1:1 from the
//  reference design's `themeFor(agent, dark)` JS function.
//

import SwiftUI
import UIKit

enum Agent: String, CaseIterable, Identifiable {
    case claude
    case both
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .both: "your agents"
        case .codex: "Codex"
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

    /// Override the window's userInterfaceStyle directly via UIKit.
    /// SwiftUI's `.preferredColorScheme(nil)` doesn't reliably revert
    /// a prior override — the window stays at the last explicit value.
    /// Setting `overrideUserInterfaceStyle = .unspecified` is the only
    /// way to *unstick* it back to the OS preference.
    @MainActor
    func applyToWindows() {
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light:  .light
        case .dark:   .dark
        }
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.overrideUserInterfaceStyle = style }
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
    let pillOff: Color
    let knobBg: Color
    let onAccent: Color

    static let claudeOrange = Color(hex: 0xdd7a52)
    static let claudeDeep   = Color(hex: 0xb85a36)
    static let codexBlue    = Color(hex: 0x8c9ce8)
    static let codexDeep    = Color(hex: 0x5d6fbc)

    static func make(agent: Agent, dark: Bool) -> Theme {
        let accent: Color
        let accentDeep: Color
        switch agent {
        case .claude:
            accent = claudeOrange
            accentDeep = claudeDeep
        case .codex:
            accent = codexBlue
            accentDeep = codexDeep
        case .both:
            accent = .lerp(claudeOrange, codexBlue, t: 0.5)
            accentDeep = .lerp(claudeDeep, codexDeep, t: 0.5)
        }

        let pillGradient: LinearGradient = {
            let stops: [Color] = (agent == .both)
                ? [claudeOrange, codexBlue]
                : [accent, accentDeep]
            return LinearGradient(
                colors: stops,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }()

        if dark {
            return Theme(
                bg: Color(hex: 0x0c0d12),
                bgPanel: Color(hex: 0x15161c),
                bgWidget: Color(hex: 0x1f2027),
                bgChip: Color(hex: 0x1d1f27),
                fg: Color(hex: 0xf5f1ec),
                fgMute: Color(hex: 0x8d8a96),
                fgFaint: Color(hex: 0x56545e),
                hairline: Color(hex: 0x272832),
                accent: accent,
                accentDeep: accentDeep,
                pillGradient: pillGradient,
                pillOff: Color(hex: 0x1d1f27),
                knobBg: Color(hex: 0x0e0f14),
                onAccent: .white
            )
        }
        return Theme(
            bg: Color(hex: 0xfbf8f4),
            bgPanel: .white,
            bgWidget: Color(hex: 0xe4dfd6),
            bgChip: Color(hex: 0xf1ede5),
            fg: Color(hex: 0x1a0e08),
            fgMute: Color(hex: 0x6e655c),
            fgFaint: Color(hex: 0xa8a097),
            hairline: Color(hex: 0xece4d8),
            accent: accent,
            accentDeep: accentDeep,
            pillGradient: pillGradient,
            pillOff: Color(hex: 0xe6dfd5),
            knobBg: .white,
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

    static func lerp(_ a: Color, _ b: Color, t: Double) -> Color {
        let aC = a.resolve(in: .init())
        let bC = b.resolve(in: .init())
        return Color(
            red: Double(aC.red) + (Double(bC.red) - Double(aC.red)) * t,
            green: Double(aC.green) + (Double(bC.green) - Double(aC.green)) * t,
            blue: Double(aC.blue) + (Double(bC.blue) - Double(aC.blue)) * t
        )
    }
}
