import VibezSessionKit

final class FakeClock: Clock, @unchecked Sendable {
    private var _now: Int64
    init(_ start: Int64 = 1_000_000) { _now = start }
    var nowMs: Int64 { _now }
    func advance(ms: Int64) { _now += ms }
    func set(_ ms: Int64) { _now = ms }
}
