import Testing
import Foundation
import AppKit
import VibezSessionKit
@testable import VibezHUDApp

private func session(appPid: Int32?, cwd: String) -> Session {
    Session(sid: "s1", agent: .claude, proj: "proj", cwd: cwd, title: "t",
            detail: nil, tool: nil, state: .working,
            startedAtMs: 0, lastActivityMs: 0, stateSinceMs: 0,
            agentPid: nil, agentStart: nil, appPid: appPid, app: "Terminal")
}

/// A pid that cannot be a running application: 0 is never a user process, and
/// the walk writes 0 when it found no `.app` ancestor at all.
@Test @MainActor func aMissingAppPidFallsBackToRevealingTheProject() {
    let dir = NSTemporaryDirectory()
    #expect(TerminalJumper.plan(for: session(appPid: nil, cwd: dir))
            == .reveal(URL(fileURLWithPath: dir)))
    #expect(TerminalJumper.plan(for: session(appPid: 0, cwd: dir))
            == .reveal(URL(fileURLWithPath: dir)))
}

/// The row whose terminal was quit AND whose directory is gone: a dead click has
/// to be genuinely inert, not a crash and not a Finder window at "/".
@Test @MainActor func aVanishedProjectDirectoryDoesNothingAtAll() {
    let gone = "/tmp/vibez-hud-does-not-exist-\(UUID().uuidString)"
    #expect(!FileManager.default.fileExists(atPath: gone))
    #expect(TerminalJumper.plan(for: session(appPid: nil, cwd: gone)) == .nothing)
}

@Test @MainActor func anEmptyCwdDoesNothing() {
    #expect(TerminalJumper.plan(for: session(appPid: nil, cwd: "")) == .nothing)
}

/// A pid that was real once but has since exited must NOT be activated — it must
/// degrade to the project reveal. `NSRunningApplication` returning nil is the
/// only signal available, so this pins that we consult it rather than trusting
/// the recorded number.
@Test @MainActor func aDeadPidDegradesToTheProjectRevealRatherThanActivating() {
    // Reap a real child so the pid is definitively not a running application.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "exit 0"]
    try? p.run()
    p.waitUntilExit()
    let deadPid = p.processIdentifier
    #expect(deadPid > 0)

    let dir = NSTemporaryDirectory()
    #expect(TerminalJumper.plan(for: session(appPid: deadPid, cwd: dir))
            == .reveal(URL(fileURLWithPath: dir)))
}

/// The live case. It cannot be self-hosted: `NSRunningApplication` only resolves
/// processes LaunchServices knows about, and this test binary is a plain CLI
/// tool, so its own pid returns nil. Borrow a real registered app instead.
@Test @MainActor func aLivePidActivatesInsteadOfRevealing() {
    guard let live = NSWorkspace.shared.runningApplications
        .first(where: { $0.activationPolicy == .regular })?.processIdentifier else {
        // No GUI session (headless CI). Nothing to assert; the reveal branches
        // above still cover the fallback half.
        return
    }
    #expect(TerminalJumper.plan(for: session(appPid: live, cwd: NSTemporaryDirectory()))
            == .activate(live))
    // ...and the reveal fallback must NOT win when the app is alive, even though
    // the directory exists and would otherwise qualify.
    #expect(TerminalJumper.plan(for: session(appPid: live, cwd: NSTemporaryDirectory()))
            != .reveal(URL(fileURLWithPath: NSTemporaryDirectory())))
}
