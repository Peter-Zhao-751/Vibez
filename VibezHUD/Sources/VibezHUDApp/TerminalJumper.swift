import AppKit
import VibezSessionKit

/// What a click on a row will do. Split out from doing it so the decision can be
/// tested and inspected — performing it activates another app or opens a Finder
/// window, which is not something a test or a verification run may do.
enum JumpPlan: Equatable {
    case activate(pid_t)
    case reveal(URL)
    case nothing
}

enum TerminalJumper {
    /// Resolving the pid is the whole trick. `appPid` is written by the plugins'
    /// `hud_process_chain`, which walks to the OUTERMOST `.app` ancestor — and it
    /// has to, because the inner bundle is often not a GUI app at all. Claude
    /// Code, for instance, ships its CLI inside `claude.app`, whose pid
    /// `NSRunningApplication` refuses to resolve; stopping at the first `.app`
    /// would make every jump silently fall through to the Finder branch.
    @MainActor
    static func plan(for session: Session) -> JumpPlan {
        if let pid = session.appPid, pid > 0,
           NSRunningApplication(processIdentifier: pid) != nil {
            return .activate(pid)
        }
        // The terminal is gone (or was never identified) — show the work instead.
        guard !session.cwd.isEmpty else { return .nothing }
        let url = URL(fileURLWithPath: session.cwd)
        guard FileManager.default.fileExists(atPath: url.path) else { return .nothing }
        return .reveal(url)
    }

    /// App-level activation needs no permissions at all. Raising a SPECIFIC
    /// window among several would need Accessibility, so it is deliberately not
    /// attempted here — the app coming forward is the 90% case.
    @MainActor
    static func jump(to session: Session) {
        switch plan(for: session) {
        case .activate(let pid):
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .nothing:
            break
        }
    }
}
