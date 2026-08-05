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
