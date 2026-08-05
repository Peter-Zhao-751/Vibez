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
    let huge = RubberBand.offset(for: CGSize(width: -9_000, height: 7_000), limit: limit)
    #expect((huge.width * huge.width + huge.height * huge.height).squareRoot() < limit)
}

@Test func resistanceGrowsTheFurtherYouPull() {
    // The marginal give per extra point of drag must shrink monotonically —
    // that IS the "more resistance the closer you get" the user asked for.
    let early = RubberBand.stretch(12, limit: limit) - RubberBand.stretch(10, limit: limit)
    let late = RubberBand.stretch(102, limit: limit) - RubberBand.stretch(100, limit: limit)
    #expect(early > late)
    #expect(late > 0)                       // still monotonic, never dead
}

@Test func directionIsPreservedExactly() {
    let t = CGSize(width: -30, height: 40)  // 3-4-5 triangle, pointing up-left
    let o = RubberBand.offset(for: t, limit: limit)
    #expect(o.width < 0 && o.height > 0)
    // Radial application: the ratio between components survives the curve.
    #expect(abs(o.width / o.height - t.width / t.height) < 0.0001)
}
