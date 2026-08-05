import Foundation
import VibezSessionKit

/// `--demo` seeds one session in every state so the whole UI is inspectable in
/// one second, with no agents running.
enum DemoData {
    static func snapshot() -> HUDSnapshot {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func s(_ sid: String, _ agent: AgentTag, _ proj: String, _ title: String,
               _ state: SessionState, _ tool: String?, _ detail: String?, _ agoMs: Int64) -> Session {
            Session(sid: sid, agent: agent, proj: proj, cwd: "/tmp/\(proj)", title: title,
                    detail: detail, tool: tool, state: state,
                    startedAtMs: now - agoMs - 60_000, lastActivityMs: now - agoMs,
                    stateSinceMs: now - agoMs, agentPid: nil, agentStart: nil,
                    appPid: nil, app: nil)
        }
        return HUDSnapshot(
            needsYou: [
                s("d1", .claude, "Vibez", "Mac notch app", .needsYou, "Bash", "rm -rf build", 12_000),
                s("d2", .codex, "vibez-backend", "Deploy the ratelimit fix", .needsYou, nil, "deploy to prod now?", 61_000),
            ],
            done: [
                s("d3", .claude, "carousel", "Export spread stills", .done, nil, nil, 8 * 60_000),
                s("d4", .claude, "ClaudePlugin", "Approval watcher port", .ended, nil, nil, 40 * 60_000),
            ],
            working: [
                s("d5", .codex, "vibez-backend", "Rate-limit escalation", .working, "Edit", "ratelimit.ts", 3_000),
                s("d6", .claude, "VibezExtension", "Popup analytics", .working, "Bash", "npm test", 40_000),
            ])
    }
}
