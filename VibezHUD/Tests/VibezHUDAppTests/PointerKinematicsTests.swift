// VibezHUD/Tests/VibezHUDAppTests/PointerKinematicsTests.swift
//
// The predictive exit is the first thing in this app that acts on a GUESS, so
// every part of the guess is pinned here with fabricated motion: the derivatives
// it is built from, the rule that fires it, and — most importantly — what
// happens when it is wrong.
import Testing
import CoreGraphics
import Foundation
@testable import VibezHUDApp

private let tuning = HoverTuning.compiled

/// Straight-line motion at a known speed, sampled every 20ms like the real poll,
/// arranged so the LAST sample lands exactly on `end` — the pointer's position
/// right now is what every rule below is stated about.
private func track(to end: CGPoint, velocity v: CGVector,
                   samples n: Int = 6, stepMs: Int64 = 20) -> PointerKinematics {
    var k = PointerKinematics()
    for i in 0..<n {
        let back = Double(n - 1 - i) * Double(stepMs) / 1000
        k.record(CGPoint(x: end.x - v.dx * back, y: end.y - v.dy * back), tMs: Int64(i) * stepMs)
    }
    return k
}

// MARK: - The derivatives

@Test func velocityRecoversAKnownSpeed() {
    let k = track(to: CGPoint(x: 0, y: 0), velocity: CGVector(dx: 0, dy: -900))
    #expect(abs(k.velocity.dy - -900) < 1)
    #expect(abs(k.velocity.dx) < 1)
    #expect(abs(k.speed - 900) < 1)
}

@Test func aStillPointerHasNoVelocityAndNoProjection() {
    var k = PointerKinematics()
    for i in 0..<6 { k.record(CGPoint(x: 500, y: 900), tMs: Int64(i) * 20) }
    #expect(k.speed == 0)
    #expect(k.projected(afterMs: 120) == CGPoint(x: 500, y: 900))
}

@Test func oneSampleProjectsNothingRatherThanGuessing() {
    var k = PointerKinematics()
    k.record(CGPoint(x: 1, y: 2), tMs: 0)
    #expect(k.projected(afterMs: 120) == nil)
    #expect(k.speed == 0)
}

@Test func accelerationShowsUpWhenTheMotionIsSpeedingUp() {
    var k = PointerKinematics()
    // y = -½·a·t² with a = 20000 pt/s²: each step covers more ground than the last.
    for i in 0..<8 {
        let t = Double(i) * 0.02
        k.record(CGPoint(x: 0, y: -0.5 * 20_000 * t * t), tMs: Int64(i) * 20)
    }
    #expect(k.acceleration.dy < -5_000, "measured \(k.acceleration.dy)")
    // ...and the projection therefore reaches FARTHER than velocity alone would.
    let linear = k.velocity.dy * 0.12
    #expect(k.projected(afterMs: 120)!.y < k.latest!.y + linear)
}

@Test func theRingBufferStaysBounded() {
    let k = track(to: CGPoint(x: 0, y: 0), velocity: CGVector(dx: 100, dy: 0), samples: 200)
    #expect(k.samples.count == PointerKinematics.capacity)
}

/// A repeated or out-of-order timestamp must not divide by zero or corrupt the
/// window — the poll can fire twice inside one millisecond.
@Test func duplicateTimestampsAreHarmless() {
    var k = PointerKinematics()
    for _ in 0..<5 { k.record(CGPoint(x: 10, y: 10), tMs: 7) }
    #expect(k.speed.isFinite)
    #expect(k.samples.count == 1)
}

// MARK: - The rule

private let zone = CGRect(x: 200, y: 700, width: 1000, height: 280)   // an expanded island

@Test func aFastDepartureIsCalledWhileThePointerIsStillInside() {
    // Deep inside, heading down hard: 120ms of this lands far below the zone.
    let k = track(to: CGPoint(x: 700, y: 760), velocity: CGVector(dx: 0, dy: -1_200))
    let d = ExitPredictor.decide(pointer: k.latest!, kinematics: k, zone: zone,
                                 isExpanded: true, tuning: tuning)
    #expect(zone.contains(k.latest!), "precondition: still on the HUD")
    #expect(d.exit)
    #expect(d.predicted)
    #expect(!d.immediate, "a prediction keeps its grace period so it can be cancelled")
}

