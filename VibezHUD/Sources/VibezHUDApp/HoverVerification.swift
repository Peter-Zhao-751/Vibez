import AppKit

/// `--verify-hover`: drives the REAL panel through the REAL routing path and
/// prints what the real `NSPanel.ignoresMouseEvents` did at each step.
///
/// This exists because the claim under test — "the collapsed panel does not eat
/// menu-bar clicks" — is a claim about an AppKit window, not about a pure
/// function, and `screencapture` is unavailable here. So instead of a screenshot
/// it asserts the panel's own mouse-opacity flag at every step of a scripted
/// pointer path, and `--click-probe` additionally posts a real synthetic click
/// and counts whether the window server routed it to this process.
///
/// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` was tried first and
/// rejected: measured here it returns the same window number for every point on
/// the screen, in both coordinate conventions, so it discriminates nothing.
@MainActor
enum HoverVerification {
    private static var failures = 0
    private static var pointer = CGPoint.zero
    private static var clicksReceived = 0
    private static var controller: NotchWindowController!

    /// `--verify-pointer`: proves the coordinate space of the polling path
    /// against the LIVE cursor, rather than trusting the documentation.
    ///
    /// Hover now depends on exactly one claim — that `NSEvent.mouseLocation` and
    /// `NotchGeometry`'s rects are the same space — and a y-flip there looks
    /// identical to "the events never fire", which is the bug being fixed. So
    /// the cursor is warped onto the notch (`CGWarpMouseCursorPosition` needs no
    /// Accessibility grant; posting events would) and the routed answer is read
    /// back. The flipped twin is checked too: if it ALSO routes `.entered`, the
    /// hot zone is symmetric enough to be meaningless and the probe says so.
    static func probePointerSpace(controller c: NotchWindowController) -> Never {
        let g = c.debugGeometry
        let screen = g.metrics.frame
        line("screen        \(fmt(screen))  hasNotch=\(g.hasNotch)")
        line("notchRect     \(fmt(g.notchRect))")
        line("hoverRect     \(fmt(g.hoverRect))")
        line("panel.frame   \(fmt(c.panel.frame))")
        line("")

        let restoreTo = NSEvent.mouseLocation
        defer { warp(to: restoreTo) }
        let target = CGPoint(x: g.notchRect.midX, y: g.notchRect.midY)

        warp(to: target)
        usleep(200_000)                       // let the window server settle
        let live = NSEvent.mouseLocation
        line("warped to     \(fmtP(target))  (AppKit space, assumed bottom-left origin)")
        line("mouseLocation \(fmtP(live))")
        check("NSEvent.mouseLocation reads back the point we warped to (±2pt)",
              abs(live.x - target.x) <= 2 && abs(live.y - target.y) <= 2)
        check("...and it is near the TOP of the screen, not the bottom  "
              + "[y=\(Int(live.y)) of \(Int(screen.maxY))]",
              live.y > screen.midY)
        check("...so the live cursor hit-tests INSIDE hoverRect",
              g.hoverRect.contains(live))
        check("...and routes .entered while collapsed",
              NotchHoverRouter.route(pointer: live, isExpanded: false,
                                     geometry: g, expandedRect: c.expandedIslandRect) == .entered)

        // The trap, on real numbers: what a y-flip would have produced.
        let flipped = CGPoint(x: live.x, y: screen.maxY - live.y)
        line("flipped twin  \(fmtP(flipped))  (what a CG-space conversion would hand in)")
        check("the flipped twin routes .exited — a y-flip would kill hover outright",
              NotchHoverRouter.route(pointer: flipped, isExpanded: false,
                                     geometry: g, expandedRect: c.expandedIslandRect) == .exited)

        line("")
        if failures == 0 { line("POINTER SPACE: PASS"); exit(0) }
        line("POINTER SPACE: \(failures) FAILED")
        exit(1)
    }

