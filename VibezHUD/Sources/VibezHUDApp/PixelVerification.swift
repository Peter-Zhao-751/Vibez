import AppKit
import SwiftUI
import VibezSessionKit

/// `--verify-pixels`: renders the island IN PROCESS and reads the bytes back.
///
/// The claims under test are claims about pixels — "the background is pure
/// black, with no gradient band across the top" and "the collapsed counts sit on
/// the notch's centre line" — and `screencapture` is blocked on this machine. So
/// the same SwiftUI views the panel hosts are pushed through `ImageRenderer`
/// into a bitmap and asserted component by component. It is not a photo of the
/// running window, but it is the same view code, and it catches exactly the
/// class of bug reported: a translucent overlay that only shows up as a few
/// non-zero RGB values near the top edge.
@MainActor
enum PixelVerification {
    private static var failures = 0
    /// 2x, so a "within ±1 point" claim is measured with half-point resolution.
    private static let scale: CGFloat = 2

    static func run() -> Never {
        let notch = CGSize(width: 200, height: 32)
        let bubble = CGSize(width: 1040, height: 450)

        orientationControl()
        everyTileIsTheSameHeight()
        theScrollFadeIsEarned()
        needsYouIsRingedNotBarred()
        expandedIsPureBlack(notch: notch, bubble: bubble)
        noHaloAroundTheIsland(notch: notch, bubble: bubble, expanded: true)
        noHaloAroundTheIsland(notch: notch, bubble: bubble, expanded: false)
        collapsedInkIsCentred(notch: notch, bubble: bubble)
        theFullscreenNudgeMovesInkAndOnlyInk(notch: notch, bubble: bubble)
        collapsedQuietIsExactlyTheNotch(notch: notch, bubble: bubble)

        line("")
        if failures == 0 { line("PIXEL VERIFY: PASS"); exit(0) }
        line("PIXEL VERIFY: \(failures) FAILED")
        exit(1)
    }

    // MARK: - Board tiles

