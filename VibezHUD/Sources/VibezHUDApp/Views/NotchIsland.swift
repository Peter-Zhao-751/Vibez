import SwiftUI

/// The collapsed island's arithmetic, pure so the sizes can be asserted without
/// a screen. Every number here is a LAYOUT number: the flanks are sized from
/// these, never from whatever the text engine happens to measure, so the black
/// shape's width is knowable before it is drawn.
enum IslandMetrics {
    /// One dot, and nothing else.
    ///
    /// The flanks used to carry a dot AND the count, which made the resting
    /// island a wide pill hanging off both sides of the notch — legible, but
    /// nothing like "the notch, grown a whisker". A count is a number you read;
    /// a dot is a thing you notice. The numbers still exist one hover away, in
    /// the expanded column headers, where there is room for them.
    static let dotDiameter: CGFloat = 6
    /// Breathing room on each side of the dot. 5 + 6 + 5 = 16pt per flank,
    /// against the 40pt a single-digit flank used to cost.
    static let dotPadding: CGFloat = 5

    /// Zero means GONE, not narrow: a flank with nothing to say contributes no
    /// width at all, which is what lets the quiet state collapse onto the notch.
    static func flankWidth(count: Int) -> CGFloat {
        count > 0 ? dotPadding * 2 + dotDiameter : 0
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
/// The fill is `Color.black` and NOTHING else — no material, no glass, no
/// specular gradient, no rim, and no drop shadow. The shadow was the "glow" the
/// user saw: a soft dark bloom spreading 30pt out of a black slab reads as a
/// halo, not as depth. The hardware island has a hard edge, so this one does
/// too. `--verify-pixels` composites the island over mid-grey and asserts the
/// pixels just outside its edge are the background EXACTLY.
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
        // Test seam, nil in production: `--verify-morph` reads the INTERPOLATED
        // size here, once per rendered frame, which is the only way to say
        // anything factual about how the morph actually moves.
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { IslandSizeProbe.sink?($0) })
        .background(HUDTheme.islandFill)
        .clipShape(shape)
        .offset(x: isExpanded ? 0 : IslandMetrics.centerOffset(needsYou: needsYou, working: working))
        .animation(HUDTheme.expand, value: isExpanded)
    }

    /// The content trails the shape: it fades in only once the growth is under
    /// way, and leaves quickly so it never lingers outside a shrinking shape.
    private var contentFade: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: HUDTheme.contentFadeDuration)
                .delay(HUDTheme.contentFadeDelay)),
            removal: .opacity.animation(.easeOut(duration: 0.09)))
    }

    // MARK: - Collapsed content

    private var flanks: some View {
        HStack(spacing: 0) {
            flank(count: needsYou, color: HUDTheme.needsYou)
            // The notch itself: a hole in the layout, so nothing is ever drawn
            // into the physical cutout.
            Color.clear.frame(width: notchSize.width, height: collapsedSize.height)
            flank(count: working, color: HUDTheme.working)
        }
        .frame(width: collapsedSize.width, height: collapsedSize.height)
    }

    /// A single dot, present or absent. Colour carries the meaning — amber for
    /// waiting on you, teal for still working — and its presence carries the
    /// only quantity the resting state needs: any, or none.
    ///
    /// Static, like everything else here. A dot that pulses in the corner of
    /// every screen forever is not ambience, it is a fidget spinner.
    @ViewBuilder
    private func flank(count: Int, color: Color) -> some View {
        if count > 0 {
            Circle().fill(color)
                .frame(width: IslandMetrics.dotDiameter, height: IslandMetrics.dotDiameter)
                // Centred in the FULL notch height, which is what puts the dot on
                // the notch's own centre line instead of a few points above it.
                .frame(width: IslandMetrics.flankWidth(count: count), height: collapsedSize.height)
        }
    }
}

/// Where `--verify-morph` taps the island's interpolated frame. Nil in
/// production, and the island's only cost for it is one optional call per
/// layout pass — the same shape of seam as `NotchWindowController.pointerSource`.
@MainActor
enum IslandSizeProbe {
    static var sink: ((CGSize) -> Void)?
}
