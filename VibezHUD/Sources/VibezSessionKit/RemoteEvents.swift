import Foundation

/// One event doc from the server's per-Vibez-ID log
/// (`events/{vibezId}/items` in the "tokens" Firestore database) — the
/// same log the Chrome extension listens to. Codable so probe fixtures
/// can inject canned docs without any network.
public struct RemoteEventDoc: Codable, Sendable, Equatable {
    public var session: String
    public var agent: String
    public var event: String?
    public var shield: String?
    public var title: String
    public var body: String?
    public var machine: String?
    public var createdAtMs: Int64

    public init(session: String, agent: String, event: String?, shield: String?,
                title: String, body: String?, machine: String?, createdAtMs: Int64) {
        self.session = session; self.agent = agent; self.event = event
        self.shield = shield; self.title = title; self.body = body
        self.machine = machine; self.createdAtMs = createdAtMs
    }
}

/// Decodes a Firestore REST `documents:runQuery` response. Tolerant by
/// design: bare read-time rows, unknown fields and malformed docs are
/// skipped — a bad server response must never take down the panel.
public enum FirestoreRESTParser {
    public static func parse(_ data: Data) -> [RemoteEventDoc] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let document = row["document"] as? [String: Any],
                  let fields = document["fields"] as? [String: Any] else { return nil }
            func str(_ key: String) -> String? {
                (fields[key] as? [String: Any])?["stringValue"] as? String
            }
            func int(_ key: String) -> Int64? {
                let v = fields[key] as? [String: Any]
                if let s = v?["integerValue"] as? String { return Int64(s) }
                if let d = v?["doubleValue"] as? Double { return Int64(d) }
                return nil
            }
            guard let session = str("session"), !session.isEmpty, session != "nosid",
                  let createdAtMs = int("createdAtMs") else { return nil }
            return RemoteEventDoc(session: session,
                                  agent: str("agent") ?? "cc",
                                  event: str("event"),
                                  shield: str("shield"),
                                  title: str("title") ?? "",
                                  body: str("body"),
                                  machine: str("machine"),
                                  createdAtMs: createdAtMs)
        }
    }
}

/// Folds raw event docs into displayable remote `Session`s. The server
/// only sees phone-worthy moments, so the mapping is deliberately
/// coarse: needs-input → needsYou, done → done, replied/shield-off →
/// working (the user answered; the agent resumed). Time rules mirror
/// the local store: done expires after `retentionMs`, anything else
/// goes stale after `staleMs` (remote rows have no pid to probe).
public enum RemoteReducer {
    public static func sessions(docs: [RemoteEventDoc], now: Int64,
                                config: StoreConfig = StoreConfig()) -> [Session] {
        var newest: [String: RemoteEventDoc] = [:]
        for d in docs where (newest[d.session]?.createdAtMs ?? .min) < d.createdAtMs {
            newest[d.session] = d
        }
        return newest.values.compactMap { d in
            let state: SessionState
            if d.shield == "off" || d.event == "replied" {
                state = .working
            } else if d.event == "needs-input" {
                state = .needsYou
            } else if d.event == "done" {
                state = .done
            } else {
                return nil   // informational push — no row
            }
            let age = now - d.createdAtMs
            if state == .done { if age > config.retentionMs { return nil } }
            else if age > config.staleMs { return nil }
            return Session(sid: d.session,
                           agent: AgentTag(rawValue: d.agent) ?? .claude,
                           proj: "", cwd: "", title: d.title,
                           detail: d.body, tool: nil, state: state,
                           startedAtMs: d.createdAtMs, lastActivityMs: d.createdAtMs,
                           stateSinceMs: d.createdAtMs,
                           agentPid: nil, agentStart: nil, appPid: nil, app: nil,
                           machine: d.machine ?? "remote")
        }
    }
}
