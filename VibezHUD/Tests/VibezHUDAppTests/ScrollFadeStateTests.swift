// VibezHUD/Tests/VibezHUDAppTests/ScrollFadeStateTests.swift
//
// The rule behind "stop dimming things I haven't scrolled". The live wiring
// (`onScrollGeometryChange`) cannot be exercised headlessly — a ScrollView's
// content does not render under ImageRenderer at all — so the mapping from
// scroll geometry to fade edges is pinned here, and --verify-pixels proves what
// each state looks like.
import Testing
import CoreGraphics
@testable import VibezHUDApp

/// The state the user complained about: a column that has never moved, showing a
/// fade over the top of its very first tile.
@Test func anUnscrolledColumnThatFitsHasNoFadeAtAll() {
    let s = ScrollFadeState.from(offsetY: 0, contentHeight: 200, containerHeight: 300)
    #expect(!s.top)
    #expect(!s.bottom)
}

/// A column that overflows but has not moved: nothing above to hint at, but
/// there IS more below.
@Test func anUnscrolledColumnWithMoreBelowFadesOnlyItsBottom() {
    let s = ScrollFadeState.from(offsetY: 0, contentHeight: 900, containerHeight: 300)
    #expect(!s.top, "nothing has scrolled under the top edge yet")
    #expect(s.bottom)
}

@Test func scrollingDownEarnsTheTopFade() {
    let s = ScrollFadeState.from(offsetY: 120, contentHeight: 900, containerHeight: 300)
    #expect(s.top)
    #expect(s.bottom)
}

@Test func scrolledToTheEndDropsTheBottomFade() {
    let s = ScrollFadeState.from(offsetY: 600, contentHeight: 900, containerHeight: 300)
    #expect(s.top)
    #expect(!s.bottom, "there is nothing left below to fade toward")
}

/// Sub-pixel offsets and a content height that rounds a hair over the container
/// must not produce a permanent fade on a column that visibly fits.
@Test func hairlineOverflowAndRubberBandingDoNotCountAsScrolled() {
    #expect(!ScrollFadeState.from(offsetY: 0.5, contentHeight: 300, containerHeight: 300).top)
    #expect(!ScrollFadeState.from(offsetY: 0, contentHeight: 301, containerHeight: 300).bottom)
    // Rubber-banding past the top gives a NEGATIVE offset; it is not "scrolled".
    #expect(!ScrollFadeState.from(offsetY: -30, contentHeight: 900, containerHeight: 300).top)
}

/// An edge with no fade due must be genuinely opaque — a single stop at full
/// opacity — not a fade compressed into one pixel.
@Test func anUnfadedEdgeIsAHardEdgeNotATinyGradient() {
    let none = ScrollFadeState(top: false, bottom: false).gradientStops
    #expect(none.allSatisfy { $0.opacity == 1 })

    let both = ScrollFadeState(top: true, bottom: true).gradientStops
    #expect(both.first!.opacity == 0)
    #expect(both.last!.opacity == 0)
    #expect(both.contains { $0.opacity == 1 })
}

/// Stops have to run in order or the gradient is undefined.
@Test func stopsAreMonotonicInEveryCombination() {
    for top in [true, false] {
        for bottom in [true, false] {
            let stops = ScrollFadeState(top: top, bottom: bottom).gradientStops
            #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location <= $1.location },
                    "top=\(top) bottom=\(bottom) -> \(stops.map(\.location))")
        }
    }
}