@Test func movingAroundInsideTheBoardIsNotLeaving() {
    // A normal reading pace across the board — nowhere near escaping.
    let k = track(to: CGPoint(x: 700, y: 850), velocity: CGVector(dx: 180, dy: 0))
    let d = ExitPredictor.decide(pointer: k.latest!, kinematics: k, zone: zone,
                                 isExpanded: true, tuning: tuning)
    #expect(!d.exit)
    #expect(!d.predicted)
}

/// Fast, but along the long axis and far from any edge: speed alone must not
/// close the HUD, or scrolling a column with the pointer would dismiss it.
@Test func speedAloneDoesNotCountAsLeaving() {
    let k = track(to: CGPoint(x: 250, y: 840), velocity: CGVector(dx: 1_500, dy: 0))
    let d = ExitPredictor.decide(pointer: k.latest!, kinematics: k, zone: zone,
                                 isExpanded: true, tuning: tuning)
    #expect(zone.contains(k.latest!))
    // The projection lands past the right edge only if it really would; with
    // 1000pt of width and 180pt of travel from x=250 it does not.
    #expect(!d.exit, "reason was \(d.reason)")
}

@Test func aGenuineFastExitSkipsTheGracePeriod() {
    let k = track(to: CGPoint(x: 700, y: 640), velocity: CGVector(dx: 0, dy: -1_500))
    let d = ExitPredictor.decide(pointer: k.latest!, kinematics: k, zone: zone,
                                 isExpanded: true, tuning: tuning)
    #expect(!zone.contains(k.latest!), "precondition: already outside")
    #expect(d.exit)
    #expect(d.immediate)
    #expect(!d.predicted)
}

@Test func aSlowDriftOutKeepsItsGracePeriod() {
    let k = track(to: CGPoint(x: 700, y: 660), velocity: CGVector(dx: 0, dy: -200))
    let d = ExitPredictor.decide(pointer: k.latest!, kinematics: k, zone: zone,
                                 isExpanded: true, tuning: tuning)
    #expect(!zone.contains(k.latest!))
    #expect(d.exit)
    #expect(!d.immediate, "200pt/s is a drift, not a decision")
}

/// THE SAFETY PROPERTY. The predictor is allowed to be wrong; it is not allowed
/// to cost anything when it is. A wrong call is corrected by the next sample
/// that lands back inside, and `HoverPolicy`'s existing re-entry cancel — which
/// this work did not touch — turns that into a no-op long before the 140ms close
/// delay expires.
@Test func aWrongPredictionIsCancelledByTheNextInsideSample() {
    var policy = HoverPolicy()
    policy.handle(.entered, nowMs: 0)
    policy.tick(nowMs: 100)
    #expect(policy.isExpanded)

    // The predictor fires early, on motion that looked like leaving.
    let leaving = track(to: CGPoint(x: 700, y: 760), velocity: CGVector(dx: 0, dy: -1_200))
    let wrong = ExitPredictor.decide(pointer: leaving.latest!, kinematics: leaving, zone: zone,
                                     isExpanded: true, tuning: tuning)
    #expect(wrong.exit && wrong.predicted)
    policy.handle(.exited, nowMs: 100)
    policy.tick(nowMs: 100)
    #expect(policy.isExpanded, "closing, but still on screen")

    // 20ms later — one sample — the hand reverses and the pointer is inside.
    let returning = track(to: CGPoint(x: 700, y: 720), velocity: CGVector(dx: 0, dy: 900))
    let right = ExitPredictor.decide(pointer: returning.latest!, kinematics: returning, zone: zone,
                                     isExpanded: true, tuning: tuning)
    #expect(!right.exit)
    policy.handle(.entered, nowMs: 120)
    policy.tick(nowMs: 300)
    #expect(policy.isExpanded, "the re-entry cancelled the close outright")
    // ...and the close delay had not even elapsed, so nothing was ever visible.
    #expect(120 - 100 < HoverTiming.closeDelayMs)
}

