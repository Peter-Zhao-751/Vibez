// VibezHUD/Tests/VibezSessionKitTests/POSIXLivenessProbeTests.swift
//
// The REAL probe, against pids this process genuinely knows: its own, one it
// spawned and killed, and one that cannot exist. Every other suite injects
// FakeLiveness, so without this file the shipping probe — the one thing here
// that forks a process on the main actor — would never be executed at all.
import Foundation
import Testing
@testable import VibezSessionKit

/// A pid never handed out on macOS (kern.maxproc tops out five digits below it).
private let impossiblePid: Int32 = Int32.max

/// Zombie-safe: `waitUntilExit()` reaps, but polling turns any residual race
/// into a short wait instead of a flaky failure.
private func waitUntilGone(_ pid: Int32, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if kill(pid, 0) != 0 && errno != EPERM { return true }
        usleep(20_000)
    } while Date() < deadline
    return false
}

@Test func theRealProbeSeesItsOwnProcess() {
    let probe = POSIXLivenessProbe()
    let me = getpid()

    // No recorded start time = "alive is enough", and that path must not fork.
    #expect(probe.isAlive(pid: me, startedAt: nil))
    #expect(probe.isAlive(pid: me, startedAt: ""))
    #expect(probe.psRunCount == 0)

    let mine = POSIXLivenessProbe.readStartTime(of: me)
    #expect(mine != nil)
    #expect(!(mine ?? "").isEmpty)
    #expect(probe.isAlive(pid: me, startedAt: mine))
}

@Test func aProcessStartTimeIsStableAcrossReads() {
    // The memo is only sound because lstart never changes for a live pid.
    let me = getpid()
    let first = POSIXLivenessProbe.readStartTime(of: me)
    usleep(50_000)
    let second = POSIXLivenessProbe.readStartTime(of: me)
    #expect(first != nil)
    #expect(first == second)
}

@Test func repeatedPollsOfALivePidRunPsExactlyOnce() {
    // THE regression: snapshot() calls this per live session at 5 Hz. One `ps`
    // per pid, ever — not one per poll.
    let probe = POSIXLivenessProbe()
    let me = getpid()
    let mine = POSIXLivenessProbe.readStartTime(of: me)
    #expect(mine != nil)

    for _ in 0..<200 { #expect(probe.isAlive(pid: me, startedAt: mine)) }
    #expect(probe.psRunCount == 1)
    #expect(probe.cachedStartTime(of: me) == mine)
}

@Test func memoizedPollsAreFasterThanForkingEveryTime() {
    // Belt-and-braces on the counter: the wall-clock cost of 100 memoized polls
    // must be a fraction of 100 real `ps` runs. Ratio, not an absolute budget,
    // so a loaded machine can't flake it.
    let probe = POSIXLivenessProbe()
    let me = getpid()
    let mine = POSIXLivenessProbe.readStartTime(of: me)
    _ = probe.isAlive(pid: me, startedAt: mine)     // prime the memo

    let memoStart = Date()
    for _ in 0..<100 { _ = probe.isAlive(pid: me, startedAt: mine) }
    let memoized = Date().timeIntervalSince(memoStart)

    let forkStart = Date()
    for _ in 0..<10 { _ = POSIXLivenessProbe.readStartTime(of: me) }
    let tenForks = Date().timeIntervalSince(forkStart)

    #expect(memoized < tenForks)
    #expect(probe.psRunCount == 1)
}

@Test func aRecycledPidIsCaughtByTheStartTimeMismatch() {
    // Alive, but the recorded start time belongs to a different process.
    let probe = POSIXLivenessProbe()
    let me = getpid()
    #expect(probe.isAlive(pid: me, startedAt: "Mon Jan  1 00:00:00 2001") == false)
    #expect(probe.psRunCount == 1)
    // ...and the second look reuses the memo rather than re-forking.
    #expect(probe.isAlive(pid: me, startedAt: "Mon Jan  1 00:00:00 2001") == false)
    #expect(probe.psRunCount == 1)
}

@Test func anImpossiblePidIsNeverAlive() {
    let probe = POSIXLivenessProbe()
    #expect(probe.isAlive(pid: impossiblePid, startedAt: nil) == false)
    #expect(probe.isAlive(pid: impossiblePid, startedAt: "whenever") == false)
    #expect(probe.isAlive(pid: 0, startedAt: nil) == false)
    #expect(probe.isAlive(pid: -1, startedAt: nil) == false)
    // A dead pid short-circuits at kill(2) — it must never reach `ps`.
    #expect(probe.psRunCount == 0)
}

@Test func aPidThatDiesIsReportedDeadAndDropsItsMemo() {
    let probe = POSIXLivenessProbe()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "sleep 30"]
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try? child.run()
    let pid = child.processIdentifier
    #expect(pid > 0)

    let started = POSIXLivenessProbe.readStartTime(of: pid)
    #expect(started != nil)
    #expect(probe.isAlive(pid: pid, startedAt: started))
    #expect(probe.cachedStartTime(of: pid) == started)

    child.terminate()
    child.waitUntilExit()
    #expect(waitUntilGone(pid))

    #expect(probe.isAlive(pid: pid, startedAt: started) == false)
    // Evicted, so the pid's next tenant re-probes instead of inheriting this
    // process's start time and passing the recycling check.
    #expect(probe.cachedStartTime(of: pid) == nil)
}

@Test func theStoreDrivesTheRealProbeEndToEnd() {
    // Wiring check: the default SessionStore probe is the POSIX one, and a
    // session pinned to THIS process (alive, correct start time) survives a
    // snapshot far past the staleness window.
    let me = getpid()
    let mine = POSIXLivenessProbe.readStartTime(of: me)
    let clock = FakeClock(1_000_000)
    let store = SessionStore(config: StoreConfig(staleMs: 1),
                             clock: clock,
                             liveness: POSIXLivenessProbe())
    store.apply(makeEvent(.start, ts: 1_000_000, agentPid: me, agentStart: mine))
    store.apply(makeEvent(.prompt, ts: 1_000_001))
    clock.advance(ms: 10 * 60_000)
    #expect(store.stateForTesting(sid: "s1") == .working)

    let dead = SessionStore(clock: FakeClock(1_000_000), liveness: POSIXLivenessProbe())
    dead.apply(makeEvent(.start, ts: 1_000_000, agentPid: impossiblePid, agentStart: "whenever"))
    dead.apply(makeEvent(.prompt, ts: 1_000_001))
    #expect(dead.stateForTesting(sid: "s1") == .ended)
}