    static func run(controller c: NotchWindowController, model: HUDViewModel) async {
        controller = c
        // Take the pointer away from the physical mouse: every read inside the
        // controller — including the one the expansion callback makes — now sees
        // the scripted position, so the script is not fighting the real cursor.
        c.pointerSource = { pointer }

        let g = c.debugGeometry
        let panel = c.panel
        let notchCenter = CGPoint(x: g.notchRect.midX, y: g.notchRect.midY)
        // Inside the panel, on the menu bar, nowhere near the notch. This is the
        // exact point the old whole-panel tracking area got wrong.
        let menuBarLeft = CGPoint(x: panel.frame.minX + 60, y: g.notchRect.midY)
        // Inside the VISIBLE island, not merely inside the window: those are
        // different rects, and only the first one is the HUD.
        let island = c.expandedIslandRect
        let insideBubble = CGPoint(x: island.midX, y: island.minY + 40)
        // Inside the window, BELOW the island — the round-2 bug's exact shape.
        let belowIsland = CGPoint(x: island.midX, y: island.minY - 20)
        let farAway = CGPoint(x: g.metrics.frame.midX, y: g.metrics.frame.minY + 60)

        line("screen        \(fmt(g.metrics.frame))  hasNotch=\(g.hasNotch)")
        line("notchRect     \(fmt(g.notchRect))")
        line("hoverRect     \(fmt(g.hoverRect))")
        line("panel.frame   \(fmt(panel.frame))   windowNumber=\(panel.windowNumber)")
        line("")

        // 1. Resting state, before any pointer has been seen at all.
        check("collapsed at launch is click-through", panel.ignoresMouseEvents == true)

        // 2. Pointer elsewhere on the menu bar — the old bug's blast radius.
        check("precondition: the panel really does cover this menu-bar point",
              panel.frame.contains(menuBarLeft))
        move(to: menuBarLeft)
        await settle()
        check("...yet the menu bar away from the notch stays click-through",
              panel.ignoresMouseEvents == true)
        check("...and does not expand the bubble", model.isExpanded == false)

        // 3. Pointer onto the notch: becomes mouse-opaque, then expands.
        move(to: notchCenter)
        check("entering the notch makes the panel mouse-opaque",
              panel.ignoresMouseEvents == false)
        await sleepMs(300)
        check("the bubble expands after the open delay", model.isExpanded == true)

        // 4. Down into the bubble: still on the HUD, rows must stay clickable.
        move(to: insideBubble)
        await settle()
        check("the bubble body is interactive", panel.ignoresMouseEvents == false)
        check("the bubble stays open inside its own body", model.isExpanded == true)

        // 4b. Off the slab but still inside the window: this must NOT count as
        //     hover, or the HUD cannot be dismissed by moving away from it.
        check("precondition: the window covers a point 20pt below the island",
              panel.frame.contains(belowIsland) && !island.contains(belowIsland))
        move(to: belowIsland)
        await settle()
        check("pulling off the island stops counting as hover",
              panel.ignoresMouseEvents == true)
        await sleepMs(500)
        check("...and the bubble collapses without a click", model.isExpanded == false)
        move(to: notchCenter)
        await sleepMs(300)
        check("re-entering the notch opens it again", model.isExpanded == true)
        move(to: insideBubble)
        await settle()

        // 5. Leaving: opacity drops IMMEDIATELY, before the close delay expires,
        //    so a user heading for the menu bar is never blocked by the fade-out.
        move(to: farAway)
        check("leaving restores click-through at once", panel.ignoresMouseEvents == true)
        check("...while the bubble is still visibly closing", model.isExpanded == true)

        // 6. Fully collapsed again.
        await sleepMs(600)
        check("the bubble has collapsed", model.isExpanded == false)
        check("collapsed is click-through again", panel.ignoresMouseEvents == true)

        // 7. A flick through the notch must neither open nor latch opacity on.
        move(to: notchCenter)
        await sleepMs(40)
        move(to: farAway)
        await sleepMs(300)
        check("a flick through the notch never opens", model.isExpanded == false)
        check("a flick through the notch leaves click-through restored",
              panel.ignoresMouseEvents == true)

        if CommandLine.arguments.contains("--click-probe") {
            await clickProbe(controller: c, model: model, notchCenter: notchCenter, farAway: farAway)
        }

        line("")
        if failures == 0 {
            line("HOVER VERIFY: PASS")
            exit(0)
        }
        line("HOVER VERIFY: \(failures) FAILED")
        exit(1)
    }

