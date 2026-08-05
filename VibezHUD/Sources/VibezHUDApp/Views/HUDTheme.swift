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

    // The island is PURE black in both appearances, with nothing layered over
    // it: it is the Dynamic Island, and the island is black on iPhone regardless
    // of light/dark. Anything translucent — glass, a material, a specular
    // gradient, a rim stroke — reads grey next to the real notch and exposes the
    // seam, which is exactly what the first build got wrong.
    static let islandFill = Color.black
    static let tileFill = Color.white.opacity(0.075)
    /// One height for every tile in every column.
    ///
    /// MEASURED, not guessed: unconstrained, the three-line variant (chip +
    /// project, title, detail) renders 63.0pt and the two-line variant 48.0pt —
    /// a 15pt gap, which is exactly the raggedness across columns the user
    /// screenshotted. 63 is the taller of the two, so nothing is ever clipped
    /// and short tiles carry theempty space. `--verify-pixels` re-measures both.
    static let tileHeight: CGFloat = 63
    static let tileSpacing: CGFloat = 7
    static let tileStroke = Color.white.opacity(0.085)
    static let expandedCornerRadius: CGFloat = 30
    /// Matches the notch's own bottom-corner radius, so the resting island's
    /// silhouette is the notch's silhouette.
    static let collapsedCornerRadius: CGFloat = 13

    /// The whole morph, start to settled. MEASURED, not guessed: the previous
    /// `spring(response: 0.42, dampingFraction: 0.78)` sailed 12.5pt past its
    /// width target at t=505ms and then drifted back for another 170ms — 672ms
    /// of motion in two visibly distinct movements, which is what "it pops up
    /// twice" was describing. `bounce: 0` cannot overshoot at all.
    static let morphDuration: Double = 0.24
    /// ASYMMETRIC on purpose. A big slab shrinking reads slower than the same
    /// slab growing — the eye tracks the leading edge, and on the way out it is
    /// travelling toward a place the user has already stopped looking. 0.20
    /// against 0.24 measures as barely different and feels noticeably crisper.
    static let collapseDuration: Double = 0.20
    static let expand = Animation.spring(duration: morphDuration, bounce: 0)
    static let collapse = Animation.spring(duration: collapseDuration, bounce: 0)
    static let expandDescription = "spring(duration: 0.24 out / 0.20 back, bounce: 0)"
    /// The board arrives INSIDE the morph, not after it: at 0.09 + 0.14 it is
    /// fully in by 0.23s, before the shape settles at 0.28s, so the eye sees one
    /// event rather than a slab followed by its contents.
    static let contentFadeDelay: Double = 0.09
    static let contentFadeDuration: Double = 0.14
}
