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
        // One timer drives both the log drain and the hover clock. 100 ms is well
        // under the 120 ms open delay, so hysteresis stays accurate.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
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
        if hover.tick(nowMs: now) {
            isExpanded = hover.isExpanded
            onExpansionChanged?(isExpanded)
        }
        // At most one assignment per second: the tiles' age labels are
        // wall-clock derived, and the snapshot guard below means nothing else
        // would invalidate them while the log is quiet.
        if ageClock.advance(toMs: now) { clockMs = now }
        guard !isDemo, let engine else { return }
        // Drain the log ~5x/sec; the hover clock still ticks at 10Hz.
        pollCounter += 1
        if pollCounter % 2 == 0 {
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
