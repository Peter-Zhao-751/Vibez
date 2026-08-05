import AppKit
import VibezSessionKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var model: HUDViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--verify-jump") { JumpVerification.run() }
        if args.contains("--verify-pixels") { PixelVerification.run() }
        if args.contains("--probe-screen") { ScreenProbe.run() }
        // Live tuning session: every pointer decision to a file, and every
        // threshold re-read from UserDefaults on each sample.
        let tuning = args.contains("--tune-hover")
        if tuning {
            HoverTuneLog.shared = HoverTuneLog(
                url: HUDPaths.hudDir.appendingPathComponent("tune.log"))
        }
        let demo = args.contains("--demo")
        let verifying = args.contains("--verify-hover")
        let morphing = args.contains("--verify-morph")
        let warping = args.contains("--verify-warp")
        let model = HUDViewModel(demo: demo || verifying || morphing || warping)
        self.model = model
        let controller = NotchWindowController(model: model,
                                               logsHover: verifying || args.contains("--debug-hover"),
                                               // warp A/Bs the predictor through UserDefaults
                                               tunes: tuning || warping)
        self.controller = controller
        // Before start(): the poll must not race the probe's cursor warping.
        if args.contains("--verify-pointer") { HoverVerification.probePointerSpace(controller: controller) }
        model.start()

        if verifying {
            Task { @MainActor in await HoverVerification.run(controller: controller, model: model) }
        }
        if warping {
            Task { @MainActor in await WarpVerification.run(controller: controller, model: model) }
        }
        if morphing {
            Task { @MainActor in await MorphVerification.run(controller: controller, model: model) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // no Dock icon, no menu bar item
let delegate = AppDelegate()
app.delegate = delegate
app.run()
