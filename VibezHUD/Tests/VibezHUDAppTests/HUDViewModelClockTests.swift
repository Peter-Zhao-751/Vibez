// VibezHUD/Tests/VibezHUDAppTests/HUDViewModelClockTests.swift
//
// AgeClockTests pins the quantisation; this pins the WIRING — that a tick with
// no new records still moves an OBSERVED property, which is the whole reason
// the age labels keep ticking now that an unchanged snapshot is not reassigned.
// (SwiftUI's redraw itself needs a view host and isn't asserted here; what is
// asserted is that an observer of `clockMs` gets notified. HUDRootView reads
// `model.clockMs` inside its body, which is the other half.)
import Foundation
import Observation
import Testing
@testable import VibezHUDApp

private final class Box: @unchecked Sendable { var fired = false }

@MainActor
@Test func aQuietTickStillNotifiesObserversOfTheClock() async throws {
    // demo: true keeps the engine (and the log file) out of it — the point is
    // that NOTHING changes except wall-clock time.
    let model = HUDViewModel(demo: true)
    let before = model.clockMs
    let snapshotBefore = model.snapshot

    let box = Box()
    withObservationTracking { _ = model.clockMs } onChange: { box.fired = true }

    try await Task.sleep(for: .milliseconds(1_100))     // cross a second boundary
    model.hoverChanged(.entered)                        // drives one tick()

    #expect(model.clockMs > before)
    #expect(model.clockMs - before >= 1_000)
    #expect(box.fired)
    // ...and it did so without the snapshot moving at all, which is the exact
    // situation the frozen label showed up in.
    #expect(model.snapshot == snapshotBefore)
}

@MainActor
@Test func repeatedTicksInsideOneSecondNotifyNobody() {
    // Twenty ticks in well under a second: the re-render suppression finding 6
    // added must survive this fix. Asserting on the OBSERVER, not just on the
    // value — @Observable invalidates on assignment, so re-assigning an equal
    // timestamp would still re-render the panel while leaving `clockMs` equal.
    let model = HUDViewModel(demo: true)
    let before = model.clockMs
    let box = Box()
    withObservationTracking { _ = model.clockMs } onChange: { box.fired = true }
    for _ in 0..<20 { model.hoverChanged(.entered) }
    #expect(model.clockMs == before)
    #expect(box.fired == false)
}
