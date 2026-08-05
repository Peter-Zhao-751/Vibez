import Testing
import CoreGraphics
@testable import VibezHUDApp

// A 14" MacBook Pro: 1512x982 points, 32pt safe-area top, notch ~200pt wide.
private let mbp = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
    auxRight: CGRect(x: 856, y: 950, width: 656, height: 32))

// An external display: no notch, no auxiliary areas.
private let external = ScreenMetrics(
    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
    safeAreaTopInset: 0, auxLeft: .zero, auxRight: .zero)

@Test func derivesTheNotchFromTheAuxiliaryAreas() {
    let g = NotchGeometry(metrics: mbp)
    #expect(g.hasNotch)
    #expect(g.notchRect.width == 200)          // 1512 - 656 - 656
    #expect(g.notchRect.height == 32)
    #expect(g.notchRect.minX == 656)
    #expect(g.notchRect.maxY == 982)           // flush with the top edge
}

@Test func fallsBackToACenteredPillWithoutANotch() {
    let g = NotchGeometry(metrics: external)
    #expect(!g.hasNotch)
    #expect(g.notchRect.width == NotchGeometry.fallbackPillWidth)
    #expect(g.notchRect.maxY == 1440)
    #expect(g.notchRect.midX == external.frame.midX)
}

@Test func theHoverZoneIsForgivinglyLargerThanTheNotch() {
    let g = NotchGeometry(metrics: mbp)
    #expect(g.hoverRect.width > g.notchRect.width)
    #expect(g.hoverRect.minY < g.notchRect.minY)      // extends downward
    #expect(g.hoverRect.contains(CGPoint(x: g.notchRect.midX, y: g.notchRect.midY)))
}

/// The notch is a HOLE. You cannot point at it, so people aim just under it and
/// stop — and with only 6pt of depth below the island that landed in dead space
/// and nothing happened ("sometimes it doesn't activate"). The zone now reaches
/// a menu-bar's height below the island's bottom edge.
@Test func theHoverZoneReachesWellBelowTheIslandsBottomEdge() {
    let g = NotchGeometry(metrics: mbp)
    let islandBottom = g.notchRect.minY          // the collapsed island IS notch-height
    #expect(islandBottom - g.hoverRect.minY >= 24)
    // A pointer parked 20pt under the notch — the exact miss the user described.
    #expect(g.hoverRect.contains(CGPoint(x: g.notchRect.midX, y: islandBottom - 20)))
    // ...but it does not creep so far down that it owns a chunk of the desktop.
    #expect(!g.hoverRect.contains(CGPoint(x: g.notchRect.midX, y: islandBottom - 40)))
}

/// Depth is forgiveness; WIDTH is not, and must not have grown with it. The
/// menu-bar items and the status items start where the auxiliary areas do.
@Test func theDeeperZoneDidNotGetWiderAndStillClearsTheMenuBar() {
    let g = NotchGeometry(metrics: mbp)
    #expect(g.hoverRect.width == g.notchRect.width + 88)
    #expect(g.hoverRect.minX > mbp.auxLeft.minX)
    #expect(g.hoverRect.maxX < mbp.auxRight.maxX)
}

@Test func theBubbleIsCappedAndCentered() {
    let g = NotchGeometry(metrics: mbp)
    let small = g.bubbleRect(rowCount: 2)
    let huge = g.bubbleRect(rowCount: 500)
    #expect(huge.height <= mbp.frame.height * 0.62 + 0.001)
    #expect(huge.height >= small.height)
    #expect(huge.width <= 1040)
    #expect(abs(huge.midX - mbp.frame.midX) < 0.001)
    #expect(huge.maxY == mbp.frame.maxY, "the bubble must start at the screen's top edge")
    #expect(huge.width > g.notchRect.width, "must be wider than the notch to swallow it")
}

@Test func aNarrowScreenNeverProducesABubbleWiderThanItself() {
    let tiny = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 900, height: 600),
                             safeAreaTopInset: 0, auxLeft: .zero, auxRight: .zero)
    let g = NotchGeometry(metrics: tiny)
    #expect(g.bubbleRect(rowCount: 10).width <= 900)
}
