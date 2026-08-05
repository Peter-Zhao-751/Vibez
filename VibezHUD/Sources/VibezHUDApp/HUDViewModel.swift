import Foundation
import Observation
import VibezSessionKit

@Observable
@MainActor
final class HUDViewModel {
    private(set) var snapshot: HUDSnapshot = HUDSnapshot()
    private(set) var isExpanded = false

    /// Whole-second wall clock the tiles derive their age labels from. Observed
    /// only by the expanded bubble — see `AgeClock` for why it exists at all.
    private(set) var clockMs: Int64

    /// Fired only when `isExpanded` actually flips. The window controller uses it
    /// to re-derive the panel's mouse opacity, which MUST track the collapsed /
    /// expanded state — see `NotchHoverRouter`.
    @ObservationIgnored var onExpansionChanged: ((Bool) -> Void)?

    /// Where the pointer is, asked once per tick, answered as a routed
    /// `HoverInput` by the window controller.
    ///
    /// POLLED, not observed. Hover used to arrive from `NSEvent` mouse-moved
    /// monitors, and on the user's machine they simply did not fire — the HUD
    /// only ever opened on a click. `NSEvent.mouseLocation` is a class property:
    /// reading it delivers no event, needs no permission and cannot be
    /// suppressed by another app, so a poll has no failure mode to have. The
    /// AppKit read and the hit-test both stay in the controller; this end only
    /// knows about `HoverInput`.
    @ObservationIgnored var pointerProvider: (() -> HoverInput)?

    private let engine: HUDEngine?
    private var hover: HoverPolicy
    private var ageClock: AgeClock
    private var timer: Timer?
    private let isDemo: Bool

    init(demo: Bool) {
        isDemo = demo
        hover = HoverPolicy()
        let startMs = Int64(Date().timeIntervalSince1970 * 1000)
        ageClock = AgeClock(nowMs: startMs)
        clockMs = startMs
        engine = demo ? nil : HUDEngine()
        if demo { snapshot = DemoData.snapshot() } else { snapshot = engine?.primeAndDrain() ?? HUDSnapshot() }
    }

    func start() {
        // One timer drives the pointer poll, the log drain and the hover clock.
        //
        // 50 ms, not 100: this timer is now the ONLY thing that notices the
        // pointer, and its period is the worst-case lag on both edges — how long
        // after arriving at the notch the HUD starts opening, and (the one that
        // matters) how long after leaving it the panel is still swallowing
        // clicks. Half a tenth of a second of that is cheap; the tick does
        // nothing at all when nothing has changed. Still well under the 120 ms
        // open delay, so the hysteresis is unaffected.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func hoverChanged(_ input: HoverInput) {
        hover.handle(input, nowMs: nowMs)
        tick()
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var pollCounter = 0
    private func tick() {
        let now = nowMs
        // Ask where the pointer is BEFORE advancing the hysteresis clock, so an
        // arrival is timestamped at this tick rather than the next one.
        // `HoverPolicy.handle` is idempotent for a repeated input, which is what
        // makes polling the same signal ten times a second harmless.
        if let input = pointerProvider?() { hover.handle(input, nowMs: now) }
        if hover.tick(nowMs: now) {
            isExpanded = hover.isExpanded
            onExpansionChanged?(isExpanded)
        }
        // At most one assignment per second: the tiles' age labels are
        // wall-clock derived, and the snapshot guard below means nothing else
        // would invalidate them while the log is quiet.
        if ageClock.advance(toMs: now) { clockMs = now }
        guard !isDemo, let engine else { return }
        // Drain the log ~5x/sec, unchanged, even though the pointer is now
        // sampled at 20 Hz: reading the log is the expensive half.
        pollCounter += 1
        if pollCounter % 4 == 0 {
            let next = engine.poll()
            // @Observable invalidates on ASSIGNMENT, not on change, so an
            // unconditional store here re-renders the whole panel 5x/sec for as
            // long as the app runs — even with nothing happening. HUDSnapshot is
            // Equatable precisely so this comparison is cheap and total.
            if next != snapshot { snapshot = next }
        }
    }

    var needsYouCount: Int { snapshot.needsYou.count }
    var workingCount: Int { snapshot.working.count }
    var totalRows: Int { snapshot.needsYou.count + snapshot.done.count + snapshot.working.count }
}
