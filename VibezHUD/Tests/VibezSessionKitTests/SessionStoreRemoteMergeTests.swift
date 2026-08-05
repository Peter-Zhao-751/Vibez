import Testing
@testable import VibezSessionKit

private func remoteSession(sid: String, state: SessionState, machine: String = "mbp-air",
                           atMs ts: Int64) -> Session {
    Session(sid: sid, agent: .codex, proj: "", cwd: "", title: "Remote task",
            detail: nil, tool: nil, state: state,
            startedAtMs: ts, lastActivityMs: ts, stateSinceMs: ts,
            agentPid: nil, agentStart: nil, appPid: nil, app: nil,
            machine: machine)
}

@Test func remoteSessionsJoinTheirColumns() {
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    let snap = s.snapshot(remote: [
        remoteSession(sid: "r1", state: .needsYou, atMs: 99_000),
        remoteSession(sid: "r2", state: .done, atMs: 99_500),
        remoteSession(sid: "r3", state: .working, atMs: 99_900),
    ])
    #expect(snap.needsYou.map(\.sid) == ["r1"])
    #expect(snap.done.map(\.sid) == ["r2"])
    #expect(snap.working.map(\.sid) == ["r3"])
    #expect(snap.needsYou.first?.machine == "mbp-air")
}

@Test func localSidWinsOverItsRemoteEcho() {
    // The local log is strictly richer — a session this Mac owns must not
    // duplicate as a remote row when its push echoes back via the server.
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 99_000, sid: "shared"))
    let snap = s.snapshot(remote: [remoteSession(sid: "shared", state: .done, atMs: 99_500)])
    #expect(snap.working.map(\.sid) == ["shared"])   // local working row
    #expect(snap.done.isEmpty)                       // remote echo dropped
}

@Test func remoteRowsSortWithLocalRows() {
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.needsInput, ts: 99_800, sid: "local"))
    let snap = s.snapshot(remote: [remoteSession(sid: "r1", state: .needsYou, atMs: 99_100)])
    // needsYou sorts longest-wait-first: the remote row has waited longer.
    #expect(snap.needsYou.map(\.sid) == ["r1", "local"])
}

@Test func localSessionsHaveNilMachine() {
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 99_000))
    #expect(s.snapshot().working.first?.machine == nil)
}

@Test func localEvictionDoesNotResurrectTheRemoteEcho() {
    // A session this Mac owned, asked, and then ended: once its row evicts
    // (past retention), the sid must stay dead even though the server's
    // event log can still hold a needs-input/replied doc for it for up to
    // staleMs. Without a tombstone, eviction un-does "local wins" and a
    // stale remote row resurrects as a phantom NEEDS YOU.
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 100_000, sid: "shared"))
    s.apply(makeEvent(.end, ts: 101_000, sid: "shared"))
    clock.advance(ms: 5 * 60_000 + 1_001)   // past retention
    _ = s.snapshot()                        // the evicting pass — stamps the tombstone
    let snap = s.snapshot(remote: [
        remoteSession(sid: "shared", state: .needsYou, atMs: clock.nowMs - 1_000),
    ])
    #expect(snap.needsYou.isEmpty)
}

@Test func tombstonesExpireAfterStaleMs() {
    // The tombstone itself must not leak forever — once staleMs has passed
    // since eviction, a FRESH remote row for the same sid is a legitimately
    // new session (e.g. resumed on another machine) and should appear.
    let clock = FakeClock(100_000)
    let s = SessionStore(config: StoreConfig(), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 100_000, sid: "shared"))
    s.apply(makeEvent(.end, ts: 101_000, sid: "shared"))
    clock.advance(ms: 5 * 60_000 + 1_001)   // past retention
    _ = s.snapshot()                        // evicts, stamps the tombstone
    clock.advance(ms: 30 * 60_000 + 1)      // past staleMs beyond the eviction
    _ = s.snapshot()                        // prunes the expired tombstone
    let snap = s.snapshot(remote: [
        remoteSession(sid: "shared", state: .needsYou, atMs: clock.nowMs - 1_000),
    ])
    #expect(snap.needsYou.map(\.sid) == ["shared"])
}
