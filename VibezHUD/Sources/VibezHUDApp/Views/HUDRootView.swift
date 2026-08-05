// Temporary stub so the Task 17 shell builds on its own. Replaced in Task 18.
import SwiftUI

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
    var body: some View {
        Text(model.isExpanded ? "expanded \(model.totalRows)" : "collapsed")
            .foregroundStyle(.white)
            .padding()
            .background(.black)
    }
}
