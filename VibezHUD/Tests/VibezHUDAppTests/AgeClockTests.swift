// VibezHUD/Tests/VibezHUDAppTests/AgeClockTests.swift
//
// The quantisation the age labels ride on. What must hold: it emits often
// enough that a "45s" label never freezes with the panel open, and rarely
// enough that it doesn't undo the 5 Hz re-render suppression it was added
// alongside — at most one change per second, whatever the tick rate.
import Testing
@testable import VibezHUDApp

@Test func aBurstOfTicksInsideOneSecondPublishesNothing() {
    var c = AgeClock(nowMs: 10_000)
    for ms in stride(from: 10_100, through: 10_900, by: 100) {
        #expect(c.advance(toMs: Int64(ms)) == false)
    }
    #expect(c.publishedMs == 10_000)
}

@Test func crossingASecondPublishesExactlyOnce() {
    var c = AgeClock(nowMs: 10_900)
    #expect(c.advance(toMs: 11_000) == true)     // crossed into the next second
    #expect(c.publishedMs == 11_000)
    #expect(c.advance(toMs: 11_100) == false)    // same second again
    #expect(c.advance(toMs: 11_999) == false)
    #expect(c.advance(toMs: 12_000) == true)
}

@Test func theTenHertzTimerPublishesAtOneHertz() {
    // 10 s of the real tick rate (100 ms) — the labels update every second and
    // the panel re-renders 10x fewer times than the timer fires.
    var c = AgeClock(nowMs: 0)
    var publishes = 0
    for step in 1...100 where c.advance(toMs: Int64(step) * 100) { publishes += 1 }
    #expect(publishes == 10)
}

@Test func everySecondOfAHoverGetsExactlyOnePublish() {
    // The frozen-label bug in miniature: hold the panel open for a minute with
    // nothing else changing. One publish per elapsed second, no more, no fewer.
    var c = AgeClock(nowMs: 1_000_000)
    var publishes = 0
    for step in 1...600 where c.advance(toMs: 1_000_000 + Int64(step) * 100) { publishes += 1 }
    #expect(publishes == 60)
}

@Test func aBackwardsClockRepublishesInsteadOfFreezing() {
    // NTP correction / sleep-wake. `>` would stall every label until wall-clock
    // time caught back up to the last published value.
    var c = AgeClock(nowMs: 60_000)
    #expect(c.advance(toMs: 30_000) == true)
    #expect(c.publishedMs == 30_000)
}

@Test func aJumpForwardPublishesOnceNotOncePerSkippedSecond() {
    var c = AgeClock(nowMs: 1_000)
    #expect(c.advance(toMs: 999_000) == true)
    #expect(c.advance(toMs: 999_100) == false)
}
