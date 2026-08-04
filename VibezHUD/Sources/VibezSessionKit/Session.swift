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
