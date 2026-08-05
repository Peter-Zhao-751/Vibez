import AppKit
import SwiftUI

/// `--verify-morph`: records the island's INTERPOLATED frame, once per rendered
/// frame, through a real expand and a real collapse, and prints the timeline.
///
/// "It pops up twice" is a claim about motion, and motion is the one thing a
/// still frame cannot settle. So this drives the real panel through the real
/// animation and taps the size SwiftUI is actually laying out at
/// (`IslandSizeProbe`), which makes overshoot, rebound and mid-flight retargets
/// all directly visible as numbers instead of adjectives.
@MainActor
enum MorphVerification {
    private struct Sample { let ms: Double; let size: CGSize }

    private static var samples: [Sample] = []
    private static var t0 = Date()
    private static var failures = 0
    private static var pointer = CGPoint.zero

    static func run(controller c: NotchWindowController, model: HUDViewModel) async {
        c.pointerSource = { pointer }
        let g = c.debugGeometry
        let notchCenter = CGPoint(x: g.notchRect.midX, y: g.notchRect.midY)
        let farAway = CGPoint(x: g.metrics.frame.midX, y: g.metrics.frame.minY + 60)

        line("notchRect   \(fmt(g.notchRect))")
        line("panel.frame \(fmt(c.panel.frame))")
        line("animation   \(HUDTheme.expandDescription)")
        line("")

        // --- EXPAND -----------------------------------------------------------
        pointer = farAway
        c.handlePointer(pointer)
        await sleepMs(700)

        record(c.panel)
        pointer = notchCenter
        c.handlePointer(pointer)
        await sleepMs(1_400)
        let expand = stop()
        reportLayout("EXPAND", expand)
        guard let e = busiestLayer() else {
            check("EXPAND: some layer in the panel actually animated", false)
            finish()
        }
        report("EXPAND (layer \(e.path))", e.series)
        assess("expand", e.series, opening: true)
        check("the bubble is open at the end of the expand window", model.isExpanded == true)

        // --- COLLAPSE ---------------------------------------------------------
        record(c.panel)
        pointer = farAway
        c.handlePointer(pointer)
        await sleepMs(1_800)
        let collapse = stop()
        reportLayout("COLLAPSE", collapse)
        guard let k = busiestLayer() else {
            check("COLLAPSE: some layer in the panel actually animated", false)
            finish()
        }
        report("COLLAPSE (layer \(k.path))", k.series)
        assess("collapse", k.series, opening: false)
        check("the bubble is closed at the end of the collapse window", model.isExpanded == false)

        finish()
    }

    // MARK: - Capture
    //
    // TWO independent taps, because they answer different questions and the
    // first one alone was misleading:
    //
    //  - `IslandSizeProbe` is SwiftUI LAYOUT. It fired exactly once per morph,
    //    already at the destination size — so the frame is not being re-laid-out
    //    per frame, and a layout tap cannot see the motion at all.
    //  - the CALayer PRESENTATION tree is what is actually on the glass. Walking
    //    it at ~8ms intervals and taking the layer whose bounds move the most is
    //    a non-invasive measurement of the real animation: nothing is added to
    //    the view hierarchy, so the probe cannot change what it measures.

    private static var layerTimer: Timer?
    private static var frames: [(ms: Double, sizes: [String: CGSize])] = []

