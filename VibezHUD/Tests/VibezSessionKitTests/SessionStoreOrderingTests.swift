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

@Test func rowsSharingAMillisecondKeepAStableOrderAcrossSnapshots() {
    // The store walks a DICTIONARY, and Swift's sort is not stable: rows with
    // equal timestamps would otherwise be free to swap places on every 5 Hz
    // poll. sid is the tiebreaker, in all three columns.
    let clock = FakeClock(); let s = store(clock)
    for sid in ["mike", "alpha", "zulu", "delta"] {
        s.apply(makeEvent(.needsInput, ts: 2_000, sid: "n-\(sid)"))
        s.apply(makeEvent(.tool, ts: 3_000, sid: "w-\(sid)"))
        s.apply(makeEvent(.done, ts: 1_000, sid: "d-\(sid)"))
    }
    clock.advance(ms: 10_000)               // commit the provisional dones

    let first = s.snapshot()
    #expect(first.needsYou.map(\.sid) == ["n-alpha", "n-delta", "n-mike", "n-zulu"])
    #expect(first.working.map(\.sid) == ["w-alpha", "w-delta", "w-mike", "w-zulu"])
    #expect(first.done.map(\.sid) == ["d-alpha", "d-delta", "d-mike", "d-zulu"])

    for _ in 0..<25 {
        let again = s.snapshot()
        #expect(again == first)
    }
}

@Test func theTiebreakerNeverOutranksTheTimestamp() {
    let clock = FakeClock(); let s = store(clock)
    // "zulu" waits longest / is most recent, so it leads despite sorting last.
    s.apply(makeEvent(.needsInput, ts: 1_000, sid: "zulu"))
    s.apply(makeEvent(.needsInput, ts: 2_000, sid: "alpha"))
    #expect(s.snapshot().needsYou.map(\.sid) == ["zulu", "alpha"])

    let clock2 = FakeClock(); let s2 = store(clock2)
    s2.apply(makeEvent(.tool, ts: 2_000, sid: "zulu"))
    s2.apply(makeEvent(.tool, ts: 1_000, sid: "alpha"))
    #expect(s2.snapshot().working.map(\.sid) == ["zulu", "alpha"])
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
