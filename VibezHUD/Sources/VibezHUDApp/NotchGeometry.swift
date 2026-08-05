import CoreGraphics

/// Everything NotchGeometry needs from an NSScreen, as plain values — so the
/// math is testable with no display attached.
public struct ScreenMetrics: Sendable, Equatable {
    public var frame: CGRect
    public var safeAreaTopInset: CGFloat
    public var auxLeft: CGRect
    public var auxRight: CGRect

    public init(frame: CGRect, safeAreaTopInset: CGFloat, auxLeft: CGRect, auxRight: CGRect) {
        self.frame = frame; self.safeAreaTopInset = safeAreaTopInset
        self.auxLeft = auxLeft; self.auxRight = auxRight
    }
}

public struct NotchGeometry: Sendable, Equatable {
    public static let fallbackPillWidth: CGFloat = 190
    public static let fallbackPillHeight: CGFloat = 24
    public static let maxBubbleWidth: CGFloat = 1040
    public static let maxBubbleHeightFraction: CGFloat = 0.62
    static let hoverPadX: CGFloat = 44
    /// How far BELOW the collapsed island the hot zone reaches.
    ///
    /// Was 6pt, which made the target barely deeper than the notch itself: an
    /// approach from below that stopped a few points short of the hardware
    /// notch — the natural thing to do, since the notch is a hole you cannot
    /// point at — landed in dead space and nothing happened. 24pt is roughly a
    /// menu-bar height of forgiveness, still nowhere near the menu-bar items,
    /// which sit outside the ±44pt x window.
    static let hoverPadY: CGFloat = 24

    public let metrics: ScreenMetrics
    public let hasNotch: Bool
    public let notchRect: CGRect
    public let hoverRect: CGRect

    public init(metrics: ScreenMetrics) {
        self.metrics = metrics
        let f = metrics.frame
        let notched = metrics.safeAreaTopInset > 0
            && metrics.auxLeft.width > 0 && metrics.auxRight.width > 0
        hasNotch = notched

        if notched {
            let w = f.width - metrics.auxLeft.width - metrics.auxRight.width
            let h = metrics.safeAreaTopInset
            notchRect = CGRect(x: f.minX + metrics.auxLeft.width, y: f.maxY - h, width: w, height: h)
        } else {
            let w = Self.fallbackPillWidth, h = Self.fallbackPillHeight
            notchRect = CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        }

        hoverRect = CGRect(x: notchRect.minX - Self.hoverPadX,
                           y: notchRect.minY - Self.hoverPadY,
                           width: notchRect.width + Self.hoverPadX * 2,
                           height: notchRect.height + Self.hoverPadY)
    }

    /// The expanded bubble: top-anchored, wider than the notch so it swallows it,
    /// capped so it can never take over the screen.
    public func bubbleRect(rowCount: Int) -> CGRect {
        let f = metrics.frame
        let width = min(Self.maxBubbleWidth, f.width * 0.84)
        let contentHeight = 78 + CGFloat(max(rowCount, 1)) * 62
        let height = min(contentHeight, f.height * Self.maxBubbleHeightFraction)
        return CGRect(x: f.midX - width / 2, y: f.maxY - height, width: width, height: height)
    }
}
