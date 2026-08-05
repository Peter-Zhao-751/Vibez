import CoreGraphics
import VibezSessionKit

/// The column counts the island is currently sized for. Frozen while expanded,
/// exactly like `bubbleRowCount` was — the island must not resize under a
/// pointer that is already reading it.
struct BoardCounts: Equatable, Sendable {
    var needsYou: Int
    var done: Int
    var working: Int

    init(needsYou: Int, done: Int, working: Int) {
        self.needsYou = needsYou; self.done = done; self.working = working
    }

    init(_ snapshot: HUDSnapshot) {
        self.init(needsYou: snapshot.needsYou.count,
                  done: snapshot.done.count,
                  working: snapshot.working.count)
    }
}

/// One place that can ADD UP the board. The user's complaint was concrete —
/// "on the bottom there's so much black space, it's uneven on the sides and
/// bottom" — and the cause was an island sized by a rough chrome-plus-rows
/// guess. Now the island's height IS this arithmetic: every term below is a
/// forced frame or a fixed padding in the views, so content bottom edge to
/// island bottom edge is exactly `HUDTheme.boardBottomMargin`, matching the
/// sides.
enum BoardLayout {
    /// The column header's forced text-row height (see SessionColumn).
    static let headerRowHeight: CGFloat = 11
    static let headerBottomPad: CGFloat = 8
    /// The tile stack's own bottom padding inside the scroll area. Zero: it
    /// made the panel's bottom inset deeper than its sides, and the board's
    /// own bottom margin already provides the breathing room below columns.
    static let stackBottomPad: CGFloat = 0

    static func scrollHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * HUDTheme.tileHeight
            + CGFloat(rows - 1) * HUDTheme.tileSpacing
            + stackBottomPad
    }

    /// Full height of one column: header block plus tiles, plus the section
    /// panel's wrap when the column is panelled (NEEDS YOU).
    static func columnHeight(rows: Int, panelled: Bool) -> CGFloat {
        let body = headerRowHeight + headerBottomPad + scrollHeight(rows: rows)
        return panelled ? body + 2 * HUDTheme.sectionPadding : body
    }

    /// The whole board, margins included — what the island's height should be
    /// when it is not capped by the screen.
    ///
    /// Panelled columns (NEEDS YOU filled, DONE outlined — same geometry) are
    /// LIFTED by `sectionPadding` so their headers sit on the bare column's
    /// header line (see BubbleBoard); their contribution to the needed height
    /// is therefore their own height minus the lift.
    static func boardHeight(_ counts: BoardCounts) -> CGFloat {
        let lift = HUDTheme.sectionPadding
        let tallest = max(columnHeight(rows: counts.needsYou, panelled: true) - lift,
                          max(columnHeight(rows: counts.done, panelled: true) - lift,
                              columnHeight(rows: counts.working, panelled: false)))
        return HUDTheme.boardTopMargin + tallest + HUDTheme.boardBottomMargin
    }
}
