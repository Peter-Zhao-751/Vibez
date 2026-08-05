import CoreGraphics

/// Decides, from the pointer's screen position alone, whether the notch panel is
/// "hovered" and whether it is allowed to swallow mouse events.
///
/// This is pure on purpose, and it is the most safety-critical geometry in the
/// app. The panel is a borderless window at layer 27 spanning 1160x470 points
/// across the top of the display — it sits ABOVE the menu bar. A panel that size
/// left mouse-opaque does not merely over-trigger the hover: it eats every
/// menu-bar click underneath it, and the user cannot use their own Mac.
///
/// So mouse opacity is derived, never assumed: opaque only while the pointer is
/// genuinely on the HUD, click-through every other instant.
public enum NotchHoverRouter {
    /// How far outside the visible island still counts as "on it". Enough to
    /// forgive a wobble at the edge, nowhere near enough to be invisible.
    public static let forgiveness: CGFloat = 12

    /// The region that counts as "on the HUD" right now.
    ///
    /// Collapsed, only the small hot zone hugging the notch counts, so the rest
    /// of the menu bar stays reachable. Expanded, the VISIBLE ISLAND counts (plus
    /// `forgiveness`), so the pointer can travel from the notch down into the
    /// board without crossing a dead seam that would snap it shut mid-reach.
    ///
    /// `expandedRect` is the island, NOT the window. That distinction is the
    /// whole bug this parameter was renamed for: the panel is deliberately
    /// larger than the island — 1160x470 around a 1040x202 slab on a 14" MBP —
    /// so using the window here made a 268pt-tall band of empty screen BELOW the
    /// visible HUD count as hover. Pulling the pointer off the island did
    /// nothing at all, and the only way to dismiss the thing was to click
    /// somewhere far away. Measured with `--verify-warp` before the fix.
    public static func activeZone(isExpanded: Bool,
                                  hoverRect: CGRect,
                                  expandedRect: CGRect) -> CGRect {
        isExpanded ? expandedRect.insetBy(dx: -forgiveness, dy: -forgiveness) : hoverRect
    }

    /// The hover signal to feed `HoverPolicy`. All hysteresis lives there; this
    /// answers only "is the pointer on the HUD, yes or no".
    public static func route(pointer: CGPoint,
                             isExpanded: Bool,
                             hoverRect: CGRect,
                             expandedRect: CGRect) -> HoverInput {
        activeZone(isExpanded: isExpanded, hoverRect: hoverRect, expandedRect: expandedRect)
            .contains(pointer) ? .entered : .exited
    }

    /// The form the polling path calls: hand it `NSEvent.mouseLocation` and the
    /// geometry, get back the signal.
    ///
    /// `pointer` MUST be in AppKit screen coordinates — origin at the BOTTOM-left
    /// of the primary display, y increasing upwards — which is the space both
    /// `NSEvent.mouseLocation` and `NSScreen.frame` (and therefore every rect in
    /// `NotchGeometry`) already live in. No conversion belongs here.
    ///
    /// This is the y-flip trap, and it is worth naming because its symptom is
    /// indistinguishable from a dead event mechanism: convert to CoreGraphics
    /// display space (top-left origin) on the way in and the notch — which sits
    /// at the TOP of the screen, i.e. at HIGH y in this space — hit-tests against
    /// the bottom of the display instead. Hover then never fires anywhere the
    /// user would think to put the pointer. `NotchHoverRouterTests` pins both a
    /// notch point and its flipped twin.
    public static func route(pointer: CGPoint,
                             isExpanded: Bool,
                             geometry: NotchGeometry,
                             expandedRect: CGRect) -> HoverInput {
        route(pointer: pointer, isExpanded: isExpanded,
              hoverRect: geometry.hoverRect, expandedRect: expandedRect)
    }

    /// Mouse opacity follows the routing exactly: the panel may intercept clicks
    /// only while the pointer is inside the active zone.
    ///
    /// Note this deliberately drops opacity the instant the pointer leaves, even
    /// though `HoverPolicy` keeps the bubble on screen for the close delay. A
    /// still-visible bubble that is already click-through is the right trade: the
    /// user is on their way to the menu bar, and the 350 ms of grace is there to
    /// forgive a wobble, not to keep capturing clicks.
    public static func ignoresMouseEvents(for input: HoverInput) -> Bool {
        input == .exited
    }
}
