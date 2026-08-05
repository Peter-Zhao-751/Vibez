import Foundation

public enum HoverInput: Sendable, Equatable { case entered, exited }

/// Every number that decides how the HUD FEELS, in one place, with the arithmetic
/// that produced it.
///
/// Perceived latency is not one constant, it is a chain: how long until a sample
/// notices the pointer, plus how long the hysteresis waits before believing it,
/// plus the morph. Round 2 shipped 50ms sampling + 120ms open + 240ms morph and
/// the user's verdict was "only works sometimes... sometimes it doesn't
/// activate" — because a pointer swiped through the zone could be seen once, or
/// not at all, and one sample is never enough to clear a 120ms open delay.
///
///     OPEN   near the top: 20ms sample + 40ms hysteresis + 240ms morph
///                          =  60ms to start moving, ~300ms to fully open
///            cold (pointer arrives from the far side of the screen, worst case):
///                          = 100ms + 40 + 240 = ~380ms, and only for the first
///                            sample after a jump — any approach that crosses the
///                            top band is already sampling at 20ms by then.
///     CLOSE  20ms sample + 140ms hysteresis + 240ms morph
///                          = ~160ms to start closing, ~400ms to gone.
///
/// The open delay still has to survive 2-3 consecutive samples at 20ms, so a
/// graze across a corner of the zone will not fire — but a deliberate pass
/// will, which is what was asked for.
public enum HoverTiming {
    /// Hysteresis. Untouched logic, retuned numbers.
    public static let openDelayMs: Int64 = 40
    public static let closeDelayMs: Int64 = 140

    /// Pointer sampling. Fast whenever the pointer is anywhere near the top of
    /// the screen (or the HUD is open, since an open HUD must close promptly);
    /// idle everywhere else, because a 50 Hz timer running while the user is
    /// typing in another app is a battery cost with no user at all.
    public static let fastSampleSeconds: TimeInterval = 0.02
    public static let idleSampleSeconds: TimeInterval = 0.10
    /// How far down from the top edge counts as "worth watching closely".
    public static let fastBandDepth: CGFloat = 100

    /// The log is drained on its own schedule, independent of the pointer
    /// cadence — reading the file is the expensive half and nothing about hover
    /// responsiveness is improved by doing it more often.
    public static let drainIntervalMs: Int64 = 200
}

/// Hysteresis for the notch. Pure and clock-driven, because "the panel vanishes
/// when the pointer crosses a seam" is the single most common way a hover UI
/// feels broken — and it is untestable if the timing lives in the view layer.
public struct HoverPolicy: Sendable, Equatable {
    private enum Phase: Equatable { case collapsed, opening(at: Int64), expanded, closing(at: Int64) }

    public let openDelayMs: Int64
    public let closeDelayMs: Int64
    private var phase: Phase = .collapsed

    public init(openDelayMs: Int64 = HoverTiming.openDelayMs,
                closeDelayMs: Int64 = HoverTiming.closeDelayMs) {
        self.openDelayMs = openDelayMs
        self.closeDelayMs = closeDelayMs
    }

    public var isExpanded: Bool {
        switch phase { case .expanded, .closing: true; default: false }
    }

    public mutating func handle(_ input: HoverInput, nowMs: Int64) {
        switch (input, phase) {
        case (.entered, .collapsed):        phase = .opening(at: nowMs)
        case (.entered, .closing):          phase = .expanded          // re-entry cancels the close
        case (.entered, .opening), (.entered, .expanded): break
        case (.exited, .opening):           phase = .collapsed          // a flick-through never opens
        case (.exited, .expanded):          phase = .closing(at: nowMs)
        case (.exited, .collapsed), (.exited, .closing): break
        }
    }

    /// Advances time. Returns true only when `isExpanded` actually flipped.
    @discardableResult
    public mutating func tick(nowMs: Int64) -> Bool {
        let before = isExpanded
        switch phase {
        case .opening(let at) where nowMs - at >= openDelayMs:  phase = .expanded
        case .closing(let at) where nowMs - at >= closeDelayMs: phase = .collapsed
        default: break
        }
        return isExpanded != before
    }
}
