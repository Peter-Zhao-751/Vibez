import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    let panel: NSPanel
    private let model: HUDViewModel
    private var geometry: NotchGeometry

    /// The last signal handed to `HoverPolicy`. Pointer monitors fire at motion
    /// frequency; only transitions are worth forwarding, because
    /// `HUDViewModel.hoverChanged` also drains the event log.
    private var lastRouting: HoverInput = .exited

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let logsHover: Bool

    /// Where the pointer is, indirected so `--verify-hover` can drive the REAL
    /// panel along a scripted path instead of wherever the physical mouse
    /// happens to be sitting. Production never replaces it.
    var pointerSource: () -> CGPoint = { NSEvent.mouseLocation }

    init(model: HUDViewModel, logsHover: Bool = false) {
        self.model = model
        self.logsHover = logsHover
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
        // Collapsed is the resting state, and collapsed MUST be click-through:
        // this window covers the menu bar.
        panel.ignoresMouseEvents = true

        let root = HUDRootView(model: model)
            .environment(\.notchGeometry, geometry)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        panel.contentView = TrackingContainer(child: host) { [weak self] in
            // The tracking area only ever means "the pointer did something over
            // the panel"; where it actually is decides the rest.
            self?.handlePointer(self?.pointerSource() ?? .zero)
        }

        layout()
        panel.orderFrontRegardless()

        model.onExpansionChanged = { [weak self] _ in
            guard let self else { return }
            // The active zone is state-dependent: expanding grows it from the
            // notch hot spot to the whole panel, collapsing shrinks it back. Both
            // change the answer for a pointer that has not moved at all.
            self.layout()
            self.handlePointer(self.pointerSource())
        }
        installPointerMonitors()
        log("init")

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.geometry = NotchWindowController.currentGeometry()
                    self?.layout()
                }
            }
    }

    // `isolated deinit` because the monitor handles are MainActor state; a
    // nonisolated deinit cannot touch them.
    isolated deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
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
        let frame = CGRect(x: padded.minX, y: padded.minY - 20,
                           width: padded.width, height: rect.height + 20)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    // MARK: - Pointer routing

    /// Mouse monitors, not tracking areas, are what make the collapsed panel
    /// usable: a click-through window receives no tracking callbacks at all, so
    /// something outside the window has to notice the pointer arriving.
    ///
    /// A GLOBAL monitor sees events delivered to other applications, which is
    /// every event while the HUD is click-through and the app is inactive. Mouse
    /// events need no permission — only keyboard monitoring prompts. The LOCAL
    /// monitor covers the case where our own app is frontmost and the events
    /// never reach the global monitor.
    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.handlePointer(self.pointerSource()) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in guard let self else { return }; self.handlePointer(self.pointerSource()) }
            return event
        }
    }

    /// `pointer` is in AppKit screen coordinates (origin bottom-left of the
    /// primary display), the same space `NSScreen.frame` and therefore
    /// `NotchGeometry` live in — no conversion needed, and none must be added.
    func handlePointer(_ pointer: CGPoint) {
        apply(NotchHoverRouter.route(pointer: pointer,
                                     isExpanded: model.isExpanded,
                                     hoverRect: geometry.hoverRect,
                                     panelFrame: panel.frame))
    }

    private func apply(_ input: HoverInput) {
        let ignores = NotchHoverRouter.ignoresMouseEvents(for: input)
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
            log("routing=\(input) ignoresMouseEvents=\(ignores)")
        }
        guard input != lastRouting else { return }
        lastRouting = input
        model.hoverChanged(input)
    }

    // MARK: - Diagnostics

    private func log(_ message: String) {
        guard logsHover else { return }
        print("[hud] \(message) expanded=\(model.isExpanded) "
              + "ignoresMouseEvents=\(panel.ignoresMouseEvents) "
              + "panelFrame=\(rectString(panel.frame)) hoverRect=\(rectString(geometry.hoverRect))")
        fflush(stdout)
    }

    private func rectString(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height)
    }

    var debugGeometry: NotchGeometry { geometry }
}

/// Hosts the SwiftUI content and reports pointer activity with `.activeAlways`,
/// which is what makes tracking fire while the app is inactive. It is the exit
/// half of the story only: while the panel is click-through it receives nothing,
/// so entry is detected by the controller's global monitor instead.
private final class TrackingContainer: NSView {
    private let child: NSView
    private let onHover: () -> Void

    init(child: NSView, onHover: @escaping () -> Void) {
        self.child = child
        self.onHover = onHover
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
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover() }
    override func mouseExited(with event: NSEvent) { onHover() }
    override func mouseMoved(with event: NSEvent) { onHover() }
}