@Test func theOutwardTestRejectsAStaleProjection() {
    // Projected point outside the top edge, but velocity pointing back down.
    #expect(!ExitPredictor.pointsOutward(CGVector(dx: 0, dy: -500),
                                         from: CGPoint(x: 700, y: 1_100), zone: zone))
    #expect(ExitPredictor.pointsOutward(CGVector(dx: 0, dy: 500),
                                        from: CGPoint(x: 700, y: 1_100), zone: zone))
}

@Test func distanceOutsideIsZeroInsideAndGrowsOutside() {
    #expect(ExitPredictor.distanceOutside(CGPoint(x: 700, y: 800), zone) == 0)
    #expect(ExitPredictor.distanceOutside(CGPoint(x: 700, y: 650), zone) == 50)
}

/// Collapsed, the predictor has no opinion at all — it can only ever make an
/// OPEN HUD close sooner, never keep one open or open one.
@Test func collapsedThePredictorJustReportsContainment() {
    let k = track(to: CGPoint(x: 700, y: 760), velocity: CGVector(dx: 0, dy: -1_200))
    let d = ExitPredictor.decide(pointer: k.latest!, kinematics: k, zone: zone,
                                 isExpanded: false, tuning: tuning)
    #expect(!d.predicted)
    #expect(!d.immediate)
    #expect(!d.exit, "the pointer is inside the zone, so containment says entered")
}

// MARK: - Tuning surface

@Test func tuningFallsBackToTheCompiledConstantsWhenNothingIsSet() {
    let empty = UserDefaults(suiteName: "vibez.hud.tests.empty")!
    for k in empty.dictionaryRepresentation().keys where k.hasPrefix(HoverTuning.prefix) {
        empty.removeObject(forKey: k)
    }
    #expect(HoverTuning.load(empty) == HoverTuning.compiled)
}

@Test func tuningReadsOverridesIncludingZero() {
    let d = UserDefaults(suiteName: "vibez.hud.tests.override")!
    d.set(0.0, forKey: HoverTuning.prefix + "exitMarginPt")     // 0 is meaningful, not "absent"
    d.set(275.0, forKey: HoverTuning.prefix + "projectionMs")
    let t = HoverTuning.load(d)
    #expect(t.exitMarginPt == 0)
    #expect(t.projectionMs == 275)
    #expect(t.fastExitSpeed == HoverTuning.compiled.fastExitSpeed)
    for k in d.dictionaryRepresentation().keys where k.hasPrefix(HoverTuning.prefix) {
        d.removeObject(forKey: k)
    }
}

// MARK: - Menu-bar detection
//
// MEASURED on this machine with `--probe-screen`: desktop, menu bar showing,
// frame.maxY 982 vs visibleFrame.maxY 949 — a 33pt gap. The fullscreen input
// could NOT be observed headlessly (see the report), which is exactly why the
// rule is a pure function: both modes are testable even though only one of them
// could be produced here.

@Test func theMenuBarIsDetectedAsVisibleOnTheDesktop() {
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 65, width: 1512, height: 884)      // maxY 949, measured
    #expect(!NotchHoverRouter.menuBarIsHidden(screenFrame: frame, visibleFrame: visible))
}

@Test func theMenuBarIsDetectedAsHiddenWhenTheTopBandIsFree() {
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    // Fullscreen: nothing is reserved at the top.
    #expect(NotchHoverRouter.menuBarIsHidden(screenFrame: frame, visibleFrame: frame))
    // The Dock still reserving space at the BOTTOM must not read as fullscreen
    // either way — only the top edge is consulted.
    let dockOnly = CGRect(x: 0, y: 80, width: 1512, height: 902)     // maxY 982
    #expect(NotchHoverRouter.menuBarIsHidden(screenFrame: frame, visibleFrame: dockOnly))
}
