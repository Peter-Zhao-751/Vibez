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
    /// The region that counts as "on the HUD" right now.
    ///
    /// Collapsed, only the small hot zone hugging the notch counts, so the rest
    /// of the menu bar stays reachable. Expanded, the whole panel counts, so the
    /// pointer can travel from the notch down into the bubble without crossing a
    /// dead seam that would snap it shut mid-reach.
    public static func activeZone(isExpanded: Bool,
                                  hoverRect: CGRect,
                                  panelFrame: CGRect) -> CGRect {
        isExpanded ? panelFrame : hoverRect
    }

    /// The hover signal to feed `HoverPolicy`. All hysteresis lives there; this
    /// answers only "is the pointer on the HUD, yes or no".
    public static func route(pointer: CGPoint,
                             isExpanded: Bool,
                             hoverRect: CGRect,
                             panelFrame: CGRect) -> HoverInput {
        activeZone(isExpanded: isExpanded, hoverRect: hoverRect, panelFrame: panelFrame)
            .contains(pointer) ? .entered : .exited
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
