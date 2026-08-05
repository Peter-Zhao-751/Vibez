import SwiftUI
import VibezSessionKit

/// Every tile uses the SAME neutral material regardless of state. Apple does not
/// tint whole rows on a black surface, and the column header already says what
/// the state is — a row wash says it twice, louder, and was rejected outright in
/// the mockups.
///
/// A needs-you row is marked by RINGING it — the same trick Mail's sidebar uses
/// for a selected mailbox: identical fill, a coloured border. The 2pt hairline
/// that used to sit down the left edge is gone; it did not line up with anything
/// (least of all the column header's dot) and read as a stray mark.
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

    private var isNeedsYou: Bool { session.state == .needsYou }
    private var isDim: Bool { session.state == .done || session.state == .ended }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        // Fixed height, content top-aligned: a two-line tile carries the empty
        // space rather than shrinking and breaking the row rhythm.
        .frame(maxWidth: .infinity, minHeight: HUDTheme.tileHeight,
               maxHeight: HUDTheme.tileHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11).fill(HUDTheme.tileFill))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isNeedsYou ? HUDTheme.needsYou.opacity(0.6) : HUDTheme.tileStroke,
                              lineWidth: 1)
        )
        .opacity(isDim ? 0.48 : 1)
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
