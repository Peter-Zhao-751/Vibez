import Testing
import Foundation
@testable import VibezSessionKit

// Everything else in this suite asserts a specific transition. These two
// assert that NOTHING the reducer can be fed — real history or an absurd
// storm — produces a state the panel cannot render.

// MARK: - the invariants

/// What must hold of any snapshot, whatever produced it. Returns descriptions
/// rather than tripping `#expect` per session: the storm below takes ~25k
/// snapshots, and one expectation per field would dominate the runtime while
/// burying the failing sequence.
private func invariantViolations(_ snap: HUDSnapshot) -> [String] {
    var bad: [String] = []

    // A column IS a state. The UI reads the arrays, not the field, so a
    // mismatch renders a "working" row under the NEEDS YOU header.
    for s in snap.needsYou where s.state != .needsYou {
        bad.append("needsYou column holds \(s.sid) in state .\(s.state.rawValue)")
    }
    for s in snap.working where s.state != .working {
        bad.append("working column holds \(s.sid) in state .\(s.state.rawValue)")
    }
    for s in snap.done where !(s.state == .done || s.state == .ended) {
        bad.append("done column holds \(s.sid) in state .\(s.state.rawValue)")
    }

    let all = snap.needsYou + snap.working + snap.done
    let ids = all.map(\.sid)
    if Set(ids).count != ids.count {
        bad.append("a session appeared in two columns: \(ids.sorted())")
    }
    for s in all where s.sid.isEmpty {
        bad.append("a session rendered with an empty sid")
    }

    // Time never runs backwards inside a row. `stateSinceMs` drives the
    // "waiting 4m" label and `lastActivityMs` the sort, so an inversion shows
    // up as a negative duration.
    for s in all {
        if s.lastActivityMs < s.startedAtMs {
            bad.append("\(s.sid): lastActivity \(s.lastActivityMs) < startedAt \(s.startedAtMs)")
        }
        if s.stateSinceMs < s.startedAtMs {
            bad.append("\(s.sid): stateSince \(s.stateSinceMs) < startedAt \(s.startedAtMs)")
        }
        if s.stateSinceMs > s.lastActivityMs {
            bad.append("\(s.sid): stateSince \(s.stateSinceMs) > lastActivity \(s.lastActivityMs)")
        }
    }

    // The ordering contract the panel depends on: longest wait at the top of
    // NEEDS YOU, most recent first everywhere else.
    for (a, b) in zip(snap.needsYou, snap.needsYou.dropFirst()) where a.stateSinceMs > b.stateSinceMs {
        bad.append("needsYou out of order: \(a.sid) then \(b.sid)")
    }
    for (a, b) in zip(snap.working, snap.working.dropFirst()) where a.lastActivityMs < b.lastActivityMs {
        bad.append("working out of order: \(a.sid) then \(b.sid)")
    }
    for (a, b) in zip(snap.done, snap.done.dropFirst()) where a.lastActivityMs < b.lastActivityMs {
        bad.append("done out of order: \(a.sid) then \(b.sid)")
    }
    return bad
}

/// 0 = the user still owes this session something, 1 = it is finished.
/// Time alone must never move a row back from 1 to 0.
private func columnRank(_ s: Session) -> Int {
    switch s.state {
    case .needsYou, .working, .idle: 0
    case .done, .ended: 1
    }
}

// MARK: - fuzzing

