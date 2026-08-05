import SwiftUI
import VibezSessionKit

/// Per-column bubble treatment.
enum TileStyle {
    /// Working: muted card with a visible outline.
    case workingCard
    /// Done (experiment, user round): the PANEL's grey, no outline — the same
    /// surface color that wraps the needs-you section.
    case doneCard
    /// Needs-you rows inside the section panel: the lighter Mail-cell grey.
    case panelCell

    var fill: Color {
        switch self {
        case .workingCard: HUDTheme.mutedCardFill
        case .doneCard: HUDTheme.sectionFill
        case .panelCell: HUDTheme.panelCellFill
        }
    }
    var cornerRadius: CGFloat {
        self == .panelCell ? HUDTheme.panelCellRadius : 11
    }
    var hasOutline: Bool { self == .workingCard }
}

/// Every tile uses the SAME neutral material regardless of state. Apple does not
/// tint whole rows on a black surface, and the column header already says what
/// the state is — a row wash says it twice, louder, and was rejected outright in
/// the mockups.
///
/// Nothing marks a needs-you row at the ROW level any more. First it was a 2pt
/// amber hairline down the left edge (lined up with nothing), then an amber ring
/// around each tile (louder, and still per-row). What Mail actually does — and
/// what was asked for — is group the whole SECTION in a panel: see
/// `SectionPanel`. Urgency belongs to the section, not to every row in it, so
/// every tile in every column now uses one identical neutral treatment.
///
/// Every tile is EXACTLY `HUDTheme.tileHeight` tall, whether it has a detail line
/// or not. Intrinsic heights made the three columns ragged — a two-line done tile
/// next to a three-line working tile — and a column of rows that do not line up
/// across the board looks broken before it looks informative.
struct SessionTile: View {
    let session: Session
    /// Passed in, never read from `Date()` at render time: the age label has to
    /// change when an OBSERVED value changes, or SwiftUI has no reason to redraw
    /// it and the counter freezes with the panel open. See `AgeClock`.
    let nowMs: Int64
    let onTap: (Session) -> Void
    /// Inside a `SectionPanel` each row is a Mail-style CELL: a lighter grey
    /// rounded rect on the panel (like the Inbox row's highlight in Mail's
    /// sidebar), with no hairline stroke. Two greys, both deliberate — the
    /// panel encompasses, the cell delineates. Outside a panel a tile is the
    /// usual card on black.
    var style = TileStyle.workingCard

    // No dim anywhere: done rows look exactly like working rows (user call).
    // A finished session is still marked by its column and, for ended, the
    // italic "ended" detail line — de-emphasis by position, not by fading.

    var body: some View {
        VStack(alignment: .leading, spacing: HUDTheme.tileLineSpacing) {
                HStack(spacing: 6) {
                    chip
                    Text(session.proj)
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(elapsed)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(session.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1).truncationMode(.tail)
            if let detail = detailLine {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(session.state == .ended ? 0.4 : 0.52))
                    .italic(session.state == .ended)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, HUDTheme.tileVerticalPadding)
        // Fixed height, content top-aligned: a two-line tile carries the empty
        // space rather than shrinking and breaking the row rhythm.
        .frame(maxWidth: .infinity, minHeight: HUDTheme.tileHeight,
               maxHeight: HUDTheme.tileHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: style.cornerRadius).fill(style.fill))
        .overlay(style.hasOutline
            ? RoundedRectangle(cornerRadius: style.cornerRadius)
                .strokeBorder(HUDTheme.mutedCardStroke, lineWidth: 1)
            : nil)
        .contentShape(Rectangle())
        .onTapGesture { onTap(session) }
    }

    private var chip: some View {
        Text(HUDTheme.glyph(session.agent))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 5).fill(HUDTheme.chip(session.agent)))
    }

    private var detailLine: String? {
        if session.state == .ended { return "ended" }
        switch (session.tool, session.detail) {
        case let (tool?, detail?): return "\(tool) · \(detail)"
        case let (tool?, nil):     return tool
        case let (nil, detail?):   return detail
        default:                   return nil
        }
    }

    /// Internal, not private: SessionTileAgeTests pins it to the PASSED clock,
    /// which is the assertion that fails if this ever reads `Date()` again.
    var elapsed: String {
        let secs = max(0, (nowMs - session.stateSinceMs) / 1000)
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }
}
