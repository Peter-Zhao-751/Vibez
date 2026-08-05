import SwiftUI

/// The collapsed island's arithmetic, pure so the sizes can be asserted without
/// a screen. Every number here is a LAYOUT number: the flanks are sized from
/// these, never from whatever the text engine happens to measure, so the black
/// shape's width is knowable before it is drawn.
enum IslandMetrics {
    /// WHAT the resting island says: how many things are blocked on you, and how
    /// many have finished. Not what is running — a working agent needs nothing
    /// from the user, so it earns no space in the menu bar. The consequence is
    /// deliberate and should not be "fixed": a machine with three agents busy
    /// and nothing waiting shows a bare notch. That is the quiet state working.
    ///
    /// Two bare dots turned out to say too little — a dot answers "any?" when
    /// the question is "how many?" — so the counts are back, at 30pt a flank
    /// rather than the 40pt the first attempt cost.
    static let dotDiameter: CGFloat = 6
    /// Between the dot and the number it sits on top of.
    static let dotGap: CGFloat = 2
    static let flankPadding: CGFloat = 5
    /// Advance of one monospaced digit at `countFontSize`. Monospaced so a count
    /// ticking 9 -> 10 changes the island's width by exactly one digit and never
    /// by a fraction of one.
    static let digitWidth: CGFloat = 6.2
    static let countFontSize: CGFloat = 10
    /// STACKED, not side by side. Read as a row, a dot-then-number flank is
    /// lopsided — the dot sits left of centre on one side and right of centre on
    /// the other, so the two flanks are not mirror images of each other. Stacked,
    /// both are symmetric about their own centre line and the island reads the
    /// same on both sides of the notch.
    static let minFlankWidth: CGFloat = 20
    /// Digits have no descender, but their line box reserves room for one, so a
    /// stack centred by layout sits visibly HIGH — measured at 1.25pt on this
    /// type. Centring is about ink, not boxes; `--verify-pixels` asserts the
    /// corrected result lands on 0.00pt.
    static let stackInkNudge: CGFloat = 1.25

    /// Zero means GONE, not narrow: a flank with nothing to say contributes no
    /// width at all, which is what lets the quiet state collapse onto the notch.
    ///
    /// Intrinsic above the minimum, so a two-digit count widens the flank rather
    /// than being clipped — "12" must not render as "1".
    static func flankWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let digits = CGFloat(String(count).count)
        return max(minFlankWidth, flankPadding * 2 + digitWidth * digits)
    }

    /// The collapsed island is exactly the notch's height and the notch's width
    /// plus whatever the two flanks need. With both counts at zero it IS the
    /// notch rect — black on black, invisible, which is the resting state.
    static func collapsedSize(needsYou: Int, done: Int, notchSize: CGSize) -> CGSize {
        CGSize(width: notchSize.width + flankWidth(count: needsYou) + flankWidth(count: done),
               height: notchSize.height)
    }

    /// How far the island's centre has to move off the notch's centre so that the
    /// notch-width band in the middle of the shape still lands ON the notch.
    ///
    /// The flanks are independent — one can be present while the other is not —
    /// so a shape that is merely centred would slide its left flank over the
    /// physical cutout and lose the count into it.
    static func centerOffset(needsYou: Int, done: Int) -> CGFloat {
        (flankWidth(count: done) - flankWidth(count: needsYou)) / 2
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
    let done: Int
    let isExpanded: Bool
    let notchSize: CGSize
    let bubbleSize: CGSize
    /// Vertical correction for the collapsed flanks. Non-zero only when the menu
    /// bar is hidden — see `HUDViewModel.menuBarHidden`.
    var flankYNudge: CGFloat = 0
    @ViewBuilder var board: () -> Board

    private var collapsedSize: CGSize {
        IslandMetrics.collapsedSize(needsYou: needsYou, done: done, notchSize: notchSize)
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
        .offset(x: isExpanded ? 0 : IslandMetrics.centerOffset(needsYou: needsYou, done: done))
        // Resolved from the NEW state, so growing uses the expand curve and
        // shrinking uses the shorter collapse one.
        .animation(isExpanded ? HUDTheme.expand : HUDTheme.collapse, value: isExpanded)
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
            flank(count: done, color: HUDTheme.done)
        }
        .frame(width: collapsedSize.width, height: collapsedSize.height)
        // Applied to the CONTENT, not the shape: the black island still has to
        // line up with the hardware notch in every mode. Only the ink moves.
        .offset(y: flankYNudge)
    }

    /// A dot ABOVE a number. Amber on the left for what is blocked on you, green
    /// on the right for what has finished — the same two colours, and the same
    /// two counts, as the expanded columns' headers, so hovering confirms the
    /// glance instead of restating it differently.
    ///
    /// Static, like everything else here. A dot that pulses in the corner of
    /// every screen forever is not ambience, it is a fidget spinner.
    @ViewBuilder
    private func flank(count: Int, color: Color) -> some View {
        if count > 0 {
            VStack(spacing: IslandMetrics.dotGap) {
                Circle().fill(color)
                    .frame(width: IslandMetrics.dotDiameter, height: IslandMetrics.dotDiameter)
                Text("\(count)")
                    .font(.system(size: IslandMetrics.countFontSize,
                                  weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            .offset(y: IslandMetrics.stackInkNudge)
            // Centred in the FULL notch height, which is what puts the ink on
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
