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

/// The VISIBLE island when expanded — the black slab the user can see.
private let islandRect = geo.bubbleRect(rowCount: 6)

/// The WINDOW that contains it, which is deliberately bigger. Keeping both here
/// is the point: routing against the window instead of the island is the bug
/// that made "move the mouse away" do nothing.
private var panelFrame: CGRect {
    let padded = islandRect.insetBy(dx: -24, dy: 0)
    return CGRect(x: padded.minX, y: padded.minY - 24,
                  width: padded.width, height: islandRect.height + 24)
}

private func route(_ p: CGPoint, expanded: Bool) -> HoverInput {
    NotchHoverRouter.route(pointer: p, isExpanded: expanded,
                           hoverRect: geo.hoverRect, expandedRect: islandRect)
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

@Test func expandedTheWholeVisibleIslandKeepsItOpen() {
    let belowNotch = CGPoint(x: geo.notchRect.midX, y: mbp.frame.maxY - 200)
    #expect(route(belowNotch, expanded: true) == .entered)
    #expect(!NotchHoverRouter.ignoresMouseEvents(for: route(belowNotch, expanded: true)))
}

@Test func expandedStillExitsOutsideTheIsland() {
    let offPanel = CGPoint(x: mbp.frame.midX, y: mbp.frame.minY + 40)
    #expect(!islandRect.contains(offPanel))
    #expect(route(offPanel, expanded: true) == .exited)
    #expect(NotchHoverRouter.ignoresMouseEvents(for: route(offPanel, expanded: true)))
}

@Test func theActiveZoneGrowsOnlyWhenExpanded() {
    let collapsed = NotchHoverRouter.activeZone(isExpanded: false,
                                                hoverRect: geo.hoverRect, expandedRect: islandRect)
    let expanded = NotchHoverRouter.activeZone(isExpanded: true,
                                               hoverRect: geo.hoverRect, expandedRect: islandRect)
    #expect(collapsed == geo.hoverRect)
    #expect(expanded == islandRect.insetBy(dx: -NotchHoverRouter.forgiveness,
                                           dy: -NotchHoverRouter.forgiveness))
    #expect(expanded.width > collapsed.width)
    #expect(expanded.height > collapsed.height)
}

/// THE ROUND-2 REGRESSION.
///
/// The window is deliberately larger than the island, and routing against the
/// window made a tall band of empty screen BELOW the visible slab count as
/// hover. The user pulled the pointer off the HUD and nothing happened; the only
/// way to dismiss it was to click somewhere else entirely. Measured on the real
/// panel with `--verify-warp` before the fix: island (236,780 1040x202) inside a
/// panel (176,512 1160x470), and (756,700) — 80pt below the slab — routed
/// `.entered`.
@Test func aPointInsideTheWindowButOffTheVisibleIslandCollapsesIt() {
    let belowIsland = CGPoint(x: islandRect.midX, y: islandRect.minY - 20)
    #expect(panelFrame.contains(belowIsland), "precondition: the window still covers it")
    #expect(!islandRect.contains(belowIsland), "precondition: the island does not")
    #expect(route(belowIsland, expanded: true) == .exited)
    #expect(NotchHoverRouter.ignoresMouseEvents(for: route(belowIsland, expanded: true)))

    // And the shape of the original bug: with the OLD, much larger window as the
    // expanded zone, that same point counted as hover. This is what changed.
    let oldStylePanel = CGRect(x: islandRect.minX - 60, y: islandRect.minY - 268,
                               width: islandRect.width + 120, height: islandRect.height + 268)
    #expect(oldStylePanel.contains(belowIsland))
    #expect(NotchHoverRouter.route(pointer: belowIsland, isExpanded: true,
                                   hoverRect: geo.hoverRect, expandedRect: oldStylePanel) == .entered,
            "routing against the window is what made the HUD undismissable")
}

