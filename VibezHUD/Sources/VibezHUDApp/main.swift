import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var model: HUDViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        let model = HUDViewModel(demo: demo)
        self.model = model
        controller = NotchWindowController(model: model)
        model.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // no Dock icon, no menu bar item
let delegate = AppDelegate()
app.delegate = delegate
app.run()
