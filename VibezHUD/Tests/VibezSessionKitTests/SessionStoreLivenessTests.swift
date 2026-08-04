// VibezHUD/Tests/VibezSessionKitTests/SessionStoreLivenessTests.swift
import Testing
@testable import VibezSessionKit

@Test func aLivePidKeepsAQuietSessionAlive() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, "Mon Aug  4 20:58:08 2026")
    let s = SessionStore(config: StoreConfig(staleMs: 60_000), clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 1_000_000, agentPid: 999, agentStart: "Mon Aug  4 20:58:08 2026"))
    s.apply(makeEvent(.prompt, ts: 1_000_001))
    clock.advance(ms: 10 * 60_000)          // far past staleMs
    #expect(s.stateForTesting(sid: "s1") == .working)
}

@Test func aDeadPidEndsTheSessionImmediately() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness()               // pid absent => not running
    let s = SessionStore(clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 1_000_000, agentPid: 999, agentStart: "start-a"))
    s.apply(makeEvent(.prompt, ts: 1_000_001))
    #expect(s.stateForTesting(sid: "s1") == .ended)
}

@Test func aRecycledPidDoesNotResurrectASession() {
    // Same pid, different process start time — macOS recycles PIDs.
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, "SOMEONE ELSE")
    let s = SessionStore(clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 1_000_000, agentPid: 999, agentStart: "start-a"))
    s.apply(makeEvent(.prompt, ts: 1_000_001))
    #expect(s.stateForTesting(sid: "s1") == .ended)
}

@Test func anUnknownPidIsUnknownNotDead() {
    // A session whose `start` line rotated away has no pid. It must keep running
    // until staleness ends it — treating "no pid" as "dead" would wipe live rows.
    let clock = FakeClock(1_000_000)
    let s = SessionStore(config: StoreConfig(staleMs: 60_000), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 1_000_000))
    #expect(s.stateForTesting(sid: "s1") == .working)
    clock.advance(ms: 59_000)
    #expect(s.stateForTesting(sid: "s1") == .working)
    clock.advance(ms: 2_000)
    #expect(s.stateForTesting(sid: "s1") == .ended)
}

@Test func finishedSessionsDropOutAfterRetention() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, nil)
    let s = SessionStore(config: StoreConfig(stopGraceMs: 0, retentionMs: 60_000),
                         clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 999_999, agentPid: 999))
    // The done's ts must not lead the clock: with stopGraceMs 0 the commit
    // check is `now - pending >= 0`, so a done stamped even 1ms in the future
    // stays provisional until the clock catches up.
    s.apply(makeEvent(.done, ts: 1_000_000))
    #expect(s.snapshot().done.count == 1)
    clock.advance(ms: 61_000)
    #expect(s.snapshot().done.isEmpty)
}

@Test func columnsSortByUrgencyThenRecency() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, nil)
    let s = SessionStore(clock: clock, liveness: live)
    s.apply(makeEvent(.needsInput, ts: 900_000, sid: "old", agentPid: 999))
    s.apply(makeEvent(.needsInput, ts: 990_000, sid: "new", agentPid: 999))
    s.apply(makeEvent(.tool, ts: 800_000, sid: "w1", agentPid: 999))
    s.apply(makeEvent(.tool, ts: 999_000, sid: "w2", agentPid: 999))
    let snap = s.snapshot()
    #expect(snap.needsYou.map(\.sid) == ["old", "new"])   // longest wait first
    #expect(snap.working.map(\.sid) == ["w2", "w1"])      // most recent first
}
