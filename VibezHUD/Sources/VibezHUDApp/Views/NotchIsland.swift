import SwiftUI

/// The collapsed island's arithmetic, pure so the sizes can be asserted without
/// a screen. Every number here is a LAYOUT number: the flanks are sized from
/// these, never from whatever the text engine happens to measure, so the black
/// shape's width is knowable before it is drawn.
enum IslandMetrics {
    /// Breathing room on each side of a flank's content.
    static let flankPadding: CGFloat = 9
    /// Both glyphs (the needs-you dot, the working bars) are drawn into a box of
    /// exactly this width, so one constant covers both flanks.
    static let glyphWidth: CGFloat = 10
    static let glyphGap: CGFloat = 5
    /// Advance of one monospaced digit at `countFontSize` — monospaced on
    /// purpose: "1" and "8" must not resize the island.
    static let digitWidth: CGFloat = 7
    static let countFontSize: CGFloat = 11

    /// Zero means GONE, not narrow: a flank with nothing to say contributes no
    /// width at all, which is what lets the quiet state collapse onto the notch.
    static func flankWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let digits = CGFloat(String(count).count)
        return flankPadding * 2 + glyphWidth + glyphGap + digitWidth * digits
    }

    /// The collapsed island is exactly the notch's height and the notch's width
    /// plus whatever the two flanks need. With both counts at zero it IS the
    /// notch rect — black on black, invisible, which is the resting state.
    static func collapsedSize(needsYou: Int, working: Int, notchSize: CGSize) -> CGSize {
        CGSize(width: notchSize.width + flankWidth(count: needsYou) + flankWidth(count: working),
               height: notchSize.height)
    }

    /// How far the island's centre has to move off the notch's centre so that the
    /// notch-width band in the middle of the shape still lands ON the notch.
    ///
    /// The flanks are independent — one can be present while the other is not —
    /// so a shape that is merely centred would slide its left flank over the
    /// physical cutout and lose the count into it.
    static func centerOffset(needsYou: Int, working: Int) -> CGFloat {
        (flankWidth(count: working) - flankWidth(count: needsYou)) / 2
    }
}

/// ONE black shape, always present, anchored to the top of the screen — the
/// collapsed island and the expanded board are the same object at two sizes.
/// Hovering does not swap one view for another; it grows this one out of the
/// notch's own footprint, which is the whole "it pops out of the notch" feel.
///
/// The fill is `Color.black` and nothing else. No material, no glass, no
/// specular gradient, no rim: any of those read as grey against the real notch
/// and give the illusion away. The only thing outside the fill is the drop
/// shadow, and that is expanded-only — a shadow around the resting island would
/// halo the wallpaper around a shape that is supposed to be invisible.
struct NotchIsland<Board: View>: View {
    let needsYou: Int
    let working: Int
    let isExpanded: Bool
    let notchSize: CGSize
    let bubbleSize: CGSize
    @ViewBuilder var board: () -> Board

    private var collapsedSize: CGSize {
        IslandMetrics.collapsedSize(needsYou: needsYou, working: working, notchSize: notchSize)
    }
    private var size: CGSize { isExpanded ? bubbleSize : collapsedSize }
    private var cornerRadius: CGFloat {
        isExpanded ? HUDTheme.expandedCornerRadius : HUDTheme.collapsedCornerRadius
    }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                // Mounted, not merely faded: `board()` is where the view model's
                // second-by-second clock is read, and an unmounted board reads
                // nothing — so a collapsed HUD still never re-renders on the clock.
                board()
                    .frame(width: bubbleSize.width, height: bubbleSize.height, alignment: .top)
                    .transition(contentFade)
            } else {
                flanks.transition(contentFade)
            }
        }
        // The frame is the morph. Everything overflowing it — the board while the
        // shape is still notch-sized — is clipped by the shape below.
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(HUDTheme.islandFill)
        .clipShape(shape)
        .shadow(color: .black.opacity(isExpanded ? 0.55 : 0), radius: 30, y: 18)
        .offset(x: isExpanded ? 0 : IslandMetrics.centerOffset(needsYou: needsYou, working: working))
        .animation(HUDTheme.expand, value: isExpanded)
    }

    /// The content trails the shape: it fades in only once the growth is under
    /// way, and leaves quickly so it never lingers outside a shrinking shape.
    private var contentFade: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.16).delay(HUDTheme.contentFadeDelay)),
            removal: .opacity.animation(.easeOut(duration: 0.10)))
    }

    // MARK: - Collapsed content

    private var flanks: some View {
        HStack(spacing: 0) {
            flank(count: needsYou) { needsYouGlyph }
            // The notch itself: a hole in the layout, so nothing is ever drawn
            // into the physical cutout.
            Color.clear.frame(width: notchSize.width, height: collapsedSize.height)
            flank(count: working) { workingGlyph }
        }
        .frame(width: collapsedSize.width, height: collapsedSize.height)
    }

    /// White on black is legible over any wallpaper — that is the entire reason
    /// the counts live inside the black shape instead of on a glass ear.
    @ViewBuilder
    private func flank<G: View>(count: Int, @ViewBuilder glyph: () -> G) -> some View {
        if count > 0 {
            HStack(spacing: IslandMetrics.glyphGap) {
                glyph().frame(width: IslandMetrics.glyphWidth)
                Text("\(count)")
                    .font(.system(size: IslandMetrics.countFontSize, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            // Centred in the FULL notch height, which is what puts the ink on the
            // notch's own centre line instead of a few points above it.
            .frame(width: IslandMetrics.flankWidth(count: count), height: collapsedSize.height)
        }
    }

    // Both glyphs are static. Nothing on this surface animates while the machine
    // is idle: a pulsing dot and a dancing equaliser in the corner of every
    // screen, forever, is not ambience, it is a fidget spinner.
    private var needsYouGlyph: some View {
        Circle().fill(HUDTheme.needsYou).frame(width: 7, height: 7)
    }

    private var workingGlyph: some View {
        HStack(alignment: .center, spacing: 2) {
            bar(5); bar(9); bar(6)
        }
    }

    private func bar(_ height: CGFloat) -> some View {
        Capsule().fill(HUDTheme.working).frame(width: 2, height: height)
    }
}
