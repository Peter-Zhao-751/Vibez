import AppKit

/// `--verify-warp`: the production path, end to end, with the REAL cursor.
///
/// `--verify-hover` replaces `pointerSource`, so it proves the routing but never
/// touches `NSEvent.mouseLocation` — and "moving the mouse away does nothing"
/// is precisely a bug that a scripted pointer cannot see. This harness overrides
/// nothing: it warps the physical cursor with `CGWarpMouseCursorPosition` (which
/// needs no Accessibility grant) and then just waits, so every transition below
/// is produced by the same 20 Hz poll that runs in production, reading the same
/// class property.
///
/// It clicks nothing. That is the point: the user should never have to.
@MainActor
enum WarpVerification {
    private static var failures = 0

    static func run(controller c: NotchWindowController, model: HUDViewModel) async {
        let g = c.debugGeometry
        let screen = g.metrics.frame
        let island = c.expandedIslandRect
        let notch = CGPoint(x: g.notchRect.midX, y: g.notchRect.midY)
        let center = CGPoint(x: screen.midX, y: screen.midY)
        // Inside the PANEL, below the visible black slab and past the edge
        // forgiveness — the first place a user pulling away from the HUD lands.
        let belowIsland = CGPoint(x: island.midX, y: island.minY - 20)
        let farBelow = CGPoint(x: island.midX, y: island.minY - 200)
        let zone = NotchHoverRouter.activeZone(isExpanded: true, hoverRect: g.hoverRect,
                                               expandedRect: island)

        line("screen        \(fmt(screen))")
        line("panel.frame   \(fmt(c.panel.frame))")
        line("island (expanded, visible)  \(fmt(island))")
        line("active zone (expanded)       \(fmt(zone))")
        line("belowIsland   \(fmtP(belowIsland))  insidePanel=\(c.panel.frame.contains(belowIsland)) "
             + "insideIsland=\(island.contains(belowIsland))")
        line("")
        // The window must cover every point the HUD claims clicks for, or a row
        // near the edge would be mouse-opaque in name only.
        check("the window contains the whole expanded active zone",
              c.panel.frame.insetBy(dx: -0.5, dy: -0.5).contains(zone.intersection(screen)))
        check("precondition: belowIsland is inside the WINDOW but off the island",
              c.panel.frame.contains(belowIsland) && !island.contains(belowIsland))

        let restore = NSEvent.mouseLocation
        defer { CGWarpMouseCursorPosition(toCG(restore)) }

        await warp(to: center, settle: 700)
        check("resting: collapsed, click-through",
              model.isExpanded == false && c.panel.ignoresMouseEvents == true)

        // 1. Entry, by hovering only.
        await warp(to: notch, settle: 500)
        check("moving the real cursor onto the notch EXPANDS it — no click",
              model.isExpanded == true)
        check("...and the panel is mouse-opaque there", c.panel.ignoresMouseEvents == false)

        // 2. THE REPORTED BUG. Pull away from the slab, still inside the window.
        await warp(to: belowIsland, settle: 700)
        check("moving the cursor just OFF the visible island collapses it  "
              + "[expanded=\(model.isExpanded)]", model.isExpanded == false)
        check("...and restores click-through", c.panel.ignoresMouseEvents == true)

        await warp(to: notch, settle: 500)
        check("re-entry after that still expands", model.isExpanded == true)
        await warp(to: farBelow, settle: 700)
        check("and pulling well clear of it collapses it too", model.isExpanded == false)

        // 3. And the unambiguous case.
        await warp(to: notch, settle: 500)
        check("re-entry expands again", model.isExpanded == true)
        await warp(to: center, settle: 700)
        check("moving to the middle of the screen collapses it", model.isExpanded == false)

        // 4. Exactly once: re-entering must not leave a stale expansion behind.
        await warp(to: notch, settle: 500)
        check("third entry still expands", model.isExpanded == true)
        await warp(to: center, settle: 700)
        check("third exit still collapses", model.isExpanded == false)

        line("")
        if failures == 0 { line("WARP VERIFY: PASS"); exit(0) }
        line("WARP VERIFY: \(failures) FAILED")
        exit(1)
    }

    private static func warp(to p: CGPoint, settle ms: Int) async {
        CGWarpMouseCursorPosition(toCG(p))
        line(String(format: "   warp -> (%.0f,%.0f), wait %dms", p.x, p.y, ms))
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    /// AppKit screen space (bottom-left origin) to CoreGraphics display space.
    private static func toCG(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        line("\(ok ? "ok  " : "FAIL") \(name)")
    }
    private static func line(_ s: String) { print(s); fflush(stdout) }
    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
    private static func fmtP(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
}
