import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var model: HUDViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--verify-jump") { JumpVerification.run() }
        if args.contains("--verify-pixels") { PixelVerification.run() }
        let demo = args.contains("--demo")
        let verifying = args.contains("--verify-hover")
        let model = HUDViewModel(demo: demo || verifying)
        self.model = model
        let controller = NotchWindowController(model: model,
                                               logsHover: verifying || args.contains("--debug-hover"))
        self.controller = controller
        model.start()

        if verifying {
            Task { @MainActor in await HoverVerification.run(controller: controller, model: model) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // no Dock icon, no menu bar item
let delegate = AppDelegate()
app.delegate = delegate
app.run()
