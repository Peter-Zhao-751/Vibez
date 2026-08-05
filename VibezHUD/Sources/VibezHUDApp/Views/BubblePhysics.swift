import CoreGraphics

/// The "magnetic field" between bubbles in a column.
///
/// When a dragged bubble closes in on a neighbor, the neighbor is repelled —
/// gently at first, then harder — and the gap between them approaches
/// `minGap` ASYMPTOTICALLY, so two bubbles can never touch, by construction
/// rather than by clamp.
///
/// Same rational family as `RubberBand`: `push(x) = x² / (x + slack)` where
/// `slack = spacing - minGap`. Three properties carry the whole feel:
///  - `push'(0) = 0`: a bubble drifting NEAR a neighbor barely moves it —
///    the field switches on with proximity, it isn't a rigid link.
///  - gap = `spacing - x + push(x)` = `spacing - slack·x/(x+slack)`, which
///    decreases monotonically toward `minGap` and never reaches it.
///  - `push(x) < x`: each cascade hop shrinks, so a push ripples down the
///    column and dies out instead of shoving the whole stack.
enum BubblePhysics {
    static func push(_ incursion: CGFloat, spacing: CGFloat, minGap: CGFloat) -> CGFloat {
        guard incursion > 0 else { return 0 }
        let slack = max(spacing - minGap, 0.001)
        return incursion * incursion / (incursion + slack)
    }

    /// Vertical displacement for every tile in a column while `draggedIndex`
    /// is offset by `dragY` (already rubber-banded). Neighbors in the drag
    /// direction get cascaded pushes; tiles on the other side never move.
    static func verticalDisplacements(count: Int, draggedIndex: Int, dragY: CGFloat,
                                      spacing: CGFloat, minGap: CGFloat) -> [CGFloat] {
        var out = [CGFloat](repeating: 0, count: count)
        guard count > 0, draggedIndex >= 0, draggedIndex < count else { return out }
        out[draggedIndex] = dragY

        let step = dragY >= 0 ? 1 : -1
        var carry = abs(dragY)
        var i = draggedIndex + step
        while i >= 0 && i < count {
            carry = push(carry, spacing: spacing, minGap: minGap)
            if carry < 0.05 { break }                 // the ripple has died out
            out[i] = CGFloat(step) * carry
            i += step
        }
        return out
    }
}
