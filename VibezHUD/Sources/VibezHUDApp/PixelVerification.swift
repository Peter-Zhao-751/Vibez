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
        expandedIsPureBlack(notch: notch, bubble: bubble)
        collapsedInkIsCentred(notch: notch, bubble: bubble)
        collapsedQuietIsExactlyTheNotch(notch: notch, bubble: bubble)

        line("")
        if failures == 0 { line("PIXEL VERIFY: PASS"); exit(0) }
        line("PIXEL VERIFY: \(failures) FAILED")
        exit(1)
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
        let view = island(needsYou: 2, working: 2, expanded: true, notch: notch, bubble: bubble)
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

    // MARK: - 2. The collapsed counts sit on the notch's centre line

    private static func collapsedInkIsCentred(notch: CGSize, bubble: CGSize) {
        let view = island(needsYou: 2, working: 3, expanded: false, notch: notch, bubble: bubble)
        guard let r = rasterize(view) else { return check("collapsed island rendered", false) }

        let expected = IslandMetrics.collapsedSize(needsYou: 2, working: 3, notchSize: notch)
        check("collapsed raster is notch-height and wider than the notch  "
              + "[\(r.width)x\(r.height) px, expected \(Int(expected.width * scale))x\(Int(expected.height * scale))]",
              r.width == Int(expected.width * scale) && r.height == Int(expected.height * scale))

        guard let box = inkBounds(r) else { return check("the collapsed island has visible ink", false) }
        let inkCentre = Double(box.minY + box.maxY) / 2 / Double(scale)
        let shapeCentre = Double(r.height) / 2 / Double(scale)
        let delta = inkCentre - shapeCentre
        check(String(format: "ink centre %.2fpt vs shape centre %.2fpt — off by %+.2fpt (±1pt)",
                     inkCentre, shapeCentre, delta), abs(delta) <= 1.0)
        line(String(format: "     ink rows %d..%d of %d px; %d ink pixels",
                    box.minY, box.maxY, r.height, box.count))

        // ...and it is WHITE ink, which is the readability half of the fix: the
        // counts no longer sit on glass over the wallpaper.
        check("the counts are drawn in white  [brightest=\(box.brightest)]", box.brightest >= 230)
    }

    // MARK: - 3. Quiet is invisible

    private static func collapsedQuietIsExactlyTheNotch(notch: CGSize, bubble: CGSize) {
        let view = island(needsYou: 0, working: 0, expanded: false, notch: notch, bubble: bubble)
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

    private static func island(needsYou: Int, working: Int, expanded: Bool,
                               notch: CGSize, bubble: CGSize) -> some View {
        NotchIsland(needsYou: needsYou, working: working, isExpanded: expanded,
                    notchSize: notch, bubbleSize: bubble) {
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