    private static func record(_ panel: NSPanel) {
        samples = []
        frames = []
        t0 = Date()
        IslandSizeProbe.sink = { size in
            samples.append(Sample(ms: Date().timeIntervalSince(t0) * 1000, size: size))
        }
        layerTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in
            Task { @MainActor in
                guard let root = panel.contentView?.layer else { return }
                var sizes: [String: CGSize] = [:]
                walk(root, "L", into: &sizes)
                frames.append((Date().timeIntervalSince(t0) * 1000, sizes))
            }
        }
    }

    private static func walk(_ layer: CALayer, _ path: String, into out: inout [String: CGSize]) {
        // `presentation()` is the mid-flight value; the model layer is already at
        // the destination and would show no motion at all.
        out[path] = (layer.presentation() ?? layer).bounds.size
        for (i, sub) in (layer.sublayers ?? []).enumerated() {
            walk(sub, path + ".\(i)", into: &out)
        }
    }

    private static func stop() -> [Sample] {
        IslandSizeProbe.sink = nil
        layerTimer?.invalidate(); layerTimer = nil
        return samples
    }

    /// The layer that moved the most is the island. Anything else in the tree is
    /// either static or the panel itself.
    private static func busiestLayer() -> (path: String, series: [Sample])? {
        var best: (String, Double) = ("", 0)
        var paths = Set<String>()
        for f in frames { paths.formUnion(f.sizes.keys) }
        for p in paths {
            let hs = frames.compactMap { $0.sizes[p]?.height }
            guard let lo = hs.min(), let hi = hs.max() else { continue }
            if hi - lo > best.1 { best = (p, hi - lo) }
        }
        guard best.1 > 1 else { return nil }
        let series = frames.compactMap { f -> Sample? in
            guard let s = f.sizes[best.0] else { return nil }
            return Sample(ms: f.ms, size: s)
        }
        return (best.0, series)
    }

    // MARK: - Reporting and assertions

    private static func finish() -> Never {
        line("")
        if failures == 0 { line("MORPH VERIFY: PASS"); exit(0) }
        line("MORPH VERIFY: \(failures) FAILED")
        exit(1)
    }

    /// What SwiftUI's LAYOUT did — one line, because it is always one frame.
    private static func reportLayout(_ title: String, _ s: [Sample]) {
        line("--- \(title): SwiftUI laid out \(s.count) time(s) ---")
        for x in s { line(String(format: "   layout t=%6.1fms  %7.2f x %7.2f", x.ms, x.size.width, x.size.height)) }
    }

    private static func report(_ title: String, _ s: [Sample]) {
        line("--- \(title): \(s.count) layout frames ---")
        guard !s.isEmpty else { return }
        // Print every frame; these timelines are the evidence, not a summary.
        for x in s {
            line(String(format: "   t=%6.1fms  %7.2f x %7.2f", x.ms, x.size.width, x.size.height))
        }
    }

    /// The three things "pops up twice" could be, each as a number:
    ///
    /// - a REVERSAL: the height goes up then down (or vice versa) by more than a
    ///   point. A spring that overshoots its target and settles back is exactly
    ///   this, and on a slab this big the rebound is the second "pop".
    /// - an OVERSHOOT past the final value.
    /// - a late SETTLE: motion still happening long after the eye expects it.
    private static func assess(_ name: String, _ s: [Sample], opening: Bool) {
        guard let last = s.last, s.count >= 2 else {
            return check("\(name): the island moved at all", false)
        }
        let target = last.size.height
        let start = s[0].size.height

        var reversals: [(Double, Double, Double)] = []
        var overshoot: Double = 0
        for i in 1..<s.count {
            let prev = s[i - 1].size.height, cur = s[i].size.height
            let delta = cur - prev
            // Direction the morph is supposed to be going.
            let wrongWay = opening ? delta < -1 : delta > 1
            if wrongWay { reversals.append((s[i].ms, prev, cur)) }
            let past = opening ? cur - target : target - cur
            overshoot = max(overshoot, past)
        }

        // Measured from MOTION ONSET, not from the pointer move: the hover
        // hysteresis deliberately spends 120ms deciding, and that is not morph.
        let onsetMs = s.first(where: { abs($0.size.height - start) > 0.5 })?.ms ?? s[0].ms
        var settleMs = s[0].ms
        for x in s where abs(x.size.height - target) > 1 { settleMs = x.ms }
        let travelMs = settleMs - onsetMs

        line(String(format: "   %@: %.1f -> %.1fpt, %d frames, onset=%.0fms, settled=%.0fms, "
                    + "TRAVEL=%.0fms, reversals=%d, overshoot=%.2fpt",
                    name, start, target, s.count, onsetMs, settleMs, travelMs,
                    reversals.count, overshoot))
        for r in reversals.prefix(6) {
            line(String(format: "     REVERSAL at t=%.1fms: %.2f -> %.2fpt", r.0, r.1, r.2))
        }
        check("\(name): the island moves in ONE direction — no rebound  [\(reversals.count) reversals]",
              reversals.isEmpty)
        check(String(format: "%@: never travels past its target  [overshoot=%.2fpt]", name, overshoot),
              overshoot <= 1.0)
        check(String(format: "%@: the morph itself takes 250-330ms  [%.0fms from onset]", name, travelMs),
              travelMs >= 240 && travelMs <= 330)
    }

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
