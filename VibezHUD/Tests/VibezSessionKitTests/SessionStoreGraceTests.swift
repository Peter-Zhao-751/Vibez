// VibezHUD/Tests/VibezSessionKitTests/SessionStoreGraceTests.swift
import Testing
@testable import VibezSessionKit

private func store(_ c: FakeClock, grace: Int64 = 3_000) -> SessionStore {
    SessionStore(config: StoreConfig(stopGraceMs: grace), clock: c, liveness: FakeLiveness())
}

@Test func doneCommitsAfterTheGraceWindowElapsesInSilence() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))

    #expect(s.stateForTesting(sid: "s1") == .working)   // provisional — still working
    clock.advance(ms: 2_999)
    #expect(s.stateForTesting(sid: "s1") == .working)
    clock.advance(ms: 1)
    #expect(s.stateForTesting(sid: "s1") == .done)      // committed
}

@Test func activityInsideTheGraceWindowDiscardsTheDone() {
    // The real bug: Stop fires at a turn boundary, the harness auto-resumes ~1s
    // later, and the session was never actually done.
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 1_000)
    s.apply(makeEvent(.tool, ts: 11_000, tool: "Bash"))
    clock.advance(ms: 10_000)
    #expect(s.stateForTesting(sid: "s1") == .working)   // never flashed to done
}

@Test func needsInputInsideTheGraceWindowWins() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 500)
    s.apply(makeEvent(.needsInput, ts: 10_500))
    clock.advance(ms: 10_000)
    #expect(s.stateForTesting(sid: "s1") == .needsYou)
}

@Test func repeatedDoneCommitsOnceAtTheLatestTimestamp() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.done, ts: 10_000))
    s.apply(makeEvent(.done, ts: 10_400))
    clock.advance(ms: 3_000)                             // 3s past the FIRST done
    #expect(s.stateForTesting(sid: "s1") == .working || s.stateForTesting(sid: "s1") == .idle)
    clock.advance(ms: 400)                               // now 3s past the LAST done
    #expect(s.stateForTesting(sid: "s1") == .done)
}

@Test func graceOfZeroCommitsImmediately() {
    // VIBEZ_STOP_GRACE_SECONDS=0 is the documented rollback switch.
    let clock = FakeClock(10_000); let s = store(clock, grace: 0)
    s.apply(makeEvent(.done, ts: 10_000))
    #expect(s.stateForTesting(sid: "s1") == .done)
}
