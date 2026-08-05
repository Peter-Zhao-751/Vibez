import AppKit
import VibezSessionKit

enum TerminalJumper {
    /// App-level activation needs no permissions at all. Raising a SPECIFIC
    /// window among several would need Accessibility, so it is deliberately not
    /// attempted here — the app coming forward is the 90% case.
    @MainActor
    static func jump(to session: Session) {
        if let pid = session.appPid, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        // The terminal is gone (or was never identified) — show the work instead.
        revealProject(session)
    }

    @MainActor
    static func revealProject(_ session: Session) {
        guard !session.cwd.isEmpty else { return }
        let url = URL(fileURLWithPath: session.cwd)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
