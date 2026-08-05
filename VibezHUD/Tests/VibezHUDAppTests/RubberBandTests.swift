import Testing
import CoreGraphics
@testable import VibezHUDApp

private let limit: CGFloat = 14

@Test func zeroDragIsZeroOffset() {
    #expect(RubberBand.offset(for: .zero, limit: limit) == .zero)
    #expect(RubberBand.stretch(0, limit: limit) == 0)
}

@Test func smallDragsFollowThePointerNearlyOneToOne() {
    // Slope 1 at the origin: a 1pt drag moves the bubble ~0.93pt — honest,
    // not mushy, at the start of the pull.
    let s = RubberBand.stretch(1, limit: limit)
    #expect(s > 0.9 && s <= 1.0)
}

@Test func theBubbleCanNeverPassTheLimit() {
    #expect(RubberBand.stretch(50, limit: limit) < limit)
    #expect(RubberBand.stretch(10_000, limit: limit) < limit)
    // Per-axis contract: each COMPONENT stays inside its limit (the walls are
    // axis-aligned; a diagonal's magnitude may legitimately exceed one axis's
    // limit while touching neither wall).
    let huge = RubberBand.offset(for: CGSize(width: -9_000, height: 7_000), limit: limit)
    #expect(abs(huge.width) < limit && abs(huge.height) < limit)
}

@Test func resistanceGrowsTheFurtherYouPull() {
    // The marginal give per extra point of drag must shrink monotonically —
    // that IS the "more resistance the closer you get" the user asked for.
    let early = RubberBand.stretch(12, limit: limit) - RubberBand.stretch(10, limit: limit)
    let late = RubberBand.stretch(102, limit: limit) - RubberBand.stretch(100, limit: limit)
    #expect(early > late)
    #expect(late > 0)                       // still monotonic, never dead
}

@Test func signsArePreservedPerAxis() {
    let t = CGSize(width: -30, height: 40)
    let o = RubberBand.offset(for: t, limit: limit)
    #expect(o.width < 0 && o.height > 0)
}

/// Anisotropic form: each axis obeys ITS OWN asymptote — the walls are
/// axis-aligned, so this is the actual constraint. A sideways drag can never
/// carry a bubble into a wall no matter how the pull is angled.
@Test func eachAxisObeysItsOwnLimit() {
    let o = RubberBand.offset(for: CGSize(width: 5_000, height: -5_000),
                              horizontalLimit: 9, verticalLimit: 14)
    #expect(o.width < 9)
    #expect(o.height > -14)
    #expect(o.width > 8.9 && o.height < -13.9, "a huge pull gets arbitrarily close")
}

/// The style limits point the never-touch rule at the right walls:
/// a panel cell stops a pixel short of the grey outline, a card a pixel
/// short of the neighboring column.
@Test func styleLimitsMatchTheirBoundaries() {
    #expect(TileStyle.panelCell.horizontalDragLimit
            == HUDTheme.sectionPadding - HUDTheme.bubbleMinGap)
    #expect(TileStyle.doneCard.horizontalDragLimit
            == HUDTheme.columnSpacing - HUDTheme.bubbleMinGap)
    #expect(TileStyle.workingCard.horizontalDragLimit
            == HUDTheme.columnSpacing - HUDTheme.bubbleMinGap)
    // Strictly inside the container/gap, so the clip can never bite.
    #expect(TileStyle.panelCell.horizontalDragLimit < HUDTheme.sectionPadding)
    #expect(TileStyle.workingCard.horizontalDragLimit < HUDTheme.columnSpacing)
}
