import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    let panel: NSPanel
    private let model: HUDViewModel
    private var geometry: NotchGeometry

    /// The last signal handed to `HoverPolicy`. The pointer is sampled twenty
    /// times a second; only transitions are worth forwarding, because
    /// `HUDViewModel.hoverChanged` also drains the event log.
    private var lastRouting: HoverInput = .exited

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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Collapsed is the resting state, and collapsed MUST be click-through:
        // this window covers the menu bar.
        panel.ignoresMouseEvents = true

        let root = HUDRootView(model: model)
            .environment(\.notchGeometry, geometry)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        model.onExpansionChanged = { [weak self] _ in
            guard let self else { return }
            // The active zone is state-dependent: expanding grows it from the
            // notch hot spot to the whole panel, collapsing shrinks it back. Both
            // change the answer for a pointer that has not moved at all, and the
            // answer decides mouse opacity — which cannot wait for the next poll.
            self.layout()
            _ = self.pollPointer()
        }
        // The one and only source of hover, installed last so nothing samples a
        // half-built controller.
        model.pointerProvider = { [weak self] in
            self?.pollPointer() ?? PointerReading(hover: .exited, nearTop: false)
        }
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
    /// draws the collapsed island inside it. That keeps the morph inside one view
    /// hierarchy instead of resizing a window mid-animation.
    func layout() {
        // Sized from the SAME row count the island uses. It used to use
        // `totalRows` (the sum of all three columns) while the island used the
        // longest column, so the window was routinely more than twice the height
        // of the thing it contained — see `NotchHoverRouter.activeZone`.
        let rect = expandedIslandRect
        let padded = rect.insetBy(dx: -NotchHoverRouter.forgiveness * 2, dy: 0)
        // Slack hangs BELOW the island: the panel's top edge stays flush with
        // the screen's top edge, otherwise the top-anchored island is drawn
        // off-screen and clipped.
        let slack = NotchHoverRouter.forgiveness * 2
        let frame = CGRect(x: padded.minX, y: padded.minY - slack,
                           width: padded.width, height: rect.height + slack)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    // MARK: - Pointer routing

    /// Sample the pointer and re-derive mouse opacity from it. Called from the
    /// view model's timer — see `HUDViewModel.pointerProvider`.
    ///
    /// POLLING, not monitors. The previous build detected hover with global and
    /// local `.mouseMoved` monitors; on the user's Mac they never fired, so the
    /// HUD had to be clicked open. `NSEvent.mouseLocation` is a plain class
    /// property — it reads the window server's current cursor position with no
    /// event delivery, no run-loop dependency and no permission — so there is
    /// nothing left to go wrong. One mechanism, both directions.
    ///
    /// Deliberately does NOT notify the model: the model is what called it, and
    /// it applies the returned input itself.
    @discardableResult
    func pollPointer() -> PointerReading {
        // Cheap and guarded: the panel has to keep containing the island, and
        // the island's size follows the row count. While EXPANDED the row count
        // is frozen, so this can never resize the window mid-morph.
        layout()
        let reading = NotchHoverRouter.read(pointer: pointerSource(),
                                            isExpanded: model.isExpanded,
                                            geometry: geometry,
                                            expandedRect: expandedIslandRect)
        apply(reading.hover, notifyModel: false)
        return reading
    }

    /// The immediate path: something happened that must be reflected before the
    /// next poll. `--verify-hover` drives the panel exclusively through this.
    func handlePointer(_ pointer: CGPoint) {
        apply(route(pointer), notifyModel: true)
    }

    /// `pointer` is in AppKit screen coordinates (origin bottom-left of the
    /// primary display), the same space `NSScreen.frame` and therefore
    /// `NotchGeometry` live in — no conversion needed, and none must be added.
    /// `--verify-pointer` proves that against the live cursor.
    private func route(_ pointer: CGPoint) -> HoverInput {
        NotchHoverRouter.route(pointer: pointer,
                               isExpanded: model.isExpanded,
                               geometry: geometry,
                               expandedRect: expandedIslandRect)
    }

    @discardableResult
    private func apply(_ input: HoverInput, notifyModel: Bool) -> HoverInput {
        let ignores = NotchHoverRouter.ignoresMouseEvents(for: input)
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
            log("routing=\(input) ignoresMouseEvents=\(ignores)")
        }
        guard input != lastRouting else { return input }
        lastRouting = input
        if notifyModel { model.hoverChanged(input) }
        return input
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

    /// Where the EXPANDED island is actually drawn — top-anchored, centred, and
    /// sized from the same row count the view uses. Distinct from `panel.frame`,
    /// which is deliberately larger.
    var expandedIslandRect: CGRect { geometry.bubbleRect(rowCount: model.bubbleRowCount) }

    var debugGeometry: NotchGeometry { geometry }
}
