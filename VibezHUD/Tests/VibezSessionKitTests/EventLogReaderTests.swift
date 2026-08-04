import Testing
import Foundation
@testable import VibezSessionKit

@Test func readsOnlyNewLinesOnEachCall() {
    let log = TempLog()
    log.appendLine(kind: "start", ts: 1)
    let r = EventLogReader(url: log.url)
    #expect(r.readNew().count == 1)
    #expect(r.readNew().isEmpty)              // nothing new
    log.appendLine(kind: "prompt", ts: 2)
    #expect(r.readNew().map(\.kind) == [.prompt])
}

@Test func neverConsumesAHalfWrittenLine() {
    let log = TempLog()
    let r = EventLogReader(url: log.url)
    log.appendRaw(#"{"v":1,"ts":1,"sid":"s1","agent":"cc","kind":"st"#)   // torn
    #expect(r.readNew().isEmpty, "a partial line must be buffered, not parsed")
    log.appendRaw("art\",\"proj\":\"P\",\"cwd\":\"/tmp/P\",\"title\":\"T\"}\n")
    #expect(r.readNew().map(\.kind) == [.start])
}

@Test func survivesRotationWithoutLosingTheOldTail() {
    let log = TempLog()
    let r = EventLogReader(url: log.url)
    log.appendLine(kind: "start", ts: 1)
    _ = r.readNew()
    log.appendLine(kind: "prompt", ts: 2)      // written, not yet read
    log.rotate()
    log.appendLine(kind: "tool", ts: 3)        // in the NEW file
    let got = r.readNew().map(\.kind)
    #expect(got == [.prompt, .tool], "the pre-rotation tail must be drained first")
}

@Test func recoversFromTruncation() {
    let log = TempLog()
    let r = EventLogReader(url: log.url)
    log.appendLine(kind: "start", ts: 1)
    log.appendLine(kind: "prompt", ts: 2)
    _ = r.readNew()
    log.truncate()
    log.appendLine(kind: "tool", ts: 3)
    #expect(r.readNew().map(\.kind) == [.tool])
}

@Test func primeFromTailIsBoundedAndDropsThePartialFirstLine() {
    let log = TempLog()
    for i in 1...400 { log.appendLine(kind: "tool", ts: Int64(i), title: String(repeating: "x", count: 60)) }
    let r = EventLogReader(url: log.url)
    let primed = r.primeFromTail(maxBytes: 4_096)
    #expect(!primed.isEmpty)
    #expect(primed.count < 400, "must not replay the whole file")
    // Every survivor decoded cleanly => the leading partial line was discarded.
    #expect(primed.allSatisfy { $0.sid == "s1" })
    #expect(r.readNew().isEmpty, "priming must leave the offset at EOF")
}

@Test func primeFromTailKeepsATornTrailingLineSoItIsNotLost() {
    // Cold start while the writer is mid-write. The head of the unfinished line
    // must be BUFFERED, not discarded — if it is dropped, the writer's later
    // completion arrives as an orphan fragment that cannot decode, and the
    // event is lost permanently with no error anywhere.
    let log = TempLog()
    for i in 1...200 { log.appendLine(kind: "tool", ts: Int64(i), title: String(repeating: "x", count: 60)) }
    log.appendRaw(#"{"v":1,"ts":999,"sid":"torn","agent":"cc","kind":"needs-inp"#)

    let r = EventLogReader(url: log.url)
    let primed = r.primeFromTail(maxBytes: 4_096)
    #expect(!primed.contains { $0.sid == "torn" }, "an incomplete line must not be emitted yet")

    log.appendRaw("ut\",\"proj\":\"P\",\"cwd\":\"/tmp/P\",\"title\":\"T\"}\n")   // writer finishes it
    #expect(r.readNew().contains { $0.sid == "torn" && $0.kind == .needsInput },
            "the buffered head plus the completion must reconstitute the event")
}

@Test func missingFileIsNotAnError() {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let r = EventLogReader(url: dir.appendingPathComponent("nope.jsonl"))
    #expect(r.primeFromTail(maxBytes: 1024).isEmpty)
    #expect(r.readNew().isEmpty)
}

@Test func engineTurnsALogIntoASnapshot() {
    let log = TempLog()
    log.appendLine(kind: "start", ts: 1_000, sid: "a", title: "Notch app")
    log.appendLine(kind: "prompt", ts: 1_001, sid: "a", title: "Notch app")
    log.appendLine(kind: "needs-input", ts: 1_002, sid: "a", title: "Notch app")
    log.appendLine(kind: "tool", ts: 1_003, sid: "b", title: "Other")

    let clock = FakeClock(2_000)
    let engine = HUDEngine(logURL: log.url,
                           config: StoreConfig(staleMs: .max),
                           clock: clock,
                           liveness: FakeLiveness())
    let snap = engine.primeAndDrain()
    #expect(snap.needsYou.map(\.sid) == ["a"])
    #expect(snap.working.map(\.sid) == ["b"])
    #expect(snap.done.isEmpty)
}
