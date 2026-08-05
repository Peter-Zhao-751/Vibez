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

    var body: some View {
        NotchIsland(needsYou: model.needsYouCount,
                    // The DONE column's count, ended sessions included, so the
                    // glance and the header the user sees on hover agree.
                    done: model.doneCount,
                    isExpanded: model.isExpanded,
                    notchSize: CGSize(width: geometry.notchRect.width,
                                      height: geometry.notchRect.height),
                    bubbleSize: bubbleSize,
                    flankYNudge: model.menuBarHidden ? model.tuning.flankYNudgeFullscreen : 0) {
            // Built lazily, INSIDE the island's expanded branch: `model.clockMs`
            // is what keeps the tiles' age labels ticking, and it is the only
            // observable that moves while the log is quiet. Reading it here means
            // a collapsed HUD never re-renders on the clock — the board does not
            // exist to read it.
            BubbleBoard(snapshot: model.snapshot, nowMs: model.clockMs) { TerminalJumper.jump(to: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var bubbleSize: CGSize {
        let r = geometry.bubbleRect(boardHeight: model.boardHeight)
        return CGSize(width: r.width, height: r.height)
    }
}
