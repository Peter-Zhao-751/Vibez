import AppKit
import CoreGraphics
import Foundation

/// Every number that decides how hover FEELS, readable from `UserDefaults` so a
/// live tuning session needs no rebuild.
///
///     defaults write vibezlol.VibezHUD vibez.hud.tune.projectionMs -float 140
///     defaults write vibezlol.VibezHUD vibez.hud.tune.fastExitSpeed -float 650
///
/// In `--tune-hover` the values are re-read continuously, so an edit takes
/// effect on the next sample; otherwise they are read once at launch. The
/// compiled constants in `HoverTiming` are the defaults, so an untouched install
/// behaves exactly as shipped and `defaults delete` restores it.
public struct HoverTuning: Sendable, Equatable {
    /// τ in `p + v·τ + ½a·τ²`. 120ms is about one reaction time: far enough
    /// ahead to start the collapse before the boundary, near enough that the
    /// extrapolation is still describing the same gesture.
    public var projectionMs: Double
    /// How far outside the zone the projection must land before the early exit
    /// fires. 40pt is roughly a fifth of the notch's width — comfortably more
    /// than the jitter of a hand resting on a trackpad, so ordinary movement
    /// inside the board never trips it.
    public var exitMarginPt: CGFloat
    /// Above this outbound speed an exit that has ALREADY crossed the boundary
    /// skips the close delay. 800pt/s is a deliberate flick; browsing the board
    /// runs an order of magnitude slower.
    public var fastExitSpeed: CGFloat
    /// Hysteresis, mirrored here so the tuning session can move them too.
    public var openDelayMs: Int64
    public var closeDelayMs: Int64
    /// Vertical correction applied to the collapsed flanks ONLY when the menu bar
    /// is hidden. Negative is upward.
    public var flankYNudgeFullscreen: CGFloat

    public static let compiled = HoverTuning(
        projectionMs: 120,
        exitMarginPt: 40,
        fastExitSpeed: 800,
        openDelayMs: HoverTiming.openDelayMs,
        closeDelayMs: HoverTiming.closeDelayMs,
        flankYNudgeFullscreen: -2)

    public static let prefix = "vibez.hud.tune."

    /// Reads overrides, falling back to the compiled value for anything absent —
    /// `object(forKey:)` first, because `double(forKey:)` cannot tell "absent"
    /// from "set to 0" and 0 is a meaningful value for most of these.
    public static func load(_ defaults: UserDefaults = .standard) -> HoverTuning {
        func num(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: prefix + key) == nil ? fallback : defaults.double(forKey: prefix + key)
        }
        let c = compiled
        return HoverTuning(
            projectionMs: num("projectionMs", c.projectionMs),
            exitMarginPt: CGFloat(num("exitMarginPt", Double(c.exitMarginPt))),
            fastExitSpeed: CGFloat(num("fastExitSpeed", Double(c.fastExitSpeed))),
            openDelayMs: Int64(num("openDelayMs", Double(c.openDelayMs))),
            closeDelayMs: Int64(num("closeDelayMs", Double(c.closeDelayMs))),
            flankYNudgeFullscreen: CGFloat(num("flankYNudgeFullscreen",
                                               Double(c.flankYNudgeFullscreen))))
    }
}

/// `--tune-hover`: one line per pointer sample, appended to
/// `~/.config/vibez/hud/tune.log`, so a live session can be replayed and the
/// constants dialled from real motion instead of from adjectives.
///
/// Off unless the flag is passed: this writes at the sampling rate.
@MainActor
final class HoverTuneLog {
    static var shared: HoverTuneLog?

    private let handle: FileHandle?
    private let start = Date()

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        guard handle != nil else { return nil }
        write("# vibez-hud tune log — t(ms) pos v a projected decision state")
        print("[tune] logging to \(url.path)")
        fflush(stdout)
    }

    func line(_ s: String) {
        write(String(format: "%8.1f  %@", Date().timeIntervalSince(start) * 1000, s))
    }

    private func write(_ s: String) {
        guard let handle, let data = (s + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        // Flushed every line on purpose: the point of this file is that someone
        // is tailing it while moving the mouse.
        try? handle.synchronize()
    }
}

/// `--probe-screen`: what the menu-bar-hidden heuristic actually sees on this
/// machine, in whatever mode the machine is in right now.
///
/// The user reports the collapsed dots looking centred on the desktop but not in
/// fullscreen, and the only thing that differs between those modes for a
/// top-anchored window is the band the eye compares against: with the menu bar
/// showing, the notch sits in a lit strip of UI; with it hidden, in unbroken
/// black. There is no API for "is some other app fullscreen on my screen", so
/// the signal used is `visibleFrame` — run this in both modes to see it move.
@MainActor
enum ScreenProbe {
    static func run() -> Never {
        for (i, s) in NSScreen.screens.enumerated() {
            let gap = s.frame.maxY - s.visibleFrame.maxY
            print("screen \(i) \(s.localizedName)")
            print("   frame          \(fmt(s.frame))")
            print("   visibleFrame   \(fmt(s.visibleFrame))")
            print(String(format: "   top gap        %.1fpt   safeAreaTop %.1fpt",
                         gap, s.safeAreaInsets.top))
            print("   auxTopLeft     \(fmt(s.auxiliaryTopLeftArea ?? .zero))")
            print("   auxTopRight    \(fmt(s.auxiliaryTopRightArea ?? .zero))")
            print("   menuBarIsHidden -> \(NotchWindowController.menuBarIsHidden(on: s))")
        }
        // Does hiding the menu bar from THIS process move the signal? An
        // accessory app owns no menu bar, so this may well be a no-op — the
        // answer is recorded rather than assumed.
        let before = NSScreen.screens.first!.visibleFrame.maxY
        NSMenu.setMenuBarVisible(false)
        usleep(400_000)
        let after = NSScreen.main!.visibleFrame.maxY
        NSMenu.setMenuBarVisible(true)
        print(String(format: "\nsetMenuBarVisible(false): visibleFrame.maxY %.1f -> %.1f  (%@)",
                     before, after, abs(before - after) > 0.5 ? "MOVED" : "no effect from an accessory app"))
        fflush(stdout)
        exit(0)
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }
}
