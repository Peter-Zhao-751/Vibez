import AppKit
import VibezSessionKit

/// `--verify-jump`: reads the HUD log for the current `HOME`, rebuilds the
/// sessions the bubble would show, and prints the `JumpPlan` for each WITHOUT
/// performing it.
///
/// Clicking a row for real needs synthetic mouse input, which needs an
/// Accessibility grant this process does not have. So this verifies everything
/// up to the click: that the plugin's process-tree walk wrote a pid, that the
/// pid still resolves to a running GUI application, and that the row would
/// therefore activate rather than fall through to Finder.
@MainActor
enum JumpVerification {
    static func run() -> Never {
        // `NSHomeDirectory()` comes from the passwd entry, not $HOME, so pointing
        // this at a sandboxed log needs an explicit path.
        let args = CommandLine.arguments
        let log: URL
        if let i = args.firstIndex(of: "--log"), i + 1 < args.count {
            log = URL(fileURLWithPath: args[i + 1])
        } else {
            log = HUDPaths.defaultLogURL
        }
        print("log: \(log.path)")
        print("exists: \(FileManager.default.fileExists(atPath: log.path))")

        let engine = HUDEngine(logURL: log)
        let snapshot = engine.primeAndDrain()
        let all = snapshot.needsYou + snapshot.done + snapshot.working
        print("sessions: \(all.count)")
        print("")

        for s in all {
            let plan = TerminalJumper.plan(for: s)
            print("sid=\(s.sid) proj=\(s.proj)")
            print("   app=\(s.app ?? "-") appPid=\(s.appPid.map(String.init) ?? "-") agentPid=\(s.agentPid.map(String.init) ?? "-")")
            print("   cwd=\(s.cwd)")
            switch plan {
            case .activate(let pid):
                let running = NSRunningApplication(processIdentifier: pid)
                print("   PLAN: activate pid \(pid) -> \(running?.localizedName ?? "?") "
                      + "(\(running?.bundleIdentifier ?? "no bundle id"))")
            case .reveal(let url):
                print("   PLAN: reveal \(url.path) in Finder (no live app pid)")
            case .nothing:
                print("   PLAN: nothing (no live app pid and no existing cwd)")
            }
            print("")
        }
        fflush(stdout)
        exit(all.isEmpty ? 2 : 0)
    }
}
