// VibezHUD/Tests/VibezSessionKitTests/SessionStoreOrderingTests.swift
import Testing
@testable import VibezSessionKit

private func store(_ c: FakeClock) -> SessionStore {
    SessionStore(config: StoreConfig(), clock: c, liveness: FakeLiveness())
}

@Test func aStaleToolHeartbeatCannotUnblockASession() {
    // Hooks fire in parallel; a `tool` can land AFTER a `needs-input` while
    // carrying an EARLIER timestamp. It must not drag the session back to working.
    let clock = FakeClock(); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 1_000))
    s.apply(makeEvent(.needsInput, ts: 2_000))
    s.apply(makeEvent(.tool, ts: 1_500, tool: "Read"))
    #expect(s.stateForTesting(sid: "s1") == .needsYou)
}

@Test func millisecondTiesResolveByPriority() {
    let clock = FakeClock(); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 1_000))
    s.apply(makeEvent(.tool, ts: 2_000))
    s.apply(makeEvent(.needsInput, ts: 2_000))    // same ms, higher priority wins
    #expect(s.stateForTesting(sid: "s1") == .needsYou)

    let clock2 = FakeClock(); let s2 = store(clock2)
    s2.apply(makeEvent(.prompt, ts: 1_000))
    s2.apply(makeEvent(.needsInput, ts: 2_000))
    s2.apply(makeEvent(.tool, ts: 2_000))         // same ms, lower priority loses
    #expect(s2.stateForTesting(sid: "s1") == .needsYou)
}

@Test func duplicateRecordsAreIdempotent() {
    let clock = FakeClock(); let s = store(clock)
    let e = makeEvent(.needsInput, ts: 2_000)
    s.apply(e); s.apply(e); s.apply(e)
    #expect(s.snapshot().needsYou.count == 1)
    #expect(s.stateForTesting(sid: "s1") == .needsYou)
}

@Test func aStaleRecordStillHealsMissingIdentity() {
    // Simulates the `start` line having been rotated away: the first record we
    // ever see is a bare heartbeat, and an older record backfills the name.
    let clock = FakeClock(); let s = store(clock)
    s.apply(makeEvent(.tool, ts: 5_000, proj: "", cwd: "", title: ""))
    s.apply(makeEvent(.start, ts: 1_000, proj: "Vibez", cwd: "/tmp/Vibez", title: "Notch app"))
    let session = s.snapshot().working.first
    #expect(session?.proj == "Vibez")
    #expect(session?.title == "Notch app")
    #expect(session?.state == .working)     // the stale start must NOT reset state
}
