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
        let mag = (translation.width * translation.width
                   + translation.height * translation.height).squareRoot()
        guard mag > 0 else { return .zero }
        let factor = stretch(mag, limit: limit) / mag
        return CGSize(width: translation.width * factor,
                      height: translation.height * factor)
    }
}
