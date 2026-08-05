import Testing
import CoreGraphics
@testable import VibezHUDApp

private let s = HUDTheme.tileSpacing        // 5
private let m = HUDTheme.bubbleMinGap       // 2
private let L = HUDTheme.bubbleDragLimit    // 14

@Test func atRestNothingMoves() {
    let out = BubblePhysics.verticalDisplacements(count: 5, draggedIndex: 2, dragY: 0,
                                                  spacing: s, minGap: m)
    #expect(out == [0, 0, 0, 0, 0])
}

@Test func theFieldSwitchesOnGently() {
    // push'(0) = 0 — a bubble drifting NEAR a neighbor barely moves it. This
    // is the "magnetic field" onset, as opposed to a rigid link.
    #expect(BubblePhysics.push(0.5, spacing: s, minGap: m) < 0.1)
    #expect(BubblePhysics.push(0.5, spacing: s, minGap: m) > 0)
}

@Test func bubblesCanNeverTouch() {
    // Walk the entire reachable drag range and check every adjacent gap.
    // gap = spacing - |approach| + push(approach); it must stay above minGap
    // for the dragged pair AND every cascaded pair below it.
    var dy: CGFloat = 0
    while dy <= L {
        let out = BubblePhysics.verticalDisplacements(count: 6, draggedIndex: 0, dragY: dy,
                                                      spacing: s, minGap: m)
        for i in 0..<5 {
            let gap = s - out[i] + out[i + 1]
            #expect(gap > m - 0.0001, "gap \(gap) at pair \(i) under drag \(dy)")
        }
        dy += 0.25
    }
}

@Test func theRippleDecaysDownTheColumn() {
    let out = BubblePhysics.verticalDisplacements(count: 6, draggedIndex: 0, dragY: L,
                                                  spacing: s, minGap: m)
    for i in 1..<5 where out[i + 1] != 0 {
        #expect(abs(out[i]) > abs(out[i + 1]), "cascade must shrink at hop \(i)")
    }
    #expect(abs(out[1]) < L, "the first neighbor moves less than the drag itself")
}

@Test func dragUpPushesOnlyUpward() {
    let out = BubblePhysics.verticalDisplacements(count: 5, draggedIndex: 2, dragY: -L,
                                                  spacing: s, minGap: m)
    #expect(out[3] == 0 && out[4] == 0, "tiles below an upward drag never move")
    #expect(out[1] < 0, "the neighbor above is pushed up")
    #expect(out[0] <= 0)
}

@Test func horizontalDragMovesNoNeighbors() {
    // dragY == 0 means a purely sideways pull — rows can't collide sideways.
    let out = BubblePhysics.verticalDisplacements(count: 4, draggedIndex: 1, dragY: 0,
                                                  spacing: s, minGap: m)
    #expect(out == [0, 0, 0, 0])
}
