import Foundation
import VibezSessionKit

// Usage: vibez-hud-probe [path/to/events.jsonl] [path/to/remote-fixture.json]
// Prints the HUDSnapshot as stable, sorted JSON so tests can diff it. The
// optional second argument is a JSON array of RemoteEventDoc, fixture-injected
// so tests can exercise the remote merge without any network.

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : HUDPaths.defaultLogURL.path

let fixtureDocs: [RemoteEventDoc]
if CommandLine.arguments.count > 2,
   let data = FileManager.default.contents(atPath: CommandLine.arguments[2]) {
    fixtureDocs = (try? JSONDecoder().decode([RemoteEventDoc].self, from: data)) ?? []
} else {
    fixtureDocs = []
}

let engine = HUDEngine(logURL: URL(fileURLWithPath: path))
var snap = engine.primeAndDrain()
if !fixtureDocs.isEmpty {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    snap = engine.snapshotMerging(remoteDocs: fixtureDocs, now: now)
}

func rows(_ sessions: [Session]) -> [[String: Any]] {
    sessions.map { s in
        var row: [String: Any] = [
            "sid": s.sid,
            "agent": s.agent.rawValue,
            "state": s.state.rawValue,
            "proj": s.proj,
            "title": s.title,
        ]
        if let t = s.tool { row["tool"] = t }
        if let d = s.detail { row["detail"] = d }
        if let m = s.machine { row["machine"] = m }
        return row
    }
}

let payload: [String: Any] = [
    "needsYou": rows(snap.needsYou),
    "done": rows(snap.done),
    "working": rows(snap.working),
]

let data = try JSONSerialization.data(withJSONObject: payload,
                                      options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