@Test func randomEventStormsNeverProduceAnImpossibleState() {
    let kinds: [EventKind] = [.start, .prompt, .tool, .needsInput, .done, .end]
    // Fixed seed on purpose: a failure here has to be reproducible from the
    // round + step printed in the message, and `Math.random`-style entropy
    // would make that a coin flip.
    var seed: UInt64 = 0x5EED
    func rnd(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }

    for round in 0..<200 {
        let clock = FakeClock(1_000_000)
        let live = FakeLiveness()
        live.table[999] = (true, nil)          // 1000 is deliberately absent = dead
        let store = SessionStore(clock: clock, liveness: live)
        var trace: [String] = []

        for step in 0..<120 {
            let kind = kinds[rnd(kinds.count)]
            let sid = "s\(rnd(6))"
            // Timestamps deliberately jitter backwards: two hooks racing to
            // append is normal, so the reducer's staleness guard is on the
            // hot path, not an edge case.
            let ts = Int64(1_000_000 + rnd(4_000) - 2_000)
            // All three liveness worlds — no PID (staleness only), a live PID,
            // and a dead one — because they take different branches in resolve.
            let pid: Int32? = switch rnd(3) { case 0: nil; case 1: 999; default: 1000 }

            store.apply(makeEvent(kind, ts: ts, sid: sid, agentPid: pid))
            trace.append("\(step):\(kind.rawValue)@\(ts)->\(sid)[pid \(pid.map(String.init) ?? "-")]")
            if rnd(9) == 0 { clock.advance(ms: Int64(rnd(9_000))) }

            let bad = invariantViolations(store.snapshot())
            if !bad.isEmpty {
                Issue.record("""
                    round \(round) step \(step): \(bad.joined(separator: "; "))
                    sequence: \(trace.joined(separator: " "))
                    """)
                return
            }
        }

        // snapshot() must be a pure read: two calls with the clock held still
        // have to agree, or the panel flickers between identical polls.
        #expect(store.snapshot() == store.snapshot(), "snapshot() is not idempotent in round \(round)")

        // With no further events, time may only finish sessions, never revive
        // them into NEEDS YOU or WORKING.
        let before = store.snapshot()
        var rankBefore: [String: Int] = [:]
        for s in before.needsYou + before.working + before.done { rankBefore[s.sid] = columnRank(s) }
        clock.advance(ms: 45 * 60 * 1_000)
        let after = store.snapshot()
        for s in after.needsYou + after.working + after.done {
            guard let was = rankBefore[s.sid] else { continue }
            #expect(columnRank(s) >= was,
                    "round \(round): \(s.sid) went backwards to .\(s.state.rawValue) as the clock advanced")
        }
        #expect(invariantViolations(after).isEmpty,
                "round \(round) after advancing the clock: \(invariantViolations(after))")
    }
}

// MARK: - replaying the real machine

/// The human-readable log the plugins have been appending to since May. It is
/// not the HUD schema, so this transcodes it into HUD records — the point is
/// the SHAPES real usage produces (bursts, day-long gaps, interleaved
/// sessions, agents mixed), which no hand-written fixture reproduces.
private struct ReplayLine {
    var ts: Int64
    var sid: String
    var agent: AgentTag
    var kind: EventKind
}

private func transcode(_ raw: String) -> [ReplayLine] {
    var out: [ReplayLine] = []
    var lastTs: Int64 = 0
    var bucket = 0

    for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        let text = String(line)

        // "[2026-05-10T06:30:25Z] ..." — parsed by hand rather than with a
        // DateFormatter so the replay cannot depend on the machine's locale.
        var ts = lastTs
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let stamp = text[text.index(after: text.startIndex)..<close]
            if let parsed = epochMs(fromISO8601: String(stamp)) { ts = parsed }
        }
        guard ts > 0 else { continue }
        lastTs = ts

        let body = text.contains("] ") ? String(text[text.range(of: "] ")!.upperBound...]) : text
        let agent: AgentTag = body.hasPrefix("cx ") ? .codex : .claude

        let kind: EventKind
        if body.contains("session-start") { kind = .start }
        else if body.contains("(event=replied)") || body.contains("user-prompt-submit") { kind = .prompt }
        else if body.contains("(event=needs-input)") { kind = .needsInput }
        else if body.contains("(event=done)") { kind = .done }
        else if body.contains("notification: received") { kind = .needsInput }
        else if body.contains("post-tool-use") || body.contains("pre-tool-use") { kind = .tool }
        else if body.contains("stop:") { kind = .done }
        else { continue }

        // Real session ids where the line carries one; otherwise round-robin
        // into a few buckets so sessions actually accumulate history instead
        // of every event landing on a session of its own.
        var sid = "bucket\(bucket % 7)"
        if let r = body.range(of: "sid=") {
            let rest = body[r.upperBound...].prefix { $0 != ")" && $0 != " " && $0 != "," }
            if !rest.isEmpty { sid = String(rest) }
        }
        bucket += 1

        out.append(ReplayLine(ts: ts, sid: sid, agent: agent, kind: kind))
    }
    return out
}

