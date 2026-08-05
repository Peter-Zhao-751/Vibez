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
        // 14pt rides the headers up beside the notch rather than below it. The
        // outer columns sit left/right of the hardware cutout, and the middle
        // column's header starts ~30pt clear of the notch's left edge at the
        // 1040pt island width — verified against this machine's 185pt notch.
        // (Restored after the SessionColumn refactor accidentally reverted it.)
        .padding(.top, 14)
        .padding([.horizontal, .bottom], 14)
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
