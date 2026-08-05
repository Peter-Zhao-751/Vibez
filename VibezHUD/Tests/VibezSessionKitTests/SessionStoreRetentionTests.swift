import Testing
@testable import VibezSessionKit

private func newStore(_ clock: FakeClock) -> SessionStore {
    SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
}

@Test func doneRowsExpireFiveMinutesAfterFinishing() {
    let clock = FakeClock(100_000); let s = newStore(clock)
    s.apply(makeEvent(.prompt, ts: 100_000))
    s.apply(makeEvent(.done, ts: 101_000))
    clock.advance(ms: 4_000)                       // grace elapses, done commits
    #expect(s.snapshot().done.map(\.sid) == ["s1"])
    // FakeClock started 1_000ms behind the done event's own ts (101_000 vs
    // 100_000), so "1ms short of 5 min since the done" needs that gap folded
    // back in: 5*60_000 - 4_000 undershoots retention by 999ms.
    clock.advance(ms: 5 * 60_000 - 3_001)          // 1ms short of 5 min since the done
    #expect(s.snapshot().done.map(\.sid) == ["s1"])
    clock.advance(ms: 2)                           // past 5 min
    #expect(s.snapshot().done.isEmpty)
}

@Test func endedRowsExpireOnTheSameFiveMinuteClock() {
    let clock = FakeClock(100_000); let s = newStore(clock)
    s.apply(makeEvent(.prompt, ts: 100_000))
    s.apply(makeEvent(.end, ts: 101_000))
    #expect(s.snapshot().done.first?.state == .ended)
    clock.advance(ms: 5 * 60_000 + 1_001)
    #expect(s.snapshot().done.isEmpty)
}

@Test func retentionPruningEvictsTheEntryFromMemory() {
    let clock = FakeClock(100_000); let s = newStore(clock)
    s.apply(makeEvent(.prompt, ts: 100_000))
    s.apply(makeEvent(.end, ts: 101_000))
    clock.advance(ms: 5 * 60_000 + 1_001)
    _ = s.snapshot()                               // the prune pass
    #expect(s.stateForTesting(sid: "s1") == nil)   // gone, not just hidden
}

@Test func workingRowsAreNeverTimePruned() {
    let clock = FakeClock(100_000)
    // Live pid: staleness must not end it, retention must not prune it.
    let live = FakeLiveness()
    live.table[4242] = (true, "x")
    let store = SessionStore(config: StoreConfig(), clock: clock, liveness: live)
    store.apply(makeEvent(.prompt, ts: 100_000, agentPid: 4242, agentStart: "x"))
    clock.advance(ms: 60 * 60_000)
    #expect(store.snapshot().working.map(\.sid) == ["s1"])
}
