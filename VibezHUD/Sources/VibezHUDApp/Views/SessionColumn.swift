import SwiftUI
import VibezSessionKit

/// Which edges of a scrolling column should be faded.
///
/// A fade over content that has not moved is noise: it dims the top of the very
/// first tile to hint at scrolling that has not happened, which is why the user
/// called it "very annoying". So each edge is earned — the top fade appears only
/// once something has actually scrolled under it, the bottom only while there is
/// more below to scroll to.
public struct ScrollFadeState: Sendable, Equatable {
    public var top: Bool
    public var bottom: Bool
    public init(top: Bool, bottom: Bool) { self.top = top; self.bottom = bottom }

    /// Slack for sub-pixel offsets and for a content height that rounds a hair
    /// over the container — without it a column that exactly fits its viewport
    /// would show a permanent bottom fade.
    public static let epsilon: CGFloat = 2

    public static func from(offsetY: CGFloat, contentHeight: CGFloat,
                            containerHeight: CGFloat) -> ScrollFadeState {
        ScrollFadeState(
            top: offsetY > epsilon,
            bottom: contentHeight - containerHeight - offsetY > epsilon)
    }

    /// Stops are collapsed to hard edges where no fade is due, so an unfaded
    /// edge is genuinely opaque rather than fading over one pixel.
    public var gradientStops: [(location: CGFloat, opacity: CGFloat)] {
        var stops: [(CGFloat, CGFloat)] = []
        if top { stops += [(0, 0), (0.05, 1)] } else { stops += [(0, 1)] }
        if bottom { stops += [(0.93, 1), (1, 0)] } else { stops += [(1, 1)] }
        return stops.map { (location: $0.0, opacity: $0.1) }
    }

    /// The mask the column actually applies. Shared with `--verify-pixels` so
    /// the harness proves THIS gradient rather than a lookalike.
    @MainActor
    public var maskGradient: LinearGradient {
        LinearGradient(stops: gradientStops.map {
            .init(color: .black.opacity($0.opacity), location: $0.location)
        }, startPoint: .top, endPoint: .bottom)
    }
}

/// Mail's sidebar panel: a lighter rounded slab wrapped around a whole SECTION —
/// its header and its rows together — sitting on the darker background.
///
/// This is the urgency marker now. Marking each needs-you row individually (a
/// bar, then a ring) said the same thing once per row and still did not group
/// anything; a panel says it once, about the section, which is what the eye is
/// actually looking for when it scans three columns.
/// How a column's section is wrapped, if at all.
enum PanelKind {
    case none
    /// The filled Mail-sidebar slab (NEEDS YOU).
    case filled
    /// Same geometry, but drawn as an OUTLINE in the working-card stroke color
    /// (DONE — user round: "an outline in the exact same way, same color as
    /// the outline for the individual bubbles in Working").
    case outlined
}

struct SectionPanel<Content: View>: View {
    var kind: PanelKind = .filled
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(HUDTheme.sectionPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind == .filled
                ? RoundedRectangle(cornerRadius: HUDTheme.sectionCornerRadius)
                    .fill(HUDTheme.sectionFill)
                : nil)
            .overlay(kind == .outlined
                ? RoundedRectangle(cornerRadius: HUDTheme.sectionCornerRadius)
                    .strokeBorder(HUDTheme.mutedCardStroke, lineWidth: 1)
                : nil)
            // Scrolling happens INSIDE the panel, so the panel's corners have to
            // own the clip.
            .clipShape(RoundedRectangle(cornerRadius: HUDTheme.sectionCornerRadius))
    }
}

/// One column of the expanded board.
///
/// A view of its own, not a function on `BubbleBoard`, because each column now
/// owns scroll state and `@State` cannot live in a method.
struct SessionColumn: View {
    let title: String
    let dot: Color
    let sessions: [Session]
    let nowMs: Int64
    let onTap: (Session) -> Void
    /// Wrap this column's header and tiles in a `SectionPanel`. Only NEEDS YOU
    /// asks for it — the panel IS the urgency marker, so a panel on all three
    /// would mark nothing.
    var panel = PanelKind.none
    /// Convenience for the layout paths that only care whether a panel exists.
    var grouped: Bool { panel != .none }
    /// Bubble treatment for this column's rows — see `TileStyle`.
    var tileStyle = TileStyle.workingCard
    /// Test seam: `--verify-pixels` forces a fade state, because `ImageRenderer`
    /// makes a single synchronous pass and `onScrollGeometryChange` never fires
    /// inside it. Nil in production.
    var forcedFade: ScrollFadeState?

