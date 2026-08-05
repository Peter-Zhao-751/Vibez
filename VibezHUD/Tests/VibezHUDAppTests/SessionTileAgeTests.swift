// VibezHUD/Tests/VibezHUDAppTests/SessionTileAgeTests.swift
//
// The age label must be a pure function of the clock it is HANDED. Reading
// `Date()` inside the view instead is what froze the counter: nothing observed
// changes, so SwiftUI has no reason to re-run the body, and "45s" stays "45s"
// for as long as the panel is open. Every expectation below collapses if that
// regresses — a Date()-derived label returns the same string for all of them.
import Testing
import VibezSessionKit
@testable import VibezHUDApp

private func session(stateSinceMs: Int64) -> Session {
    Session(sid: "s1", agent: .claude, proj: "Vibez", cwd: "/tmp/Vibez", title: "Notch app",
            detail: nil, tool: nil, state: .needsYou,
            startedAtMs: stateSinceMs, lastActivityMs: stateSinceMs, stateSinceMs: stateSinceMs,
            agentPid: nil, agentStart: nil, appPid: nil, app: nil)
}

private func age(at nowMs: Int64, since: Int64 = 1_000_000) -> String {
    SessionTile(session: session(stateSinceMs: since), nowMs: nowMs, onTap: { _ in }).elapsed
}

@Test func theAgeLabelReadsThePassedClockAndNotTheWallClock() {
    #expect(age(at: 1_000_000) == "0s")
    #expect(age(at: 1_045_000) == "45s")
    #expect(age(at: 1_059_999) == "59s")
    #expect(age(at: 1_060_000) == "1m")
    #expect(age(at: 1_000_000 + 3_599_000) == "59m")
    #expect(age(at: 1_000_000 + 7_200_000) == "2h")
}

@Test func aLaterClockAlwaysMeansALaterAge() {
    // The frozen label in one line: advancing only the clock must move the text.
    #expect(age(at: 1_045_000) != age(at: 1_046_000))
    #expect(age(at: 1_045_000) != age(at: 1_120_000))
}

@Test func aClockBehindTheEventClampsToZeroRatherThanGoingNegative() {
    #expect(age(at: 999_000) == "0s")
}