/// ...but the edge is forgiving, or a pointer resting on the boundary flickers.
@Test func aWobbleJustOutsideTheEdgeIsForgiven() {
    let justBelow = CGPoint(x: islandRect.midX, y: islandRect.minY - 6)
    let wellBelow = CGPoint(x: islandRect.midX, y: islandRect.minY - 40)
    #expect(route(justBelow, expanded: true) == .entered)
    #expect(route(wellBelow, expanded: true) == .exited)
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

// MARK: - The polling overload
//
// Hover is now sampled from `NSEvent.mouseLocation` every tick instead of
// arriving on a mouse-moved monitor, and this overload is the entire hit-test
// that sampling runs through. Everything below feeds it FAKE points, which is
// the only way to state the coordinate-space contract as a test at all.

private func poll(_ p: CGPoint, expanded: Bool) -> HoverInput {
    NotchHoverRouter.route(pointer: p, isExpanded: expanded, geometry: geo, expandedRect: islandRect)
}

@Test func pollingTheNotchWhileCollapsedEntersTheHUD() {
    #expect(poll(CGPoint(x: geo.notchRect.midX, y: geo.notchRect.midY), expanded: false) == .entered)
}

@Test func pollingAnywhereElseWhileCollapsedDoesNot() {
    #expect(poll(CGPoint(x: 220, y: geo.notchRect.midY), expanded: false) == .exited)     // menu bar
    #expect(poll(CGPoint(x: mbp.frame.midX, y: mbp.frame.midY), expanded: false) == .exited)
    #expect(poll(.zero, expanded: false) == .exited)   // bottom-left corner of the display
}

@Test func pollingInsideTheIslandWhileExpandedKeepsItOpen() {
    let deepInside = CGPoint(x: islandRect.midX, y: islandRect.minY + 40)
    #expect(poll(deepInside, expanded: true) == .entered)
    #expect(poll(deepInside, expanded: false) == .exited)   // ...but only while expanded
}

/// THE Y-FLIP TRAP.
///
/// `NSEvent.mouseLocation` is AppKit screen space: origin BOTTOM-left, so the
/// notch — physically at the top of the display — is at HIGH y. CoreGraphics
/// display space is the other way up. Convert on the way in and every real hover
/// hit-tests against the bottom edge of the screen instead, which presents
/// exactly as "hover never fires" — the bug this whole change is fixing. So the
/// notch point and its flipped twin are pinned to OPPOSITE answers: no
/// implementation can satisfy both and still contain a flip.
@Test func aFlippedPointerIsNotOnTheNotchAndMustNeverRegisterAsHover() {
    let onTheNotch = CGPoint(x: geo.notchRect.midX, y: geo.notchRect.midY)
    let flipped = CGPoint(x: onTheNotch.x, y: mbp.frame.maxY - onTheNotch.y)

    #expect(onTheNotch.y > mbp.frame.midY, "precondition: the notch is at HIGH y in AppKit space")
    #expect(flipped.y < mbp.frame.midY, "precondition: its CG twin is near the bottom of the display")

    #expect(poll(onTheNotch, expanded: false) == .entered)
    #expect(poll(flipped, expanded: false) == .exited)
    // ...and the same trap while expanded: the panel is top-anchored too.
    #expect(poll(onTheNotch, expanded: true) == .entered)
    #expect(poll(flipped, expanded: true) == .exited)
}

/// The two overloads are the same function; the geometry one just spares the
/// caller a member lookup. If they ever disagree, one call site is hit-testing
/// something else.
@Test func theGeometryOverloadAgreesWithTheRectOverloadEverywhere() {
    for x in stride(from: mbp.frame.minX, to: mbp.frame.maxX, by: 37) {
        for y in stride(from: mbp.frame.minY, to: mbp.frame.maxY, by: 37) {
            for expanded in [true, false] {
                let p = CGPoint(x: x, y: y)
                #expect(poll(p, expanded: expanded) == route(p, expanded: expanded))
            }
        }
    }
}