    @State private var fade = ScrollFadeState(top: false, bottom: false)

    private var active: ScrollFadeState { forcedFade ?? fade }

    var body: some View {
        Group {
            if grouped { SectionPanel(kind: panel) { section } } else { section }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The scroll area asks for exactly the room its tiles need and no more, so
    /// the panel HUGS its content the way Mail's does instead of stretching to
    /// the full column height when the section is nearly empty. Tiles are a
    /// fixed height now, so this is arithmetic rather than a guess.
    private var naturalScrollHeight: CGFloat {
        BoardLayout.scrollHeight(rows: sessions.count)
    }

    /// The live drag, if any: which tile and its RAW gesture translation.
    /// The column owns this — repulsion needs one brain over all the tiles.
    @State private var drag: (id: Session.ID, translation: CGSize)?

    /// Per-tile visual offsets: the dragged tile gets the rubber-banded 2D
    /// offset, everyone else gets BubblePhysics' cascaded vertical push.
    private func tileOffsets() -> [CGSize] {
        guard let drag, let idx = sessions.firstIndex(where: { $0.id == drag.id }) else {
            return Array(repeating: .zero, count: sessions.count)
        }
        let banded = RubberBand.offset(for: drag.translation,
                                       horizontalLimit: tileStyle.horizontalDragLimit,
                                       verticalLimit: HUDTheme.bubbleDragLimit)
        let pushes = BubblePhysics.verticalDisplacements(
            count: sessions.count, draggedIndex: idx, dragY: banded.height,
            spacing: HUDTheme.tileSpacing, minGap: HUDTheme.bubbleMinGap)
        return sessions.indices.map { i in
            i == idx ? banded : CGSize(width: 0, height: pushes[i])
        }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                // Count LEADS the title in one run of the same font — "2 NEEDS
                // YOU" — instead of trailing at the column's far edge.
                Text("\(sessions.count) \(title)")
                    .font(.system(size: 8.5, weight: .bold)).kerning(0.9)
            }
            .foregroundStyle(.white)
            // Forced height: BoardLayout adds these numbers up to size the
            // island exactly, and a text line's intrinsic height is not a
            // number you can do arithmetic with.
            .frame(height: BoardLayout.headerRowHeight)
            // No horizontal padding: the header's dot has to start exactly where
            // the tiles below it start, and the tiles start at the column's edge.
            .padding(.bottom, BoardLayout.headerBottomPad)

            // Each column scrolls on its own, so a hundred sessions look the
            // same as twelve — the bubble never grows to accommodate them.
            ScrollView(.vertical) {
                let offsets = tileOffsets()
                VStack(spacing: HUDTheme.tileSpacing) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { i, session in
                        SessionTile(session: session, nowMs: nowMs, onTap: onTap,
                                    style: tileStyle,
                                    dragOffset: offsets[i],
                                    onDrag: { drag = (session.id, $0) },
                                    onDragEnd: {
                                        withAnimation(HUDTheme.bubbleSnapBack) { drag = nil }
                                    })
                    }
                }
                .padding(.bottom, BoardLayout.stackBottomPad)
            }
            .scrollIndicators(.automatic)
            .onScrollGeometryChange(for: ScrollFadeState.self) { geo in
                ScrollFadeState.from(offsetY: geo.contentOffset.y,
                                     contentHeight: geo.contentSize.height,
                                     containerHeight: geo.containerSize.height)
            } action: { _, next in
                fade = next
            }
            .mask(active.maskGradient)
            // Short enough not to lag the scroll, long enough not to blink.
            .animation(.easeInOut(duration: 0.15), value: active)
            // At most what the tiles need; less when the board is short, and
            // then it scrolls.
            .frame(maxHeight: naturalScrollHeight)
        }
    }
}
