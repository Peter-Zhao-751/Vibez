import Foundation

public enum AgentTag: String, Codable, Sendable, CaseIterable {
    case claude = "cc", codex = "cx", cursor = "cu"
}

public enum EventKind: String, Codable, Sendable {
    case start, prompt, tool
    case needsInput = "needs-input"
    case done, end

    /// Tie-break when two records share a millisecond. Terminal and blocking
    /// facts outrank routine heartbeats: if a permission request and a tool
    /// completion land in the same ms, "blocked on you" is the truthful state.
    var priority: Int {
        switch self {
        case .end: 5
        case .needsInput: 4
        case .done: 3
        case .prompt: 2
        case .tool: 1
        case .start: 0
        }
    }
}

public struct HUDEvent: Codable, Sendable, Equatable {
    public let v: Int
    public let ts: Int64
    public let sid: String
    public let agent: AgentTag
    public let kind: EventKind
    public let proj: String
    public let cwd: String
    public let title: String
    public let body: String?
    public let tool: String?
    public let agentPid: Int32?
    public let agentStart: String?
    public let appPid: Int32?
    public let app: String?

    private enum CodingKeys: String, CodingKey {
        case v, ts, sid, agent, kind, proj, cwd, title, body, tool
        case agentPid, agentStart, appPid, app
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        ts = try c.decode(Int64.self, forKey: .ts)
        sid = try c.decode(String.self, forKey: .sid)
        // Unknown agent tags fall back to Claude rather than dropping the line.
        agent = AgentTag(rawValue: try c.decode(String.self, forKey: .agent)) ?? .claude
        kind = try c.decode(EventKind.self, forKey: .kind)
        proj = try c.decodeIfPresent(String.self, forKey: .proj) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        agentPid = try c.decodeIfPresent(Int32.self, forKey: .agentPid)
        agentStart = try c.decodeIfPresent(String.self, forKey: .agentStart)
        appPid = try c.decodeIfPresent(Int32.self, forKey: .appPid)
        app = try c.decodeIfPresent(String.self, forKey: .app)
    }
}

public enum HUDEventDecoder {
    public static let schemaVersion = 1

    /// Returns nil for anything unusable. A bad line must never take down the tail.
    public static func decodeLine(_ line: String) -> HUDEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let event = try? JSONDecoder().decode(HUDEvent.self, from: data) else { return nil }
        guard event.v == schemaVersion else { return nil }
        guard !event.sid.isEmpty, event.sid != "nosid" else { return nil }
        return event
    }
}
