import Testing
@testable import VibezHUDApp

@Test func openingWaitsOutTheDelay() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000)
    #expect(!p.isExpanded)
    _ = p.tick(nowMs: 1_119)
    #expect(!p.isExpanded)
    _ = p.tick(nowMs: 1_120)
    #expect(p.isExpanded)
}

@Test func aFlickThroughTheNotchNeverOpensIt() {
    // Pointer crosses the notch on its way somewhere else.
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000)
    p.handle(.exited, nowMs: 1_040)
    _ = p.tick(nowMs: 5_000)
    #expect(!p.isExpanded)
}

@Test func closingIsForgivingAndCancelledByReentry() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000); _ = p.tick(nowMs: 1_200)
    #expect(p.isExpanded)

    p.handle(.exited, nowMs: 2_000)
    _ = p.tick(nowMs: 2_200)
    #expect(p.isExpanded, "must survive the pointer crossing a seam")

    p.handle(.entered, nowMs: 2_250)      // came back
    _ = p.tick(nowMs: 9_000)
    #expect(p.isExpanded, "re-entry cancels the pending close")
}

@Test func closingCompletesWhenThePointerStaysAway() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000); _ = p.tick(nowMs: 1_200)
    p.handle(.exited, nowMs: 2_000)
    _ = p.tick(nowMs: 2_349)
    #expect(p.isExpanded)
    _ = p.tick(nowMs: 2_350)
    #expect(!p.isExpanded)
}

@Test func tickReportsOnlyRealChanges() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000)
    #expect(p.tick(nowMs: 1_050) == false)
    #expect(p.tick(nowMs: 1_120) == true)     // opened
    #expect(p.tick(nowMs: 1_500) == false)    // steady
}
