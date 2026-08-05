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
            column("NEEDS YOU", HUDTheme.needsYou, snapshot.needsYou, grouped: true, style: .panelCell)
            column("DONE", HUDTheme.done, snapshot.done, style: .doneCard)
            column("WORKING", HUDTheme.working, snapshot.working, style: .workingCard)
        }
        // Sides and bottom are EQUAL and small — BoardLayout sizes the island
        // so the bottom black is exactly boardBottomMargin, like the sides.
        // The TOP margin is applied per column (see `column`): the panelled
        // one starts sectionPadding higher so its header lands on the same
        // line as the bare columns' headers. (The top padding was once
        // silently reverted by a refactor: 8097a7d.)
        .padding(.horizontal, HUDTheme.boardSideMargin)
        .padding(.bottom, HUDTheme.boardBottomMargin)
    }

    /// The column body moved to `SessionColumn`: each one now owns scroll state
    /// so it can decide whether its own edges have earned a fade, and `@State`
    /// cannot live in a method.
    private func column(_ title: String, _ dot: Color, _ sessions: [Session],
                        grouped: Bool = false, style: TileStyle = .workingCard) -> some View {
        SessionColumn(title: title, dot: dot, sessions: sessions,
                      nowMs: nowMs, onTap: onTap, grouped: grouped, tileStyle: style,
                      forcedFade: forcedFade)
            // "Make the NEEDS YOU text the same level as the rest": the panel
            // wraps its header in sectionPadding, so the panelled column starts
            // that much higher — header tops align across all three columns.
            // BoardLayout.boardHeight mirrors this lift; keep them in step.
            .padding(.top, grouped ? HUDTheme.boardTopMargin - HUDTheme.sectionPadding
                                   : HUDTheme.boardTopMargin)
    }
}
