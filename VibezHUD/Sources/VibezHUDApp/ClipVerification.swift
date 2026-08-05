import AppKit
import SwiftUI
import VibezSessionKit

/// `--verify-clip`: PROVE where a horizontally dragged bubble's ink stops.
///
/// ImageRenderer cannot render ScrollView content (round-5 finding), and the
/// suspected clipper IS the ScrollView — so this probe hosts the real
/// `SessionColumn` in an offscreen NSWindow and captures it with
/// `cacheDisplay`, a real AppKit render pass where scroll content draws.
/// No screen recording involved: we draw our own window into our own bitmap.
///
/// Geometry: the column is 340pt wide, leading-aligned on a 420pt canvas,
/// over a mid-grey backdrop (the bubble fill is dark; ink must be measured
/// as DIFFERENCE from the backdrop, and pure black canvas would make the
/// muted card invisible). The first tile is force-dragged +100pt raw, which
/// the rubber band turns into ~+9.4pt. If nothing clips, its ink reaches
/// ~349pt; if the scroll bounds clip, ink stops at exactly 340pt.
@MainActor
enum ClipVerification {
    static let columnWidth: CGFloat = 340
    static let canvasWidth: CGFloat = 420
    static let canvasHeight: CGFloat = 260

    static func run() {
        var failures = 0
        func check(_ label: String, _ ok: Bool) {
            print("\(ok ? "ok  " : "FAIL") \(label)"); fflush(stdout)
            if !ok { failures += 1 }
        }

        let demo = DemoData.snapshot()
        let dragged = demo.working[0]

        func capture(translation: CGSize) -> NSBitmapImageRep? {
            let column = SessionColumn(title: "WORKING", dot: HUDTheme.working,
                                       sessions: demo.working, nowMs: dragged.lastActivityMs,
                                       onTap: { _ in }, tileStyle: .workingCard,
                                       forcedDrag: (dragged.id, translation))
                .frame(width: columnWidth)
                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                .background(Color(red: 0.5, green: 0.5, blue: 0.5))

            let host = NSHostingView(rootView: column)
            host.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            window.colorSpace = .sRGB
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        /// The rightmost x (in points) whose pixel differs from the grey
        /// backdrop anywhere in the tile band — i.e. where the bubble's ink
        /// actually ends in the capture.
        func rightmostInk(_ rep: NSBitmapImageRep) -> CGFloat {
            let scale = CGFloat(rep.pixelsWide) / canvasWidth
            let backdrop: (Int, Int, Int) = (127, 127, 128)
            var rightmost = 0
            for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
                var hit = false
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255),
                        b = Int(c.blueComponent * 255)
                    if abs(r - backdrop.0) > 12 || abs(g - backdrop.1) > 12 || abs(b - backdrop.2) > 12 {
                        hit = true; break
                    }
                }
                if hit { rightmost = x; break }
            }
            return CGFloat(rightmost) / scale
        }

        guard let rest = capture(translation: .zero),
              let pulled = capture(translation: CGSize(width: 100, height: 0)) else {
            check("captured both states", false)
            exit(1)
        }

        let restEdge = rightmostInk(rest)
        let pulledEdge = rightmostInk(pulled)
        let banded = RubberBand.offset(for: CGSize(width: 100, height: 0),
                                       horizontalLimit: TileStyle.workingCard.horizontalDragLimit,
                                       verticalLimit: HUDTheme.bubbleDragLimit).width
        print(String(format: "     rest edge %.1fpt   pulled edge %.1fpt   expected +%.1fpt travel",
                     restEdge, pulledEdge, banded)); fflush(stdout)

        check(String(format: "at rest the ink ends at the column edge  [%.1f ≈ %.0f]", restEdge, columnWidth),
              abs(restEdge - columnWidth) <= 1.5)
        check(String(format: "a pulled bubble's ink travels PAST the column edge  [%.1f vs %.1f]",
                     pulledEdge, restEdge + banded - 1.5),
              pulledEdge >= restEdge + banded - 1.5)

        print(failures == 0 ? "\nCLIP VERIFY: PASS" : "\nCLIP VERIFY: \(failures) FAILED")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
