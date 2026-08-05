// VibezHUD/Tests/VibezHUDAppTests/IslandMetricsTests.swift
//
// The collapsed island's whole design rests on two arithmetic claims: a quiet
// machine renders a shape that IS the notch rect (and is therefore invisible),
// and a busy one grows sideways only, never taller. Both are pure functions, so
// both are pinned here rather than left to a screenshot.
import Testing
import CoreGraphics
@testable import VibezHUDApp

private let notch = CGSize(width: 200, height: 32)

@Test func aFlankWithNothingToSayHasNoWidthAtAll() {
    #expect(IslandMetrics.flankWidth(count: 0) == 0)
    #expect(IslandMetrics.flankWidth(count: 1) > 0)
}

/// The invisible resting state, which is what replaces "two glass ears floating
/// over the wallpaper": black shape, notch's own footprint, nothing to see.
@Test func bothCountsZeroIsExactlyTheNotchRect() {
    let size = IslandMetrics.collapsedSize(needsYou: 0, done: 0, notchSize: notch)
    #expect(size.width == notch.width)
    #expect(size.height == notch.height)
}

@Test func oneCountShowingGrowsOnlySideways() {
    let left = IslandMetrics.collapsedSize(needsYou: 3, done: 0, notchSize: notch)
    let right = IslandMetrics.collapsedSize(needsYou: 0, done: 3, notchSize: notch)
    #expect(left.width > notch.width)
    #expect(left.width == right.width)          // the flanks cost the same
    #expect(left.height == notch.height)        // ...and the island never gets taller
    #expect(right.height == notch.height)
}

@Test func bothFlanksAddUpAndTheNotchBandSurvivesInTheMiddle() {
    let size = IslandMetrics.collapsedSize(needsYou: 2, done: 3, notchSize: notch)
    #expect(size.width == notch.width
            + IslandMetrics.flankWidth(count: 2) + IslandMetrics.flankWidth(count: 3))
}

/// Digits are monospaced, so a flank's width is a function of how many digits
/// the count has and never of which digits they are: 1 and 8 must produce the
/// same island, or the shape twitches every time a number changes without
/// changing length.
@Test func theIslandWidthTracksDigitCountNotDigitIdentity() {
    #expect(IslandMetrics.flankWidth(count: 1) == IslandMetrics.flankWidth(count: 8))
    #expect(IslandMetrics.flankWidth(count: 10) == IslandMetrics.flankWidth(count: 99))
    #expect(IslandMetrics.flankWidth(count: 10) >= IslandMetrics.flankWidth(count: 9))
}

/// Stacked, a flank is 20pt — and the two flanks are mirror images, which a
/// dot-then-number row never was.
@Test func aFlankCostsTwentyPoints() {
    #expect(IslandMetrics.flankWidth(count: 1) == 20)
    let both = IslandMetrics.collapsedSize(needsYou: 3, done: 4, notchSize: notch)
    #expect(both.width == notch.width + 40)
}

/// ...and a two-digit count widens the flank rather than clipping. "12" must
/// never render as "1".
@Test func twoDigitsWidenTheFlankInsteadOfBeingClipped() {
    let one = IslandMetrics.flankWidth(count: 9)
    let two = IslandMetrics.flankWidth(count: 12)
    #expect(two >= one)
    #expect(two >= IslandMetrics.flankPadding * 2 + IslandMetrics.digitWidth * 2)
    #expect(IslandMetrics.flankWidth(count: 99) == two)
}

/// The resting island answers "what is blocked on me" and "what finished". A
/// busy agent needs nothing from the user, so WORKING earns no space out here —
/// and the consequence is deliberate: three agents running and nothing waiting
/// shows a bare notch.
@Test func aMachineThatIsOnlyWorkingShowsABareNotch() {
    // `collapsedSize` takes needsYou and done; there is no working parameter to
    // pass, which is the design stated as a type.
    let onlyWorking = IslandMetrics.collapsedSize(needsYou: 0, done: 0, notchSize: notch)
    #expect(onlyWorking.width == notch.width)
    #expect(onlyWorking.height == notch.height)
}

/// The centring correction. The flanks are independent, so an island that were
/// merely centred on the notch would slide its lone flank over the physical
/// cutout — the count would be drawn into a hole and vanish.
@Test func aLoneFlankShiftsTheIslandSoTheNotchBandStaysOverTheNotch() {
    let notchOnly = IslandMetrics.centerOffset(needsYou: 0, done: 0)
    #expect(notchOnly == 0)

    // Left flank only: the island must move LEFT by half its width.
    let leftOnly = IslandMetrics.centerOffset(needsYou: 2, done: 0)
    #expect(leftOnly == -IslandMetrics.flankWidth(count: 2) / 2)

    // Right flank only: mirror image.
    let rightOnly = IslandMetrics.centerOffset(needsYou: 0, done: 2)
    #expect(rightOnly == IslandMetrics.flankWidth(count: 2) / 2)

    // Equal flanks cancel out.
    #expect(IslandMetrics.centerOffset(needsYou: 4, done: 7) == 0)
}

/// Spelled out as a coordinate claim, because "the shape covers the notch" is
/// the thing that actually has to be true on screen.
@Test func theNotchBandLandsOnTheNotchWhateverTheFlanksDo() {
    let notchCenter: CGFloat = 756          // this machine's notch midX
    for (n, w) in [(0, 0), (1, 0), (0, 1), (2, 3), (12, 4)] {
        let size = IslandMetrics.collapsedSize(needsYou: n, done: w, notchSize: notch)
        let center = notchCenter + IslandMetrics.centerOffset(needsYou: n, done: w)
        let islandMinX = center - size.width / 2
        // Where the notch-width band sits inside the shape.
        let bandMinX = islandMinX + IslandMetrics.flankWidth(count: n)
        #expect(abs(bandMinX - (notchCenter - notch.width / 2)) < 0.001,
                "needsYou=\(n) working=\(w) put the notch band at \(bandMinX)")
    }
}
