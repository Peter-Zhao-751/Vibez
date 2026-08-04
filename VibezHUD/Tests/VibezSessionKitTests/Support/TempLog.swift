import Foundation

final class TempLog {
    let dir: URL
    let url: URL

    init() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibez-hud-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Appends raw text exactly as given — used to simulate torn writes.
    func appendRaw(_ text: String) {
        let h = try! FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(text.data(using: .utf8)!)
        try? h.close()
    }

    func appendLine(kind: String, ts: Int64, sid: String = "s1", title: String = "T") {
        appendRaw(#"{"v":1,"ts":\#(ts),"sid":"\#(sid)","agent":"cc","kind":"\#(kind)","proj":"P","cwd":"/tmp/P","title":"\#(title)"}"# + "\n")
    }

    func rotate() {
        try? FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("events.jsonl.1"))
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func truncate() {
        let h = try! FileHandle(forWritingTo: url)
        try! h.truncate(atOffset: 0)
        try? h.close()
    }
}
