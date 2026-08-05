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
    /// knows about `PointerReading`.
    @ObservationIgnored var pointerProvider: (() -> PointerReading)?

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
        // Seeded before the window controller's first `layout()`, so the panel is
        // never sized for a one-row island on frame 1.
        refreezeRowsWhileCollapsed()
    }

    func start() { schedule(fast: false) }

    func stop() { timer?.invalidate(); timer = nil; isSampling = nil }

    /// ADAPTIVE. One timer drives the pointer poll, the log drain and the hover
    /// clock, and its period follows where the pointer is.
    ///
    /// A fixed rate cannot win here. Fast enough to catch a swipe across the
    /// notch means 50 Hz, and 50 Hz forever is a timer waking a background agent
    /// twenty-four hours a day for a pointer that is almost never near the top of
    /// the screen. So: 100ms while the pointer is anywhere else — cheap, and
    /// still enough to notice it approaching — and 20ms the moment it is near the
    /// top edge or the HUD is open, which is exactly when a missed sample is the
    /// difference between "it works" and "it only works sometimes". Reading
    /// `NSEvent.mouseLocation` and testing a rect costs nanoseconds; the timer
    /// wakeup is the whole cost, which is why it is the thing being managed.
    private var isSampling: Bool?
    private func schedule(fast: Bool) {
        guard isSampling != fast else { return }
        isSampling = fast
        timer?.invalidate()
        let interval = fast ? HoverTiming.fastSampleSeconds : HoverTiming.idleSampleSeconds
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // `.common` so the cadence survives menu tracking and scrolling, which
        // put the run loop into event-tracking mode and would otherwise stall the
        // only thing that notices the pointer.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Which cadence the current reading calls for. Pure so the rule is testable
    /// without a screen or a clock.
    nonisolated static func wantsFastSampling(reading: PointerReading, isExpanded: Bool) -> Bool {
        reading.nearTop || isExpanded
    }

    func hoverChanged(_ input: HoverInput) {
        hover.handle(input, nowMs: nowMs)
        tick()
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var lastDrainMs: Int64 = 0
    private func tick() {
        let now = nowMs
        // Ask where the pointer is BEFORE advancing the hysteresis clock, so an
        // arrival is timestamped at this tick rather than the next one.
        // `HoverPolicy.handle` is idempotent for a repeated input, which is what
        // makes polling the same signal fifty times a second harmless.
        if let reading = pointerProvider?() {
            hover.handle(reading.hover, nowMs: now)
            schedule(fast: HUDViewModel.wantsFastSampling(reading: reading, isExpanded: hover.isExpanded))
        }
        if hover.tick(nowMs: now) {
            isExpanded = hover.isExpanded
            onExpansionChanged?(isExpanded)
        }
        // AFTER the flip, so the tick that opens the island keeps the size it was
        // already showing rather than adopting a target computed a frame later.
        refreezeRowsWhileCollapsed()
        // At most one assignment per second: the tiles' age labels are
        // wall-clock derived, and the snapshot guard below means nothing else
        // would invalidate them while the log is quiet.
        if ageClock.advance(toMs: now) { clockMs = now }
        guard !isDemo, let engine else { return }
        // Drained on the WALL CLOCK, not on a tick count: the tick rate is
        // adaptive now, and counting ticks would silently drain the log five
        // times more often whenever the pointer wandered near the menu bar.
        if now - lastDrainMs >= HoverTiming.drainIntervalMs {
            lastDrainMs = now
            let next = engine.poll()
            // @Observable invalidates on ASSIGNMENT, not on change, so an
            // unconditional store here re-renders the whole panel 5x/sec for as
            // long as the app runs — even with nothing happening. HUDSnapshot is
            // Equatable precisely so this comparison is cheap and total.
            if next != snapshot { snapshot = next }
        }
    }

    /// Rows the EXPANDED island is sized from — the longest column, since the
    /// three columns sit side by side.
    ///
    /// FROZEN while open, and recomputed only while collapsed. Two reasons, one
    /// of which is a bug that would have been very hard to catch by eye: this
    /// number decides the island's target height, the log is drained five times
    /// a second, and a new session landing mid-morph would move the target the
    /// animation is flying toward — a genuine second movement in the middle of
    /// the first. Freezing it also stops the island resizing under a pointer
    /// that is already reading it; the columns scroll, so nothing is lost.
    private(set) var bubbleRowCount: Int = 1

    private func refreezeRowsWhileCollapsed() {
        let next = HUDViewModel.rowCount(current: bubbleRowCount,
                                         snapshot: snapshot, isExpanded: isExpanded)
        if next != bubbleRowCount { bubbleRowCount = next }
    }

    /// Pure, so the freeze is a testable rule rather than an ordering accident.
    /// `nonisolated` because it touches nothing but its arguments.
    nonisolated static func rowCount(current: Int, snapshot: HUDSnapshot, isExpanded: Bool) -> Int {
        guard !isExpanded else { return current }
        return max(1, max(snapshot.needsYou.count,
                          max(snapshot.done.count, snapshot.working.count)))
    }

    var needsYouCount: Int { snapshot.needsYou.count }
    var workingCount: Int { snapshot.working.count }
    var totalRows: Int { snapshot.needsYou.count + snapshot.done.count + snapshot.working.count }
}
