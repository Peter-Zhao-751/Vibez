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
    /// The NEEDS YOU section's grouping panel — Mail's sidebar trick: one
    /// lighter rounded slab around the whole section, header and rows together.
    ///
    /// The rows inside it are BARE (see `SessionTile.bare`): the panel is the
    /// only surface, exactly like Mail's sidebar. The first attempt kept card
    /// fills on the rows over a faint 0.055 wash, which read as "grayed-out
    /// messages" rather than a containing element — the user's words. With no
    /// cards competing, the panel itself carries the contrast: 0.09 composites
    /// to RGB 23 on black, a bigger step off the island than a card's 19, so
    /// the slab unmistakably reads as its own element.
    static let sectionFill = Color.white.opacity(0.09)
    static let sectionCornerRadius: CGFloat = 16
    /// ONE spacing unit, two places: cells-to-panel-edge equals panel-to-
    /// island-edge (boardSideMargin), uniform on every side. Tying it to the
    /// tile gap (5pt) made the cells "way too close to the side and top" —
    /// the harmony the user asked for is bubbles→panel == panel→island, with
    /// the tighter 5pt rhythm living only BETWEEN bubbles.
    static let sectionPadding: CGFloat = boardSideMargin
    /// Mail's second grey: each row inside the panel is its own lighter rounded
    /// cell, like the Inbox row's highlight in the sidebar. Two surfaces, both
    /// unmistakably deliberate: panel composites to RGB 23 on black, a cell on
    /// the panel to RGB 51 — a 28-step, close to Mail's own.
    static let panelCellFill = Color.white.opacity(0.12)
    static let panelCellRadius: CGFloat = 10
    /// Done and Working cards share ONE color — done's. Done tiles used to dim
    /// the whole tile to 48%, which made their cards darker than Working's;
    /// the user preferred that darker shade and asked for both columns to
    /// match it. So the card chrome is muted for both (7.5% x 0.48 ≈ 3.6%),
    /// and the 48% dim now applies to done/ended CONTENT only.
    /// Elastic bubble drag: how far a bubble can be pulled (asymptotic limit
    /// of the rubber-band curve) and the snap-back. The snap-back is the ONE
    /// deliberately bouncy animation in the HUD — playfulness was the point —
    /// while the island morph stays bounce-free.
    static let bubbleDragLimit: CGFloat = 14
    static let bubbleSnapBack = Animation.spring(response: 0.32, dampingFraction: 0.55)

    static let mutedCardFill = Color.white.opacity(0.036)
    /// Visible on purpose: at 0.04 the outline vanished into the fill (user:
    /// "make the outlines slightly more distinctive"). 0.10 draws RGB ~26 on
    /// the RGB 9 card — an edge you can see without the card going bright.
    static let mutedCardStroke = Color.white.opacity(0.10)
    /// Board margins. Sides and bottom are EQUAL and small — the island hugs
    /// its content Mail-style instead of trailing a black apron. Top stays
    /// larger only because the headers ride beside the notch.
    static let boardTopMargin: CGFloat = 14
    static let boardSideMargin: CGFloat = 10
    static let boardBottomMargin: CGFloat = 10
    /// One height for every tile in every column.
    ///
    /// Tightened Mail-ward from the measured 63: the three-line content fits 58
    /// with 6pt vertical padding and 3pt line spacing (lines ≈ 13+13+12 plus
    /// gaps = 47, +12 padding = 59… the intrinsic fit is re-measured by
    /// `--verify-pixels`, which fails if the tightening ever clips a line).
    /// Uniform across columns as before — short tiles carry the empty space.
    static let tileHeight: CGFloat = 58
    static let tileSpacing: CGFloat = 5
    static let tileVerticalPadding: CGFloat = 6
    static let tileLineSpacing: CGFloat = 3
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
