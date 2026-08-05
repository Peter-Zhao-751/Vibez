import SwiftUI
import VibezSessionKit

struct NotchGeometryKey: EnvironmentKey {
    static let defaultValue = NotchGeometry(metrics: ScreenMetrics(
        frame: .init(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32,
        auxLeft: .init(x: 0, y: 950, width: 656, height: 32),
        auxRight: .init(x: 856, y: 950, width: 656, height: 32)))
}
extension EnvironmentValues {
    var notchGeometry: NotchGeometry {
        get { self[NotchGeometryKey.self] }
        set { self[NotchGeometryKey.self] = newValue }
    }
}

struct HUDRootView: View {
    let model: HUDViewModel
    @Environment(\.notchGeometry) private var geometry
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .top) {
                if model.isExpanded {
                    bubble
                        .transition(.identity)
                } else {
                    CollapsedEars(needsYou: model.needsYouCount,
                                  working: model.workingCount,
                                  notchWidth: geometry.notchRect.width,
                                  namespace: glass)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(HUDTheme.expand, value: model.isExpanded)
        }
    }

    private var bubble: some View {
        BubbleBoard(snapshot: model.snapshot) { TerminalJumper.jump(to: $0) }
            .frame(width: bubbleSize.width, height: bubbleSize.height)
            .background(
                // Opaque black, top-anchored, wider than the notch so it
                // swallows it: one continuous object, not a window under a notch.
                UnevenRoundedRectangle(bottomLeadingRadius: HUDTheme.bubbleCornerRadius,
                                       bottomTrailingRadius: HUDTheme.bubbleCornerRadius)
                    .fill(HUDTheme.bubbleFill)
                    .overlay(
                        UnevenRoundedRectangle(bottomLeadingRadius: HUDTheme.bubbleCornerRadius,
                                               bottomTrailingRadius: HUDTheme.bubbleCornerRadius)
                            .fill(LinearGradient(colors: [.white.opacity(0.055), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(
                        UnevenRoundedRectangle(bottomLeadingRadius: HUDTheme.bubbleCornerRadius,
                                               bottomTrailingRadius: HUDTheme.bubbleCornerRadius)
                            .strokeBorder(.white.opacity(0.13), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.7), radius: 30, y: 18)
            )
            .glassEffectID("bubble", in: glass)
    }

    private var bubbleSize: CGSize {
        let rows = max(model.snapshot.needsYou.count,
                       max(model.snapshot.done.count, model.snapshot.working.count))
        let r = geometry.bubbleRect(rowCount: rows)
        return CGSize(width: r.width, height: r.height)
    }
}