    /// The decisive test, opt-in because it briefly warps the physical cursor.
    ///
    /// A LOCAL event monitor sees only events macOS delivered to THIS process. So
    /// posting a synthetic click at the notch and counting what the monitor saw
    /// answers the real question — did the window server route that click to us,
    /// or straight past us to whatever is underneath — rather than restating the
    /// flag we set. Right-button, so nothing in the UI can act on it.
    private static func clickProbe(controller c: NotchWindowController,
                                   model: HUDViewModel,
                                   notchCenter: CGPoint, farAway: CGPoint) async {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { _ in
            clicksReceived += 1
            return nil          // swallow it; nothing downstream should act
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        let restoreTo = NSEvent.mouseLocation
        defer { warp(to: restoreTo) }

        line("")
        line("--- synthetic click probe (right button, at the notch) ---")

        // Collapsed. This is the state that must not swallow menu-bar clicks.
        move(to: farAway)
        await sleepMs(600)
        check("precondition: collapsed and click-through",
              model.isExpanded == false && c.panel.ignoresMouseEvents == true)
        clicksReceived = 0
        postRightClick(at: notchCenter)
        await sleepMs(250)
        let whileCollapsed = clicksReceived

        // Expanded. The bubble has to actually receive clicks or rows are dead.
        move(to: notchCenter)
        await sleepMs(400)
        check("precondition: expanded and mouse-opaque",
              model.isExpanded == true && c.panel.ignoresMouseEvents == false)
        clicksReceived = 0
        postRightClick(at: notchCenter)
        await sleepMs(250)
        let whileExpanded = clicksReceived

        // The expanded case doubles as the probe's own control. If a click the
        // panel is mouse-OPAQUE for still never arrives, posting itself is being
        // dropped (CGEvent needs an Accessibility grant this process does not
        // have), and the collapsed zero means nothing. Say so instead of banking
        // an unearned pass.
        if whileCollapsed == 0 && whileExpanded == 0 {
            line("INCONCLUSIVE: the control case (mouse-opaque) received no click either,")
            line("              so CGEvent posting is being dropped here — AXIsProcessTrusted")
            line("              is false. This probe proves nothing in either direction.")
            return
        }
        check("a real click at the notch is NOT delivered to us while collapsed  [received=\(whileCollapsed)]",
              whileCollapsed == 0)
        check("a real click at the notch IS delivered to us while expanded  [received=\(whileExpanded)]",
              whileExpanded > 0)
    }

    private static func postRightClick(at p: CGPoint) {
        let cg = toCG(p)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: cg, mouseButton: .right)?.post(tap: .cghidEventTap)
        }
    }

    private static func warp(to p: CGPoint) { CGWarpMouseCursorPosition(toCG(p)) }

    /// AppKit screen space (bottom-left origin) to CoreGraphics display space
    /// (top-left origin on the primary display).
    private static func toCG(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    private static func move(to p: CGPoint) {
        pointer = p
        controller.handlePointer(p)
    }

    /// The window a mouse-down at `p` would actually hit. Windows that ignore
    /// mouse events are skipped, which is what makes this a real proof of
    /// click-through rather than a restatement of the flag we just set.
    private static func fmtP(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }

    /// One run-loop turn plus a model tick, so timer-driven state settles.
    private static func settle() async { await sleepMs(150) }

    private static func sleepMs(_ ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        line("\(ok ? "ok  " : "FAIL") \(name)")
    }

    private static func line(_ s: String) { print(s); fflush(stdout) }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
}