    /// The columns looked ragged because tiles were intrinsic-height: measured
    /// unconstrained, the three-line variant is 63.0pt and the two-line variant
    /// 48.0pt. Now every tile is exactly `HUDTheme.tileHeight`, whatever it
    /// contains, so rows line up ACROSS the three columns.
    private static func everyTileIsTheSameHeight() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let demo = DemoData.snapshot()
        let variants = [("3-line needs-you", demo.needsYou[0]), ("2-line done", demo.done[0]),
                        ("ended", demo.done[1]), ("3-line working", demo.working[0])]
        var heights: [Double] = []
        for (name, session) in variants {
            let view = SessionTile(session: session, nowMs: now) { _ in }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300)
            guard let r = rasterize(view) else { return check("tile \(name) rendered", false) }
            let pt = Double(r.height) / Double(scale)
            heights.append(pt)
            check(String(format: "%@ tile is exactly %.0fpt  [%.1f]", name,
                         Double(HUDTheme.tileHeight), pt),
                  abs(pt - Double(HUDTheme.tileHeight)) < 0.51)
        }
        check("...and every variant agrees, so the columns cannot go ragged  \(heights)",
              Set(heights).count == 1)
    }

    /// The 2pt amber bar down the left edge is gone — it lined up with nothing,
    /// least of all the header dot above it. A needs-you tile is RINGED instead,
    /// Mail-sidebar style: same fill as every other tile, amber border.
    private static func needsYouIsRingedNotBarred() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let demo = DemoData.snapshot()
        guard let ring = rasterize(tile(demo.needsYou[0], now)),
              let plain = rasterize(tile(demo.working[0], now))
        else { return check("needs-you and plain tiles rendered", false) }

        // The border runs the whole way round, so the TOP edge — where the old
        // bar never was — is where to look.
        // `strokeBorder` draws inside the edge, so the amber occupies the first
        // ~1pt of rows; take the best of them rather than betting on one.
        let topAmber = (0..<Int(2 * scale)).map { amberRun(ring, row: $0) }.max() ?? 0
        let plainTopAmber = (0..<Int(2 * scale)).map { amberRun(plain, row: $0) }.max() ?? 0
        check("a needs-you tile is ringed in amber along its top edge  [\(topAmber)px]",
              topAmber > Int(150 * scale))
        check("...and an ordinary tile is not  [\(plainTopAmber)px]", plainTopAmber == 0)

        // ...and the old bar is really gone: a 2pt-wide amber column running the
        // full height at the leading edge would show up as amber deep inside the
        // tile, well below the border's corner radius.
        let midRow = ring.height / 2
        let inset = Int(3 * scale)
        let p = ring.px(inset, midRow)
        check("no amber bar survives inside the leading edge  [\(rgb(p))]",
              !(p.r > 150 && p.g > 90 && p.b < 90))
    }

    private static func tile(_ s: Session, _ now: Int64) -> some View {
        SessionTile(session: s, nowMs: now) { _ in }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 300)
    }

    /// Pixels in one row that look like the needs-you amber.
    private static func amberRun(_ r: Raster, row: Int) -> Int {
        var n = 0
        for x in 0..<r.width {
            let p = r.px(x, row)
            if p.r > 120 && p.g > 60 && p.g < 170 && p.b < 90 { n += 1 }
        }
        return n
    }

    // MARK: - The scroll fade

    /// A fade over content that has never scrolled dims the top of the FIRST
    /// tile to hint at scrolling that has not happened. The user called it "very
    /// annoying" and they were right.
    ///
    /// `ImageRenderer` makes one synchronous pass, so `onScrollGeometryChange`
    /// never fires inside it and the live wiring cannot be exercised here — the
    /// rule that maps scroll geometry to fade edges is unit-tested instead
    /// (`ScrollFadeStateTests`). What IS asserted here is the thing the user
    /// sees: with no fade due, the first tile's top edge renders at full
    /// brightness; with one due, it is visibly dimmed.
    private static func theScrollFadeIsEarned() {
        // MEASURED LIMITATION: a `ScrollView`'s content does not render under
        // `ImageRenderer` at all — rendering the whole board yields the column
        // HEADERS and nothing else (every row below y=40pt comes back pure
        // black). So the board cannot be the subject here. What is asserted
        // instead is the mask the column actually applies, over a known solid,
        // which is the part that decides whether the first tile is dimmed.
        func render(_ state: ScrollFadeState) -> Raster? {
            rasterize(Color.white.frame(width: 200, height: 200).mask(state.maskGradient))
        }
        guard let none = render(ScrollFadeState(top: false, bottom: false)),
              let topFaded = render(ScrollFadeState(top: true, bottom: false)),
              let bottomFaded = render(ScrollFadeState(top: false, bottom: true))
        else { return check("fade masks rendered", false) }

        let mid = none.height / 2
        let topRow = 1, bottomRow = none.height - 2
        line(String(format: "     mask top row: unscrolled=%d scrolled=%d   bottom row: %d / %d",
                    none.px(100, topRow).a, topFaded.px(100, topRow).a,
                    none.px(100, bottomRow).a, bottomFaded.px(100, bottomRow).a))

        check("unscrolled, the first tile's top edge is at FULL brightness  "
              + "[alpha \(none.px(100, topRow).a) vs mid-content \(none.px(100, mid).a)]",
              none.px(100, topRow).a == none.px(100, mid).a && none.px(100, topRow).a == 255)
        check("...and with nothing below, the bottom edge is undimmed too  "
              + "[\(none.px(100, bottomRow).a)]", none.px(100, bottomRow).a == 255)
        check("once scrolled, the top fade appears  [\(topFaded.px(100, topRow).a) < 255]",
              topFaded.px(100, topRow).a < 40)
        check("...while its own mid-content stays untouched  [\(topFaded.px(100, mid).a)]",
              topFaded.px(100, mid).a == 255)
        check("with more content below, the bottom fade appears  [\(bottomFaded.px(100, bottomRow).a) < 255]",
              bottomFaded.px(100, bottomRow).a < 40)
        check("...and that one leaves the TOP alone  [\(bottomFaded.px(100, topRow).a)]",
              bottomFaded.px(100, topRow).a == 255)
    }

    private static func brightestInRow(_ r: Raster, row: Int) -> Int {
        guard row >= 0 && row < r.height else { return -1 }
        var best = 0
        for x in 0..<r.width {
            let p = r.px(x, row)
            best = max(best, max(p.r, max(p.g, p.b)))
        }
        return best
    }

    // MARK: - 0. Which way up is the buffer?

    /// Every assertion below says "the top N rows". A bitmap context's rows can
    /// be read either way up depending on how the image was drawn into it, and
    /// getting it backwards would turn "the top is black" into "the bottom is
    /// black" — a silent false pass, since the bottom of the board is padding and
    /// also black. So the orientation is not assumed, it is measured, with a
    /// view whose halves cannot be confused.
    private static func orientationControl() {
        let probe = VStack(spacing: 0) {
            Color(red: 1, green: 0, blue: 0).frame(width: 20, height: 10)
            Color(red: 0, green: 0, blue: 1).frame(width: 20, height: 10)
        }
        guard let r = rasterize(probe) else { return check("orientation control rendered", false) }
        let top = r.px(10, 2), bottom = r.px(10, r.height - 3)
        check("row 0 of the buffer is the TOP of the image  [top=\(rgb(top)) bottom=\(rgb(bottom))]",
              top.r > 200 && top.b < 60 && bottom.b > 200 && bottom.r < 60)
    }

    // MARK: - 1. Pure black, top rows and edges

    private static func expandedIsPureBlack(notch: CGSize, bubble: CGSize) {
        let view = island(needsYou: 2, done: 2, expanded: true, notch: notch, bubble: bubble)
        guard let r = rasterize(view) else { return check("expanded island rendered", false) }
        check("expanded raster is the bubble size  [\(r.width)x\(r.height) px @\(Int(scale))x]",
              r.width == Int(bubble.width * scale) && r.height == Int(bubble.height * scale))

        // The complaint: "a visible blur/gradient band across the top". The old
        // build's specular overlay was `.white.opacity(0.055)` at the very top —
        // RGB 14 — and the 0.5pt rim was brighter still. Both die here.
        var worst = (x: 0, y: 0, v: 0)
        var opaque = true
        let topRows = Int(8 * scale)                      // the top 8 POINTS
        for y in 0..<topRows {
            for x in 0..<r.width {
                let p = r.px(x, y)
                if p.a != 255 { opaque = false }
                let v = max(p.r, max(p.g, p.b))
                if v > worst.v { worst = (x, y, v) }
            }
        }
        check("the top 8pt (\(topRows) rows x \(r.width) px) are fully opaque", opaque)
        check("the top 8pt are pure #000000  [brightest=\(worst.v) at (\(worst.x),\(worst.y))]",
              worst.v == 0)

        // The rim ran the whole border, so sample the border itself, not just
        // near it. Skip the bottom corner arcs, where partial alpha is the
        // rounding and not a stroke.
        let arc = Int(HUDTheme.expandedCornerRadius * scale)
        var edgeWorst = 0
        for y in 0..<(r.height - arc) {
            for x in [0, r.width - 1] {
                let p = r.px(x, y)
                edgeWorst = max(edgeWorst, max(p.r, max(p.g, p.b)))
                if p.a != 255 { opaque = false }
            }
        }
        check("the left and right edges carry no rim  [brightest=\(edgeWorst)]", edgeWorst == 0)

        // All four corners, just inside the shape (30pt radius; 9pt in on the
        // diagonal is inside the arc and inside the board's own padding).
        let i = Int(9 * scale)
        for (name, p) in [("top-left", r.px(i, i)),
                          ("top-right", r.px(r.width - 1 - i, i)),
                          ("bottom-left", r.px(i, r.height - 1 - i)),
                          ("bottom-right", r.px(r.width - 1 - i, r.height - 1 - i))] {
            check("corner \(name) inside the shape is opaque #000000  [\(rgb(p)) a=\(p.a)]",
                  p.a == 255 && p.r == 0 && p.g == 0 && p.b == 0)
        }
    }

    // MARK: - 1b. Nothing bleeds outside the edge

    /// The "glow" complaint. A drop shadow on a black slab is a soft dark bloom
    /// spreading out of a hard-edged object, and against a desktop it reads as a
    /// halo rather than as depth — so there is no shadow any more, in either
    /// state, and this is how that stays true.
    ///
    /// Rendered on a transparent canvas a shadow would be almost invisible to a
    /// probe (dark pixels with low alpha, easy to mistake for antialiasing), so
    /// the island is composited over mid-grey exactly as it is composited over a
    /// desktop. Any bleed then shows up as grey that is no longer grey.
    private static func noHaloAroundTheIsland(notch: CGSize, bubble: CGSize, expanded: Bool) {
        let pad: CGFloat = 60          // wider than the deleted shadow's 30pt radius + 18pt offset
        let view = island(needsYou: 2, done: 3, expanded: expanded, notch: notch, bubble: bubble)
            .padding(pad)
            .background(Color(white: 0.5))
        guard let r = rasterize(view) else {
            return check("halo probe rendered (expanded=\(expanded))", false)
        }
        let state = expanded ? "expanded" : "collapsed"
        // Self-calibrating: whatever the far corner is, is the background.
        let bg = r.px(2, 2)
        let padPx = Int(pad * scale)

        // A ring from 2pt to 40pt outside the island's box — where a shadow of
        // radius 30 offset 18 down would land, in every direction.
        var worst = (x: 0, y: 0, d: 0)
        var samples = 0
        for y in 0..<r.height {
            for x in 0..<r.width {
                let outside = x < padPx - Int(2 * scale) || x >= r.width - padPx + Int(2 * scale)
                    || y < padPx - Int(2 * scale) || y >= r.height - padPx + Int(2 * scale)
                guard outside else { continue }
                let p = r.px(x, y)
                let d = max(abs(p.r - bg.r), max(abs(p.g - bg.g), abs(p.b - bg.b)))
                samples += 1
                if d > worst.d { worst = (x, y, d) }
            }
        }
        check("\(state): background sampled as \(rgb(bg)) over \(samples) ring pixels", samples > 1000)
        check("\(state): nothing bleeds outside the island's edge  "
              + "[worst deviation \(worst.d)/255 at (\(worst.x),\(worst.y))]", worst.d == 0)
    }

    // MARK: - 2. The collapsed counts sit on the notch's centre line

    private static func collapsedInkIsCentred(notch: CGSize, bubble: CGSize) {
        let view = island(needsYou: 2, done: 3, expanded: false, notch: notch, bubble: bubble)
        guard let r = rasterize(view) else { return check("collapsed island rendered", false) }

        let expected = IslandMetrics.collapsedSize(needsYou: 2, done: 3, notchSize: notch)
        check("collapsed raster is notch-height and wider than the notch  "
              + "[\(r.width)x\(r.height) px, expected \(Int(expected.width * scale))x\(Int(expected.height * scale))]",
              r.width == Int(expected.width * scale) && r.height == Int(expected.height * scale))

        // The dot now sits ON TOP of the count instead of beside it, which makes
        // the two flanks mirror images and takes a flank from 30pt to 20.
        check(String(format: "each flank costs %.0fpt, so the island is notch+%.0fpt",
                     IslandMetrics.flankWidth(count: 1), expected.width - notch.width),
              IslandMetrics.flankWidth(count: 1) == IslandMetrics.minFlankWidth)
        check("...and a two-digit count widens it rather than clipping  "
              + "[\(IslandMetrics.flankWidth(count: 12))pt]",
              IslandMetrics.flankWidth(count: 12) >= IslandMetrics.flankWidth(count: 1))

        guard let box = inkBounds(r) else { return check("the collapsed island has visible ink", false) }
        let inkCentre = Double(box.minY + box.maxY + 1) / 2 / Double(scale)
        let shapeCentre = Double(r.height) / 2 / Double(scale)
        let delta = inkCentre - shapeCentre
        check(String(format: "stack ink centre %.2fpt vs shape centre %.2fpt — off by %+.2fpt (±1pt)",
                     inkCentre, shapeCentre, delta), abs(delta) <= 1.0)
        line(String(format: "     ink rows %d..%d of %d px; %d ink pixels",
                    box.minY, box.maxY, r.height, box.count))
        // Ink is a dot STACKED over a digit — dot, gap, cap height — and still
        // comfortably inside the notch's own height.
        let inkHeight = Double(box.maxY - box.minY + 1) / Double(scale)
        check(String(format: "the ink is a dot stacked over a digit  [%.1fpt tall]", inkHeight),
              inkHeight >= Double(IslandMetrics.dotDiameter + IslandMetrics.dotGap)
                  && inkHeight <= Double(notch.height) - 8)

        // ...and each dot is the RIGHT dot. The left one says "blocked on you",
        // the right one says "finished" — different meanings, so different
        // colours, asserted rather than assumed. Stacked, the dot is the TOP of
        // the ink and sits on its flank's own centre line.
        let dotRow = box.minY + Int(IslandMetrics.dotDiameter / 2 * scale)
        let leftFlankMid = Int(IslandMetrics.flankWidth(count: 2) / 2 * scale)
        let rightFlankMid = r.width - 1 - Int(IslandMetrics.flankWidth(count: 3) / 2 * scale)
        let left = r.px(leftFlankMid, dotRow)
        let right = r.px(rightFlankMid, dotRow)
        check("left flank is the amber needs-you dot #FF9F0A  [\(rgb(left))]",
              left.r > 230 && left.g > 130 && left.g < 190 && left.b < 60)
        check("right flank is the green done dot #30D158  [\(rgb(right))]",
              right.r < 90 && right.g > 190 && right.b > 60 && right.b < 130)

        // The counts themselves: white ink somewhere to the right of each dot.
        let leftDigit = brightestColumnRange(r, from: 0,
                                             to: Int(IslandMetrics.flankWidth(count: 2) * scale))
        check("the needs-you count is drawn in white  [brightest=\(leftDigit)]", leftDigit >= 230)
    }

    // MARK: - 2b. The fullscreen nudge

    /// The user sees the dots as centred on the desktop but high/low in
    /// fullscreen. Whatever the cause — the eye has a lit menu-bar strip to
    /// compare against in one mode and unbroken black in the other — the fix is
    /// a small mode-dependent nudge, and the thing that must NOT happen is the
    /// black island moving with it: the island has to stay welded to the
    /// hardware notch in every mode. So this asserts the ink moved by exactly
    /// the nudge and the shape did not move at all.
    private static func theFullscreenNudgeMovesInkAndOnlyInk(notch: CGSize, bubble: CGSize) {
        let nudge = HoverTuning.compiled.flankYNudgeFullscreen
        guard let plain = rasterize(island(needsYou: 2, done: 3, expanded: false,
                                           notch: notch, bubble: bubble)),
              let nudged = rasterize(island(needsYou: 2, done: 3, expanded: false,
                                            notch: notch, bubble: bubble, nudge: nudge)),
              let a = inkBounds(plain), let b = inkBounds(nudged)
        else { return check("nudged island rendered", false) }

        check("the nudge does not resize the black island  [\(plain.width)x\(plain.height) vs \(nudged.width)x\(nudged.height)]",
              plain.width == nudged.width && plain.height == nudged.height)
        let movedPt = Double(b.minY - a.minY) / Double(scale)
        check(String(format: "menu-bar-hidden moves the ink %.2fpt (asked for %.2f)", movedPt, Double(nudge)),
              abs(movedPt - Double(nudge)) <= 0.5)
        check(String(format: "...and it moves UP  [%.2fpt]", movedPt), movedPt < 0)
    }

    // MARK: - 3. Quiet is invisible

    private static func collapsedQuietIsExactlyTheNotch(notch: CGSize, bubble: CGSize) {
        let view = island(needsYou: 0, done: 0, expanded: false, notch: notch, bubble: bubble)
        guard let r = rasterize(view) else { return check("quiet island rendered", false) }
        let widthPt = Double(r.width) / Double(scale)
        check(String(format: "with both counts zero the shape is exactly the notch width  [%.1fpt vs %.1fpt]",
                     widthPt, notch.width), abs(widthPt - Double(notch.width)) < 0.01)
        check("...and the notch height  [\(Double(r.height) / Double(scale))pt vs \(notch.height)pt]",
              abs(Double(r.height) / Double(scale) - Double(notch.height)) < 0.01)
        let box = inkBounds(r)
        check("...and carries no ink at all  [\(box?.count ?? 0) ink pixels]", box == nil)
    }

    // MARK: - Rendering

    private static func island(needsYou: Int, done: Int, expanded: Bool,
                               notch: CGSize, bubble: CGSize,
                               nudge: CGFloat = 0) -> some View {
        NotchIsland(needsYou: needsYou, done: done, isExpanded: expanded,
                    notchSize: notch, bubbleSize: bubble, flankYNudge: nudge) {
            BubbleBoard(snapshot: DemoData.snapshot(),
                        nowMs: Int64(Date().timeIntervalSince1970 * 1000)) { _ in }
        }
    }

    private struct Raster {
        let width: Int, height: Int
        let bytes: [UInt8]
        func px(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
        }
    }

    private static func rasterize<V: View>(_ view: V) -> Raster? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = bytes.withUnsafeMutableBytes({ raw in
                  CGContext(data: raw.baseAddress, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
              })
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let buf = UnsafeRawBufferPointer(start: data, count: w * h * 4)
        return Raster(width: w, height: h, bytes: [UInt8](buf))
    }

    /// Brightest pixel anywhere in a column band — used to find the white digits
    /// without depending on exactly where the text engine placed them.
    private static func brightestColumnRange(_ r: Raster, from x0: Int, to x1: Int) -> Int {
        var best = 0
        for x in max(0, x0)..<min(r.width, x1) {
            for y in 0..<r.height {
                let p = r.px(x, y)
                best = max(best, min(p.r, min(p.g, p.b)))     // min channel: white only
            }
        }
        return best
    }

    /// Rows and brightness of everything that is not the black shape. Alpha
    /// matters: the rounded corners are black-with-partial-alpha, which is the
    /// silhouette, not ink.
    private static func inkBounds(_ r: Raster)
    -> (minY: Int, maxY: Int, count: Int, brightest: Int)? {
        var minY = Int.max, maxY = -1, count = 0, brightest = 0
        for y in 0..<r.height {
            for x in 0..<r.width {
                let p = r.px(x, y)
                let v = max(p.r, max(p.g, p.b))
                guard v > 24 else { continue }          // above antialias fringe
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1; brightest = max(brightest, v)
            }
        }
        return maxY < 0 ? nil : (minY, maxY, count, brightest)
    }

    // MARK: - Reporting

    private static func rgb(_ p: (r: Int, g: Int, b: Int, a: Int)) -> String {
        String(format: "#%02X%02X%02X", p.r, p.g, p.b)
    }
    private static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        line("\(ok ? "ok  " : "FAIL") \(name)")
    }
    private static func line(_ s: String) { print(s); fflush(stdout) }
}
