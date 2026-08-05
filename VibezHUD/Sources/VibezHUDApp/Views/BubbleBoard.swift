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
            column("NEEDS YOU", HUDTheme.needsYou, snapshot.needsYou)
            column("DONE", HUDTheme.done, snapshot.done)
            column("WORKING", HUDTheme.working, snapshot.working)
        }
        .padding(.top, 34)          // clears the notch
        .padding([.horizontal, .bottom], 14)
    }

    /// The column body moved to `SessionColumn`: each one now owns scroll state
    /// so it can decide whether its own edges have earned a fade, and `@State`
    /// cannot live in a method.
    private func column(_ title: String, _ dot: Color, _ sessions: [Session]) -> some View {
        SessionColumn(title: title, dot: dot, sessions: sessions,
                      nowMs: nowMs, onTap: onTap, forcedFade: forcedFade)
    }
}
