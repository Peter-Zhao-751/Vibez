// VibezHUD/Tests/VibezSessionKitTests/RemoteEventsTests.swift
import Foundation
import Testing
@testable import VibezSessionKit

private func doc(_ session: String, event: String?, shield: String? = nil,
                 agent: String = "cc", machine: String? = "mbp-air",
                 atMs: Int64) -> RemoteEventDoc {
    RemoteEventDoc(session: session, agent: agent, event: event, shield: shield,
                   title: "T", body: "B", machine: machine, createdAtMs: atMs)
}

// MARK: - REST parsing

@Test func parsesARunQueryResponse() {
    let json = """
    [
      {"document": {"name": "projects/p/databases/tokens/documents/events/id/items/a1",
        "fields": {
          "title": {"stringValue": "Claude is done"},
          "body": {"stringValue": "Finished."},
          "event": {"stringValue": "done"},
          "shield": {"stringValue": "on"},
          "session": {"stringValue": "sess-1"},
          "agent": {"stringValue": "cc"},
          "machine": {"stringValue": "mbp-air"},
          "createdAtMs": {"integerValue": "170000"}
        }}, "readTime": "2026-08-05T00:00:00Z"},
      {"readTime": "2026-08-05T00:00:00Z"}
    ]
    """
    let docs = FirestoreRESTParser.parse(json.data(using: .utf8)!)
    #expect(docs.count == 1)
    #expect(docs.first == RemoteEventDoc(session: "sess-1", agent: "cc", event: "done",
                                         shield: "on", title: "Claude is done", body: "Finished.",
                                         machine: "mbp-air", createdAtMs: 170_000))
}

@Test func parserSkipsDocsWithoutAUsableSession() {
    let json = """
    [{"document": {"name": "x", "fields": {
        "title": {"stringValue": "test ping"}, "createdAtMs": {"integerValue": "1"}}}},
     {"document": {"name": "y", "fields": {
        "title": {"stringValue": "t"}, "session": {"stringValue": "nosid"},
        "createdAtMs": {"integerValue": "2"}}}}]
    """
    #expect(FirestoreRESTParser.parse(json.data(using: .utf8)!).isEmpty)
}

@Test func parserToleratesGarbage() {
    #expect(FirestoreRESTParser.parse(Data("not json".utf8)).isEmpty)
    #expect(FirestoreRESTParser.parse(Data("{}".utf8)).isEmpty)
}

// MARK: - reduction

@Test func newestDocPerSessionWins() {
    let sessions = RemoteReducer.sessions(docs: [
        doc("s", event: "done", atMs: 2_000),
        doc("s", event: "needs-input", atMs: 1_000),
    ], now: 10_000)
    #expect(sessions.map(\.state) == [.done])
}

@Test func eventMappingMatchesTheSpec() {
    let now: Int64 = 100_000
    #expect(RemoteReducer.sessions(docs: [doc("a", event: "needs-input", atMs: now)], now: now).first?.state == .needsYou)
    #expect(RemoteReducer.sessions(docs: [doc("b", event: "done", atMs: now)], now: now).first?.state == .done)
    #expect(RemoteReducer.sessions(docs: [doc("c", event: "replied", atMs: now)], now: now).first?.state == .working)
    // shield:off with no event (timeout-ish shapes) also means resumed.
    #expect(RemoteReducer.sessions(docs: [doc("d", event: nil, shield: "off", atMs: now)], now: now).first?.state == .working)
    // A needs-input whose doc says shield off is a reply race — resumed wins.
    #expect(RemoteReducer.sessions(docs: [doc("e", event: "needs-input", shield: "off", atMs: now)], now: now).first?.state == .working)
    // No event, shield on: informational — no row.
    #expect(RemoteReducer.sessions(docs: [doc("f", event: nil, shield: "on", atMs: now)], now: now).isEmpty)
}

@Test func remoteDoneExpiresAfterRetention() {
    let d = [doc("s", event: "done", atMs: 0)]
    #expect(RemoteReducer.sessions(docs: d, now: 5 * 60_000 - 1).count == 1)
    #expect(RemoteReducer.sessions(docs: d, now: 5 * 60_000 + 1).isEmpty)
}

@Test func remoteNonDoneGoesStaleAfterStaleMs() {
    let d = [doc("s", event: "needs-input", atMs: 0)]
    #expect(RemoteReducer.sessions(docs: d, now: 30 * 60_000 - 1).count == 1)
    #expect(RemoteReducer.sessions(docs: d, now: 30 * 60_000 + 1).isEmpty)
}

@Test func machineFallsBackToRemote() {
    let s = RemoteReducer.sessions(docs: [doc("s", event: "done", machine: nil, atMs: 0)], now: 0)
    #expect(s.first?.machine == "remote")
}

@Test func agentTagDecodesWithClaudeFallback() {
    let s = RemoteReducer.sessions(docs: [doc("s", event: "done", agent: "cx", atMs: 0),
                                          doc("t", event: "done", agent: "??", atMs: 0)], now: 0)
    #expect(s.first(where: { $0.sid == "s" })?.agent == .codex)
    #expect(s.first(where: { $0.sid == "t" })?.agent == .claude)
}
