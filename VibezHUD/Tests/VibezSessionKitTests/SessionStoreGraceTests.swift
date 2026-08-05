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
    // Exactly 3s past the FIRST done. This instant is the discriminator: a
    // reducer that measured grace from the first done would have committed by
    // now (13_000 - 10_000 == 3_000), while one measuring from the latest has
    // only seen 2_600ms elapse. Assert the exact state — `!= .done` (or a
    // disjunction spelling it) would pass under BOTH behaviours and pin nothing.
    // The session never worked, so its state is still .idle.
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .idle)
    clock.advance(ms: 400)                               // now 3s past the LAST done
    #expect(s.stateForTesting(sid: "s1") == .done)
}

@Test func graceOfZeroCommitsImmediately() {
    // VIBEZ_STOP_GRACE_SECONDS=0 is the documented rollback switch.
    let clock = FakeClock(10_000); let s = store(clock, grace: 0)
    s.apply(makeEvent(.done, ts: 10_000))
    #expect(s.stateForTesting(sid: "s1") == .done)
}

@Test func repeatedDoneAfterCommitDoesNotReopenTheGraceWindow() {
    // The flash bug: a second Stop on an already-done session used to
    // overwrite pendingDoneAtMs, and the display reverted to the stored
    // pre-done state for 3s.
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .done)   // committed
    s.apply(makeEvent(.done, ts: 13_100))
    #expect(s.stateForTesting(sid: "s1") == .done)   // STAYS done — no flash
    clock.advance(ms: 10_000)
    #expect(s.stateForTesting(sid: "s1") == .done)
}

@Test func activityAfterACommittedDoneStillResumesWorking() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .done)
    s.apply(makeEvent(.prompt, ts: 14_000))
    #expect(s.stateForTesting(sid: "s1") == .working)
    // stateSince reflects the resume, not the pre-done working stretch.
    #expect(s.snapshot().working.first?.stateSinceMs == 14_000)
}

@Test func startInsideTheGraceWindowCancelsPendingDone() {
    // The grace-window fix only covers activity that ARRIVES after the done.
    // Start is also activity (from the event log), and it ALSO cancels the pending done.
    // A session that becomes done, then resumes before the grace expires, should not
    // flash to done even when the grace window elapses.
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 500)
    // Start inside the grace window cancels pendingDoneAtMs (line: if e.kind != .done { entry.pendingDoneAtMs = nil })
    s.apply(makeEvent(.start, ts: 10_500))
    // The state is still .working (the pre-done state); start doesn't change it.
    #expect(s.stateForTesting(sid: "s1") == .working)
    // Advance past the grace window — the pending done was canceled, so it never commits.
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .working)   // never flashed to .done
}

@Test func startAfterCommittedDoneResetsToIdle() {
    // After the grace window has elapsed and the done commits, a start event
    // should still reset the row to idle for a proper resume display.
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .done)   // committed
    s.apply(makeEvent(.start, ts: 13_500))
    #expect(s.stateForTesting(sid: "s1") == .idle)   // fresh start
}
