import SwiftUI
import AppKit
import VibezSessionKit

enum HUDTheme {
    // Set from the Task 1 spike result: `.statusBar + 2` measured as layer 27,
    // above the menu bar (Window Server, 24) and its extras (Control Center, 25).
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    // Apple dark-mode system colors. Each means exactly one thing: state.
    static let needsYou = Color(red: 1.00, green: 0.62, blue: 0.04)   // #FF9F0A
    static let done     = Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158
    static let working  = Color(red: 0.39, green: 0.82, blue: 1.00)   // #64D2FF  teal, not blue —
                                                                      // deliberately unlike Codex's brand blue
    static let ended    = Color(red: 0.60, green: 0.60, blue: 0.62)   // #98989D

    // Agent brand chips — the same colors as the phone app, shield and extension.
    static func chip(_ agent: AgentTag) -> Color {
        switch agent {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)    // #d97757
        case .codex:  Color(red: 0.29,  green: 0.48,  blue: 1.00)     // #4A7AFF
        case .cursor: Color(red: 0.647, green: 0.647, blue: 0.725)    // #A5A5B9
        }
    }

    static func glyph(_ agent: AgentTag) -> String {
        switch agent { case .claude: "✳"; case .codex: "◆"; case .cursor: "▲" }
    }

    // The bubble is opaque black in BOTH appearances: it is the Dynamic Island,
    // and the island is black on iPhone regardless of light/dark. A light bubble
    // exposes the seam against the black notch and kills the illusion.
    static let bubbleFill = Color.black
    static let tileFill = Color.white.opacity(0.075)
    static let tileStroke = Color.white.opacity(0.085)
    static let bubbleCornerRadius: CGFloat = 30
    static let earCornerRadius: CGFloat = 10

    static let expand = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let contentFadeDelay: Double = 0.16
}
