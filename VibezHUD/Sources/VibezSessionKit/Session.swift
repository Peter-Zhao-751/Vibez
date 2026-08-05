import Foundation

public enum SessionState: String, Sendable, Equatable {
    case idle, working, needsYou, done, ended
}

public struct Session: Sendable, Equatable, Identifiable {
    public var sid: String
    public var agent: AgentTag
    public var proj: String
    public var cwd: String
    public var title: String
    public var detail: String?
    public var tool: String?
    public var state: SessionState
    public var startedAtMs: Int64
    public var lastActivityMs: Int64
    public var stateSinceMs: Int64
    public var agentPid: Int32?
    public var agentStart: String?
    public var appPid: Int32?
    public var app: String?

    public var id: String { sid }

    /// The memberwise initialiser is internal by default, which puts `Session`
    /// out of reach of the app target (`--demo` seeding, previews). Same order,
    /// same semantics — only the access level differs.
    public init(sid: String, agent: AgentTag, proj: String, cwd: String, title: String,
                detail: String?, tool: String?, state: SessionState,
                startedAtMs: Int64, lastActivityMs: Int64, stateSinceMs: Int64,
                agentPid: Int32?, agentStart: String?, appPid: Int32?, app: String?) {
        self.sid = sid; self.agent = agent; self.proj = proj; self.cwd = cwd
        self.title = title; self.detail = detail; self.tool = tool; self.state = state
        self.startedAtMs = startedAtMs; self.lastActivityMs = lastActivityMs
        self.stateSinceMs = stateSinceMs; self.agentPid = agentPid
        self.agentStart = agentStart; self.appPid = appPid; self.app = app
    }
}

/// Exactly the three columns the UI renders. ENDED lives inside `done`.
public struct HUDSnapshot: Sendable, Equatable {
    public var needsYou: [Session]
    public var done: [Session]
    public var working: [Session]

    public init(needsYou: [Session] = [], done: [Session] = [], working: [Session] = []) {
        self.needsYou = needsYou; self.done = done; self.working = working
    }

    public var isEmpty: Bool { needsYou.isEmpty && done.isEmpty && working.isEmpty }
}
