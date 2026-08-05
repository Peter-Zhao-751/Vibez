import Foundation

/// Publishes wall-clock time to the view layer at 1 Hz.
///
/// The age label on a tile ("45s") is derived from the CURRENT time, not from
/// anything inside the snapshot. The 5 Hz poll deliberately stops assigning an
/// unchanged snapshot — @Observable invalidates on assignment, so re-assigning
/// an equal value re-rendered the whole panel five times a second forever — but
/// that removed the only thing that was (accidentally) driving those labels. A
/// quiet log then froze every counter for as long as the panel stayed open,
/// which reads as a hung HUD, and hovering a NEEDS YOU row while nothing is
/// happening is exactly the state you open the panel in.
///
/// So the view model publishes a clock as well, quantised to whole seconds: the
/// labels stay alive at the resolution they actually display, the panel
/// re-renders 1x/sec instead of 10, and the collapsed ears never read it at all.
public struct AgeClock: Sendable, Equatable {
    public private(set) var publishedMs: Int64

    public init(nowMs: Int64) { publishedMs = nowMs }

    /// True — and advances the published value — when `nowMs` falls in a
    /// different whole second than the last publish.
    ///
    /// `!=`, not `>`: a backwards step (NTP correction, sleep/wake) must
    /// republish rather than freeze the labels until the clock catches up.
    public mutating func advance(toMs nowMs: Int64) -> Bool {
        guard nowMs / 1_000 != publishedMs / 1_000 else { return false }
        publishedMs = nowMs
        return true
    }
}
