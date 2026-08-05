import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let model: HUDViewModel
    private var geometry: NotchGeometry

    init(model: HUDViewModel) {
        self.model = model
        self.geometry = NotchWindowController.currentGeometry()

        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = HUDTheme.windowLevel
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = HUDRootView(model: model)
            .environment(\.notchGeometry, geometry)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        panel.contentView = TrackingContainer(model: model, child: host)

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.geometry = NotchWindowController.currentGeometry()
                    self?.layout()
                }
            }
    }

    static func currentGeometry() -> NotchGeometry {
        // The menu-bar screen, which is the one that has a notch if any does.
        let screen = NSScreen.screens.first ?? NSScreen.main!
        return NotchGeometry(metrics: ScreenMetrics(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxLeft: screen.auxiliaryTopLeftArea ?? .zero,
            auxRight: screen.auxiliaryTopRightArea ?? .zero))
    }

    /// The panel is always sized for the EXPANDED bubble; the SwiftUI content
    /// draws the collapsed ears inside it. That keeps the morph inside one view
    /// hierarchy instead of resizing a window mid-animation.
    func layout() {
        let rect = geometry.bubbleRect(rowCount: max(model.totalRows, 3))
        let padded = rect.insetBy(dx: -60, dy: 0)
        // The extra 20pt is slack for the drop shadow and must hang BELOW the
        // bubble: the panel's top edge stays flush with the screen's top edge,
        // otherwise the top-anchored bubble is drawn off-screen and clipped.
        panel.setFrame(CGRect(x: padded.minX, y: padded.minY - 20,
                              width: padded.width, height: rect.height + 20), display: true)
    }
}

/// Hosts the SwiftUI content and reports hover with `.activeAlways`, which is
/// what makes tracking fire while the app is inactive.
private final class TrackingContainer: NSView {
    private let model: HUDViewModel
    private let child: NSView
    init(model: HUDViewModel, child: NSView) {
        self.model = model
        self.child = child
        super.init(frame: .zero)
        addSubview(child)
        child.frame = bounds
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        child.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        Task { @MainActor in model.hoverChanged(.entered) }
    }
    override func mouseExited(with event: NSEvent) {
        Task { @MainActor in model.hoverChanged(.exited) }
    }
}
