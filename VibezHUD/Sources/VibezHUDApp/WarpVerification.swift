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

        // Restored EXPLICITLY, not by `defer`: this function ends in `exit()`,
        // and `exit` does not unwind the stack — the defer would never run and
        // the user's cursor would be left wherever the last warp put it. That
        // also made consecutive runs flaky, since each one started from the
        // previous one's parking spot.
        Self.restorePoint = NSEvent.mouseLocation

        await warp(to: center, settle: 700)
        check("resting: collapsed, click-through",
              model.isExpanded == false && c.panel.ignoresMouseEvents == true)

        // 1. Entry, by hovering only — and how LONG it takes, measured.
        CGWarpMouseCursorPosition(toCG(notch))
        let openMs = await waitFor(model, expanded: true)
        line(String(format: "   OPEN  latency %.0fms (cursor placed -> isExpanded)", openMs))
        check("moving the real cursor onto the notch EXPANDS it — no click",
              model.isExpanded == true)
        check(String(format: "...within 250ms  [%.0fms]", openMs), openMs <= 250)
        check("...and the panel is mouse-opaque there", c.panel.ignoresMouseEvents == false)

        // 1b. And how long it takes to get OUT of the way.
        CGWarpMouseCursorPosition(toCG(center))
        let closeMs = await waitFor(model, expanded: false)
        line(String(format: "   CLOSE latency %.0fms (cursor left -> collapsed)", closeMs))
        check(String(format: "leaving collapses it within 250ms  [%.0fms]", closeMs), closeMs <= 250)

        // 1c. THE ROUND-3 COMPLAINT: a quick deliberate swipe onto the notch,
        //     three steps 20ms apart, the way a hand actually moves. At the old
        //     50ms sampling this could be seen once or not at all, and one
        //     sample can never clear an open delay — "sometimes it doesn't
        //     activate". Nothing here waits for the pointer to sit still.
        await warp(to: center, settle: 400)
        check("precondition: collapsed before the swipe", model.isExpanded == false)
        for p in [CGPoint(x: notch.x - 120, y: notch.y - 60),
                  CGPoint(x: notch.x - 50, y: notch.y - 20),
                  notch] {
            CGWarpMouseCursorPosition(toCG(p))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let swipeMs = await waitFor(model, expanded: true)
        line(String(format: "   SWIPE-IN opened %.0fms after the last step", swipeMs))
        check("a 3-step 20ms swipe onto the notch opens it", model.isExpanded == true)
        check(String(format: "...promptly  [%.0fms after the swipe ended]", swipeMs), swipeMs <= 250)
        await warp(to: center, settle: 500)

        // 1d. The other half of "sometimes it doesn't activate": the notch is a
        //     HOLE, so people aim just UNDER it and stop. With the old 6pt of
        //     depth that landed in dead space. 15pt under the island's bottom
        //     edge is inside the zone now and was not before.
        let justUnder = CGPoint(x: g.notchRect.midX, y: g.notchRect.minY - 15)
        check("precondition: 15pt under the notch is inside the hot zone",
              g.hoverRect.contains(justUnder))
        for p in [CGPoint(x: justUnder.x - 100, y: justUnder.y - 40), justUnder] {
            CGWarpMouseCursorPosition(toCG(p))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let underMs = await waitFor(model, expanded: true)
        line(String(format: "   AIM-UNDER opened %.0fms after stopping 15pt below the notch", underMs))
        check("stopping just UNDER the notch opens it too", model.isExpanded == true)
        await warp(to: center, settle: 500)

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

        await predictiveExit(c, model, island: island, notch: notch, center: center)

        line("")
        finish()
    }

    private static var restorePoint = CGPoint.zero

    private static func finish() -> Never {
        CGWarpMouseCursorPosition(toCG(restorePoint))
        if failures == 0 { line("WARP VERIFY: PASS"); exit(0) }
        line("WARP VERIFY: \(failures) FAILED")
        exit(1)
    }

    /// The round-4 complaint: leaving still felt delayed. Containment cannot
    /// help — by the time the pointer is outside it has been outside for a
    /// sample, and only then does the close delay start. So the collapse is now
    /// predicted from the pointer's own velocity and acceleration, and these
    /// three cases are the ones that matter: it must start early on a real
    /// departure, it must NOT start early on a feint, and a slow drift must keep
    /// its grace period.
    private static func predictiveExit(_ c: NotchWindowController, _ model: HUDViewModel,
                                       island: CGRect, notch: CGPoint, center: CGPoint) async {
        line("")
        line("--- predictive exit ---")

        // 1. FAST SWIPE OUT, measured twice: once with the predictor disabled
        //    (its margin pushed out of reach through the same UserDefaults knob
        //    a tuning session uses) and once as shipped. The number that matters
        //    is close ONSET — when the HUD is told the pointer is leaving — not
        //    when `isExpanded` flips, which is onset plus the close delay plus
        //    the morph and would be identical either way.
        let d = UserDefaults.standard
        d.set(1_000_000.0, forKey: HoverTuning.prefix + "exitMarginPt")
        let baseline = await swipeOut(c, model, island: island, notch: notch)
        d.removeObject(forKey: HoverTuning.prefix + "exitMarginPt")
        let predicted = await swipeOut(c, model, island: island, notch: notch)

        line(String(format: "   swipe-out  boundary crossed at step %d", predicted.crossed))
        line(String(format: "   close onset  WITHOUT prediction: step %d   WITH: step %d",
                    baseline.onset, predicted.onset))
        check("the swipe-out closes at all", predicted.onset >= 0)
        check("...and the close STARTS BEFORE the cursor leaves the island (+1 sample)  "
              + "[onset@\(predicted.onset) vs crossed@\(predicted.crossed)]",
              predicted.onset >= 0 && predicted.crossed >= 0 && predicted.onset <= predicted.crossed + 1)
        check("...earlier than containment alone could ever manage  "
              + "[\(predicted.onset) < \(baseline.onset)]",
              predicted.onset < baseline.onset)

        // 2. FEINT. Move outward fast enough to trip the prediction, then come
        //    back INSIDE within 60ms. The prediction is allowed to be wrong; it
        //    is not allowed to cost anything when it is. This works only because
        //    `HoverPolicy`'s re-entry cancel is untouched.
        await warp(to: notch, settle: 400)
        check("precondition: expanded before the feint", model.isExpanded == true)
        for p in [CGPoint(x: island.midX, y: island.maxY - 40),
                  CGPoint(x: island.midX, y: island.maxY - 110),
                  CGPoint(x: island.midX, y: island.maxY - 175)] {
            CGWarpMouseCursorPosition(toCG(p))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // ...and back, well inside, inside the close delay.
        CGWarpMouseCursorPosition(toCG(CGPoint(x: island.midX, y: island.maxY - 30)))
        try? await Task.sleep(nanoseconds: 60_000_000)
        check("a feint back inside within 60ms does NOT collapse  [expanded=\(model.isExpanded)]",
              model.isExpanded == true)

        // 3. SLOW DRIFT across the boundary keeps the grace period: nothing about
        //    this motion says the user has decided to leave.
        await warp(to: notch, settle: 400)
        let driftStart = Date()
        var driftClosed: Double = -1
        for i in 0..<12 {
            let p = CGPoint(x: island.midX, y: island.maxY - CGFloat(i) * 6)   // ~300pt/s
            CGWarpMouseCursorPosition(toCG(p))
            try? await Task.sleep(nanoseconds: 20_000_000)
            if driftClosed < 0 && !model.isExpanded {
                driftClosed = Date().timeIntervalSince(driftStart) * 1000
            }
        }
        line(String(format: "   slow drift: still open after %.0fms of crawling%@",
                    Date().timeIntervalSince(driftStart) * 1000,
                    driftClosed < 0 ? "" : String(format: " (closed at %.0fms)", driftClosed)))
        check("a slow drift inside the island does not trip the predictor",
              driftClosed < 0 || driftClosed > 150)
        await warp(to: center, settle: 500)
    }

    /// One fast departure, sampled in 20ms steps. Returns the step at which the
    /// cursor genuinely left the hover zone and the step at which the HUD was
    /// told it was leaving.
    private static func swipeOut(_ c: NotchWindowController, _ model: HUDViewModel,
                                 island: CGRect, notch: CGPoint) async -> (crossed: Int, onset: Int) {
        await warp(to: notch, settle: 450)
        let zone = island.insetBy(dx: -NotchHoverRouter.forgiveness, dy: -NotchHoverRouter.forgiveness)
        let before = c.lastExitRoutedMs
        var crossed = -1, onset = -1
        let step: CGFloat = 60          // 60pt per 20ms = 3000pt/s, a real flick
        for i in 0..<14 {
            // Start 30pt INSIDE the top edge: `CGRect.contains` excludes maxY, so
            // beginning exactly on the boundary would report "already outside".
            let p = CGPoint(x: island.midX, y: island.maxY - 30 - CGFloat(i) * step)
            CGWarpMouseCursorPosition(toCG(p))
            try? await Task.sleep(nanoseconds: 20_000_000)
            if crossed < 0 && !zone.contains(p) { crossed = i }
            if onset < 0 && c.lastExitRoutedMs != before { onset = i }
        }
        await warp(to: CGPoint(x: island.midX, y: 100), settle: 400)
        return (crossed, onset)
    }

    /// Poll the model every 5ms until it reaches `expanded`, and report how long
    /// that took. This is the number the user is complaining about, so it is
    /// measured rather than asserted by sleeping long enough to be safe.
    private static func waitFor(_ model: HUDViewModel, expanded: Bool,
                                timeoutMs: Int = 2_000) async -> Double {
        let start = Date()
        while model.isExpanded != expanded {
            if Date().timeIntervalSince(start) * 1000 > Double(timeoutMs) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return Date().timeIntervalSince(start) * 1000
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
