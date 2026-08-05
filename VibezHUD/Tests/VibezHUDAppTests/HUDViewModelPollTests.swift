// VibezHUD/Tests/VibezHUDAppTests/HUDViewModelPollTests.swift
//
// The wiring behind the hover rewrite: the timer POLLS for the pointer, so a
// HUD that opens now needs no event to have been delivered to anything. The old
// mechanism (global/local `.mouseMoved` monitors) is what failed on the user's
// machine — it opened only on a click — and nothing in a unit test could have
// caught that, because the monitor either fires or it doesn't. What can be
// pinned is this: the model asks, every tick, without being told to.
import Foundation
import Testing
@testable import VibezHUDApp
import VibezSessionKit

private final class Answers: @unchecked Sendable {
    var next: HoverInput = .exited
    /// The pointer is reported near the top so the model runs its FAST cadence,
    /// which is the one a user hovering the notch actually gets.
    var nearTop = true
    var asked = 0
    var reading: PointerReading { PointerReading(hover: next, nearTop: nearTop) }
}

@MainActor
@Test func theTimerPollsForThePointerAndOpensWithoutAnyEvent() async throws {
    let model = HUDViewModel(demo: true)
    let answers = Answers()
    model.pointerProvider = { answers.asked += 1; return answers.reading }
    model.start()
    defer { model.stop() }

    // Nothing has moved and nothing was delivered — the model must still be
    // asking, and at the fast cadence, because the pointer is near the top.
    try await Task.sleep(for: .milliseconds(250))
    #expect(answers.asked >= 6, "polled only \(answers.asked) times in 250ms")
    #expect(model.isExpanded == false)

    // The pointer is now on the notch. No `hoverChanged` call, no event, no
    // monitor: only the poll can notice this.
    answers.next = .entered
    try await Task.sleep(for: .milliseconds(400))
    #expect(model.isExpanded == true)

    // ...and leaving closes it again, through the same one mechanism.
    answers.next = .exited
    try await Task.sleep(for: .milliseconds(600))
    #expect(model.isExpanded == false)
}

/// A graze the poll happens to catch mid-flight must not open the HUD — the
/// hysteresis still owns that decision, and polling must not have quietly
/// bypassed it. The window is narrower than it was (40ms, not 120ms) because a
/// deliberate pass through the notch is now MEANT to open it; what must still
/// not open it is a single stray sample.
@MainActor
@Test func aSinglePolledSampleInsideTheNotchIsNotEnoughToOpen() async throws {
    let model = HUDViewModel(demo: true)
    let answers = Answers()
    model.pointerProvider = { answers.asked += 1; return answers.reading }
    model.start()
    defer { model.stop() }

    answers.next = .entered
    try await Task.sleep(for: .milliseconds(15))     // shorter than the 40ms open delay
    answers.next = .exited
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.isExpanded == false)
}

// MARK: - The frozen expanded size
//
// The island's target height comes from this row count, and the log is drained
// five times a second. A session landing mid-morph used to be able to move the
// target the animation was already flying toward — a second movement inside the
// first, which is one of the three things "it pops up twice" could have been.
// (The measured cause was spring overshoot; this closes the other door, and
// stops the island resizing under a pointer that is reading it.)

private func snap(needsYou: Int, done: Int, working: Int) -> HUDSnapshot {
    func rows(_ n: Int, _ state: SessionState) -> [Session] {
        (0..<n).map {
            Session(sid: "s\($0)\(state)", agent: .claude, proj: "p", cwd: "/tmp", title: "t",
                    detail: nil, tool: nil, state: state, startedAtMs: 0, lastActivityMs: 0,
                    stateSinceMs: 0, agentPid: nil, agentStart: nil, appPid: nil, app: nil)
        }
    }
    return HUDSnapshot(needsYou: rows(needsYou, .needsYou),
                       done: rows(done, .done),
                       working: rows(working, .working))
}

@Test func collapsedTheRowCountFollowsTheLongestColumn() {
    #expect(HUDViewModel.rowCount(current: 1, snapshot: snap(needsYou: 2, done: 5, working: 3),
                                 isExpanded: false) == 5)
    // Never zero: an empty island still has a minimum height.
    #expect(HUDViewModel.rowCount(current: 4, snapshot: snap(needsYou: 0, done: 0, working: 0),
                                 isExpanded: false) == 1)
}

@Test func expandedTheRowCountIsFrozenNoMatterWhatArrives() {
    let busy = snap(needsYou: 9, done: 9, working: 9)
    #expect(HUDViewModel.rowCount(current: 2, snapshot: busy, isExpanded: true) == 2)
    // ...including shrinking, which would yank the floor out from under a
    // pointer already inside the board.
    #expect(HUDViewModel.rowCount(current: 6, snapshot: snap(needsYou: 1, done: 0, working: 0),
                                  isExpanded: true) == 6)
}

// MARK: - Adaptive sampling
//
// "It only works sometimes" was a sampling-rate bug: at 50ms a pointer swiped
// across the notch could be seen once, or not at all, and one sample can never
// clear the open delay. The cadence rule is pure, so it is pinned here; the
// warp harness proves the effect on the real panel.

@Test func samplingGoesFastNearTheTopAndIdlesEverywhereElse() {
    let atTop = PointerReading(hover: .exited, nearTop: true)
    let away = PointerReading(hover: .exited, nearTop: false)
    #expect(HUDViewModel.wantsFastSampling(reading: atTop, isExpanded: false))
    #expect(!HUDViewModel.wantsFastSampling(reading: away, isExpanded: false))
}

/// An OPEN HUD samples fast wherever the pointer is: the island is 200pt tall,
/// far deeper than the near-top band, and an open HUD that is slow to notice the
/// pointer leaving is slow to get out of the user's way.
@Test func anOpenHUDAlwaysSamplesFast() {
    let away = PointerReading(hover: .entered, nearTop: false)
    #expect(HUDViewModel.wantsFastSampling(reading: away, isExpanded: true))
}

/// The near-top band is a cue, not a hit-test: it has to be much bigger than the
/// hover zone so a pointer travelling toward the notch is already being sampled
/// quickly by the time it arrives.
@Test func theFastBandIsFarBiggerThanTheHoverZone() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let geo = NotchGeometry(metrics: ScreenMetrics(
        frame: screen, safeAreaTopInset: 32,
        auxLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
        auxRight: CGRect(x: 856, y: 950, width: 656, height: 32)))
    #expect(NotchHoverRouter.isNearTop(pointer: CGPoint(x: 756, y: 966), screen: screen))
    #expect(NotchHoverRouter.isNearTop(pointer: CGPoint(x: 100, y: 900), screen: screen))
    #expect(!NotchHoverRouter.isNearTop(pointer: CGPoint(x: 756, y: 700), screen: screen))
    // Deeper than the hot zone, so the fast cadence is already running before
    // the pointer can possibly enter it.
    #expect(screen.maxY - HoverTiming.fastBandDepth < geo.hoverRect.minY)
}
