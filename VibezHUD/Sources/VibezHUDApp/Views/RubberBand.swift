import CoreGraphics

/// The elastic-drag curve for message bubbles.
///
/// `limit * t / (t + limit)` — slope 1 at the origin (a small drag follows the
/// pointer honestly), asymptotic to `limit` (the bubble can NEVER be dragged
/// past it), and with marginal give that shrinks the further you pull: the
/// classic rubber-band feel. Applied RADIALLY so diagonal drags curve the same
/// as axis-aligned ones and the drag direction is preserved exactly.
enum RubberBand {
    static func stretch(_ t: CGFloat, limit: CGFloat) -> CGFloat {
        guard t > 0, limit > 0 else { return 0 }
        return limit * t / (t + limit)
    }

    static func offset(for translation: CGSize, limit: CGFloat) -> CGSize {
        offset(for: translation, horizontalLimit: limit, verticalLimit: limit)
    }

    /// Anisotropic form: each axis gets its own asymptote, because the space
    /// available sideways (to a panel edge or the neighboring column) differs
    /// from the space available vertically (where neighbor repulsion rules).
    /// Per-axis application keeps each component inside its own limit — which
    /// is the actual constraint, walls being axis-aligned.
    static func offset(for translation: CGSize,
                       horizontalLimit: CGFloat, verticalLimit: CGFloat) -> CGSize {
        CGSize(width: translation.width.sign == .minus
                   ? -stretch(-translation.width, limit: horizontalLimit)
                   : stretch(translation.width, limit: horizontalLimit),
               height: translation.height.sign == .minus
                   ? -stretch(-translation.height, limit: verticalLimit)
                   : stretch(translation.height, limit: verticalLimit))
    }
}