/// "2026-05-10T06:30:25Z" -> epoch ms. Nil for anything that isn't that shape.
private func epochMs(fromISO8601 s: String) -> Int64? {
    let d = Array(s.utf8)
    guard d.count >= 20, s.hasSuffix("Z") else { return nil }
    func num(_ lo: Int, _ hi: Int) -> Int? {
        var v = 0
        for i in lo..<hi {
            let c = Int(d[i]) - 48
            guard (0...9).contains(c) else { return nil }
            v = v * 10 + c
        }
        return v
    }
    guard let y = num(0, 4), let mo = num(5, 7), let day = num(8, 10),
          let h = num(11, 13), let mi = num(14, 16), let sec = num(17, 19),
          (1...12).contains(mo), (1...31).contains(day) else { return nil }

    // Days from 1970-01-01 (Howard Hinnant's civil-from-days, inverted).
    let yAdj = y - (mo <= 2 ? 1 : 0)
    let era = (yAdj >= 0 ? yAdj : yAdj - 399) / 400
    let yoe = yAdj - era * 400
    let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return (Int64(days) * 86_400 + Int64(h * 3_600 + mi * 60 + sec)) * 1_000
}

@Test func replayingTheRealVibezLogNeverBreaksTheReducer() {
    // VIBEZ_REPLAY_LOG overrides the path. It exists because NSHomeDirectory()
    // on macOS reads getpwuid, NOT $HOME, so there is otherwise no way to
    // exercise the skip path below or point this at a captured log.
    let logPath = ProcessInfo.processInfo.environment["VIBEZ_REPLAY_LOG"]
        .map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/vibez/log")

    // Skipped cleanly on a machine that has never run the plugins — this test
    // is a bonus stressor, never a reason for a fresh clone to go red. Read
    // only; nothing here ever writes to the user's Vibez state.
    guard let raw = try? String(contentsOf: logPath, encoding: .utf8),
          !raw.isEmpty else { return }

    let events = transcode(raw)
    #expect(!events.isEmpty, "the log has \(raw.count) bytes but nothing transcoded — the parser drifted")
    guard !events.isEmpty else { return }

    // Real timestamps, not a synthetic +1s ramp: the day-long gaps between
    // sessions are exactly what drives the staleness and retention paths, and
    // the clock is walked alongside them so each checkpoint looks at the
    // sessions that were live at that moment rather than a graveyard.
    let clock = FakeClock(events[0].ts)
    let store = SessionStore(clock: clock, liveness: FakeLiveness())
    var sawSomething = false

    for (i, e) in events.enumerated() {
        store.apply(makeEvent(e.kind, ts: e.ts, sid: e.sid, agent: e.agent))
        guard i % 25 == 0 || i == events.count - 1 else { continue }
        clock.set(e.ts + 5_000)
        let snap = store.snapshot()
        if !snap.isEmpty { sawSomething = true }
        let bad = invariantViolations(snap)
        if !bad.isEmpty {
            Issue.record("""
                broke at real event \(i) (\(e.kind.rawValue) ts=\(e.ts) sid=\(e.sid)): \
                \(bad.joined(separator: "; "))
                """)
            return
        }
    }

    // Long after the last event everything must have aged out cleanly rather
    // than leaving a row stuck in WORKING forever.
    clock.set(events[events.count - 1].ts + 4 * 60 * 60 * 1_000)
    let cold = store.snapshot()
    #expect(invariantViolations(cold).isEmpty, "\(invariantViolations(cold))")
    #expect(cold.working.isEmpty && cold.needsYou.isEmpty,
            "sessions survived 4h of silence: \(cold.working.count) working, \(cold.needsYou.count) needsYou")

    #expect(sawSomething, "replayed \(events.count) real events and never rendered a single row")
}
