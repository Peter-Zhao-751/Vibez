import SwiftUI
import VibezSessionKit

struct BubbleBoard: View {
    let snapshot: HUDSnapshot
    /// Whole-second wall clock from the view model — the tiles' age labels are
    /// derived from it rather than from `Date()` at render time, so they keep
    /// ticking even when the snapshot is unchanged. See `AgeClock`.
    let nowMs: Int64
    let onTap: (Session) -> Void
    /// Test seam, nil in production — see `SessionColumn.forcedFade`.
    var forcedFade: ScrollFadeState?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            // Only NEEDS YOU is panelled. The panel is the urgency marker, and
            // a marker on all three marks nothing.
            column("NEEDS YOU", HUDTheme.needsYou, snapshot.needsYou, grouped: true)
            column("DONE", HUDTheme.done, snapshot.done)
            column("WORKING", HUDTheme.working, snapshot.working)
        }
        // Top rides the headers up beside the notch (verified: the middle
        // column's header clears the 185pt cutout by ~30pt at 1040 wide).
        // Sides and bottom are EQUAL and small — BoardLayout sizes the island
        // so the bottom black is exactly boardBottomMargin, like the sides.
        // (The top padding was once silently reverted by a refactor: 8097a7d.)
        .padding(.top, HUDTheme.boardTopMargin)
        .padding(.horizontal, HUDTheme.boardSideMargin)
        .padding(.bottom, HUDTheme.boardBottomMargin)
    }

    /// The column body moved to `SessionColumn`: each one now owns scroll state
    /// so it can decide whether its own edges have earned a fade, and `@State`
    /// cannot live in a method.
    private func column(_ title: String, _ dot: Color, _ sessions: [Session],
                        grouped: Bool = false) -> some View {
        SessionColumn(title: title, dot: dot, sessions: sessions,
                      nowMs: nowMs, onTap: onTap, grouped: grouped, forcedFade: forcedFade)
    }
}
