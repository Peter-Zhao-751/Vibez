import Foundation

public enum HoverInput: Sendable, Equatable { case entered, exited }

/// Hysteresis for the notch. Pure and clock-driven, because "the panel vanishes
/// when the pointer crosses a seam" is the single most common way a hover UI
/// feels broken — and it is untestable if the timing lives in the view layer.
public struct HoverPolicy: Sendable, Equatable {
    private enum Phase: Equatable { case collapsed, opening(at: Int64), expanded, closing(at: Int64) }

    public let openDelayMs: Int64
    public let closeDelayMs: Int64
    private var phase: Phase = .collapsed

    public init(openDelayMs: Int64 = 120, closeDelayMs: Int64 = 350) {
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
