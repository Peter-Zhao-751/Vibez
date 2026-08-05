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
    var asked = 0
}

@MainActor
@Test func theTimerPollsForThePointerAndOpensWithoutAnyEvent() async throws {
    let model = HUDViewModel(demo: true)
    let answers = Answers()
    model.pointerProvider = { answers.asked += 1; return answers.next }
    model.start()
    defer { model.stop() }

    // Nothing has moved and nothing was delivered — the model must still be
    // asking.
    try await Task.sleep(for: .milliseconds(250))
    #expect(answers.asked >= 3, "polled only \(answers.asked) times in 250ms")
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

/// A flick through the notch that the poll happens to catch mid-flight must not
/// open the HUD — the hysteresis still owns that decision, and polling must not
/// have quietly bypassed it.
@MainActor
@Test func aSinglePolledSampleInsideTheNotchIsNotEnoughToOpen() async throws {
    let model = HUDViewModel(demo: true)
    let answers = Answers()
    model.pointerProvider = { answers.asked += 1; return answers.next }
    model.start()
    defer { model.stop() }

    answers.next = .entered
    try await Task.sleep(for: .milliseconds(60))     // shorter than the 120ms open delay
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
