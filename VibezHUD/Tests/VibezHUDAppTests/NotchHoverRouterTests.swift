import Testing
import CoreGraphics
@testable import VibezHUDApp

// A 14" MacBook Pro, matching NotchGeometryTests.
private let mbp = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
    auxRight: CGRect(x: 856, y: 950, width: 656, height: 32))

private let geo = NotchGeometry(metrics: mbp)

/// What the controller actually installs: the bubble rect widened by 60pt a side
/// with 20pt of shadow slack below. Roughly 1160x470 on this screen.
private var panelFrame: CGRect {
    let r = geo.bubbleRect(rowCount: 6)
    let padded = r.insetBy(dx: -60, dy: 0)
    return CGRect(x: padded.minX, y: padded.minY - 20, width: padded.width, height: r.height + 20)
}

private func route(_ p: CGPoint, expanded: Bool) -> HoverInput {
    NotchHoverRouter.route(pointer: p, isExpanded: expanded,
                           hoverRect: geo.hoverRect, panelFrame: panelFrame)
}

@Test func collapsedOnlyTheNotchHotSpotCounts() {
    #expect(route(CGPoint(x: geo.notchRect.midX, y: geo.notchRect.midY), expanded: false) == .entered)
    #expect(route(CGPoint(x: geo.hoverRect.minX + 1, y: geo.hoverRect.midY), expanded: false) == .entered)
}

/// The regression this whole fix exists for: a menu-bar point that the panel
/// covers, but that is nowhere near the notch, must NOT count as hover — and
/// must therefore leave the panel click-through.
@Test func collapsedIgnoresMenuBarPointsThePanelHappensToCover() {
    let menuBarLeft = CGPoint(x: 220, y: geo.notchRect.midY)
    #expect(panelFrame.contains(menuBarLeft), "precondition: the panel really does cover this point")
    #expect(!geo.hoverRect.contains(menuBarLeft))
    #expect(route(menuBarLeft, expanded: false) == .exited)
    #expect(NotchHoverRouter.ignoresMouseEvents(for: route(menuBarLeft, expanded: false)))
}

@Test func collapsedIgnoresThePanelsOwnBodyBelowTheNotch() {
    // 200pt down from the top edge: deep inside the panel, far below the notch.
    let belowNotch = CGPoint(x: geo.notchRect.midX, y: mbp.frame.maxY - 200)
    #expect(panelFrame.contains(belowNotch))
    #expect(route(belowNotch, expanded: false) == .exited)
}

@Test func expandedTheWholePanelKeepsItOpen() {
    let belowNotch = CGPoint(x: geo.notchRect.midX, y: mbp.frame.maxY - 200)
    #expect(route(belowNotch, expanded: true) == .entered)
    #expect(!NotchHoverRouter.ignoresMouseEvents(for: route(belowNotch, expanded: true)))
}

@Test func expandedStillExitsOutsideThePanel() {
    let offPanel = CGPoint(x: mbp.frame.midX, y: mbp.frame.minY + 40)
    #expect(!panelFrame.contains(offPanel))
    #expect(route(offPanel, expanded: true) == .exited)
    #expect(NotchHoverRouter.ignoresMouseEvents(for: route(offPanel, expanded: true)))
}

@Test func theActiveZoneGrowsOnlyWhenExpanded() {
    let collapsed = NotchHoverRouter.activeZone(isExpanded: false,
                                                hoverRect: geo.hoverRect, panelFrame: panelFrame)
    let expanded = NotchHoverRouter.activeZone(isExpanded: true,
                                               hoverRect: geo.hoverRect, panelFrame: panelFrame)
    #expect(collapsed == geo.hoverRect)
    #expect(expanded == panelFrame)
    #expect(expanded.width > collapsed.width)
    #expect(expanded.height > collapsed.height)
}

/// Mouse opacity is a pure function of the routing, and it must be OFF in the
/// resting state. A borderless window at layer 27 spanning the top of the
/// display swallows every menu-bar click it is opaque for.
@Test func mouseOpacityTracksRoutingExactly() {
    #expect(NotchHoverRouter.ignoresMouseEvents(for: .exited))
    #expect(!NotchHoverRouter.ignoresMouseEvents(for: .entered))
}

/// Walk the pointer across the panel while collapsed and count how much of it is
/// mouse-opaque. Before the fix the answer was "all of it".
@Test func almostNoneOfTheCollapsedPanelIsMouseOpaque() {
    var opaque = 0, total = 0
    for x in stride(from: panelFrame.minX, to: panelFrame.maxX, by: 8) {
        for y in stride(from: panelFrame.minY, to: panelFrame.maxY, by: 8) {
            total += 1
            if route(CGPoint(x: x, y: y), expanded: false) == .entered { opaque += 1 }
        }
    }
    let fraction = Double(opaque) / Double(total)
    #expect(fraction < 0.06, "collapsed hot zone covers \(fraction) of the panel")
    #expect(opaque > 0, "the notch itself must still be hoverable")
}

/// The hot zone must not spill past the notch far enough to reach the menu-bar
/// items or the status items, which start right where the aux areas do.
@Test func theHotSpotStaysWithinTheAuxiliaryGap() {
    #expect(geo.hoverRect.minX > mbp.auxLeft.minX)
    #expect(geo.hoverRect.maxX < mbp.auxRight.maxX)
    #expect(geo.hoverRect.width < 300)
}
