import Foundation
import Testing
@testable import VibezSessionKit

func makeEvent(_ kind: EventKind, ts: Int64, sid: String = "s1",
               agent: AgentTag = .claude, proj: String = "Vibez",
               cwd: String = "/tmp/Vibez", title: String = "Notch app",
               body: String? = nil, tool: String? = nil,
               agentPid: Int32? = nil, agentStart: String? = nil) -> HUDEvent {
    let json: [String: Any?] = [
        "v": 1, "ts": ts, "sid": sid, "agent": agent.rawValue, "kind": kind.rawValue,
        "proj": proj, "cwd": cwd, "title": title, "body": body, "tool": tool,
        "agentPid": agentPid.map { Int($0) }, "agentStart": agentStart,
    ]
    let clean = json.compactMapValues { $0 }
    let data = try! JSONSerialization.data(withJSONObject: clean)
    return HUDEventDecoder.decodeLine(String(data: data, encoding: .utf8)!)!
}

private func newStore(_ clock: FakeClock, _ live: FakeLiveness = FakeLiveness()) -> SessionStore {
    SessionStore(config: StoreConfig(), clock: clock, liveness: live)
}

@Test func startAloneIsIdleAndRendersInNoColumn() {
    let clock = FakeClock(); let store = newStore(clock)
    store.apply(makeEvent(.start, ts: clock.nowMs))
    let snap = store.snapshot()
    #expect(snap.needsYou.isEmpty && snap.working.isEmpty && snap.done.isEmpty)
}

@Test func promptAndToolMeanWorking() {
    let clock = FakeClock(); let store = newStore(clock)
    store.apply(makeEvent(.start, ts: clock.nowMs))
    store.apply(makeEvent(.prompt, ts: clock.nowMs + 1))
    #expect(store.snapshot().working.map(\.sid) == ["s1"])

    store.apply(makeEvent(.tool, ts: clock.nowMs + 2, tool: "Edit"))
    let s = store.snapshot().working.first
    #expect(s?.state == .working)
    #expect(s?.tool == "Edit")
}

@Test func needsInputBlocksAndEndTerminates() {
    let clock = FakeClock(); let store = newStore(clock)
    store.apply(makeEvent(.prompt, ts: clock.nowMs))
    store.apply(makeEvent(.needsInput, ts: clock.nowMs + 1, body: "Bash: rm -rf build", tool: "Bash"))
    #expect(store.snapshot().needsYou.map(\.sid) == ["s1"])

    store.apply(makeEvent(.end, ts: clock.nowMs + 2))
    #expect(store.snapshot().needsYou.isEmpty)
    #expect(store.snapshot().done.first?.state == .ended)
}

@Test func endedSharesTheDoneColumn() {
    let clock = FakeClock(); let store = newStore(clock)
    store.apply(makeEvent(.prompt, ts: clock.nowMs, sid: "a"))
    store.apply(makeEvent(.done, ts: clock.nowMs + 1, sid: "a"))
    store.apply(makeEvent(.end, ts: clock.nowMs + 1, sid: "b", title: "other"))
    clock.advance(ms: 5_000)          // let the provisional done commit
    let done = store.snapshot().done
    #expect(Set(done.map(\.sid)) == ["a", "b"])
    #expect(done.first(where: { $0.sid == "a" })?.state == .done)
    #expect(done.first(where: { $0.sid == "b" })?.state == .ended)
}

@Test func fullTransitionMatrix() {
    // Every (kind) applied to a session in every state, asserting the result.
    // Rows: starting kind sequence -> then the kind under test -> expected state.
    let seeds: [(String, [EventKind], SessionState)] = [
        ("idle",    [.start],                    .idle),
        ("working", [.start, .prompt],           .working),
        ("needs",   [.start, .needsInput],       .needsYou),
        ("ended",   [.start, .end],              .ended),
    ]
    let expectations: [SessionState: [EventKind: SessionState]] = [
        .idle:     [.start: .idle, .prompt: .working, .tool: .working, .needsInput: .needsYou, .done: .idle, .end: .ended],
        .working:  [.start: .working, .prompt: .working, .tool: .working, .needsInput: .needsYou, .done: .working, .end: .ended],
        .needsYou: [.start: .needsYou, .prompt: .working, .tool: .working, .needsInput: .needsYou, .done: .needsYou, .end: .ended],
        .ended:    [.start: .ended, .prompt: .working, .tool: .working, .needsInput: .needsYou, .done: .ended, .end: .ended],
    ]
    // NOTE: `done` shows the PREVIOUS state here because it is provisional
    // until the grace window elapses — committed behaviour is covered in Task 5.
    for (label, seed, seededState) in seeds {
        for kind in [EventKind.start, .prompt, .tool, .needsInput, .done, .end] {
            let clock = FakeClock(); let store = newStore(clock)
            var ts = clock.nowMs
            for k in seed { store.apply(makeEvent(k, ts: ts)); ts += 1 }
            store.apply(makeEvent(kind, ts: ts))
            let got = store.stateForTesting(sid: "s1")
            let want = expectations[seededState]![kind]!
            #expect(got == want, "\(label) + \(kind.rawValue) => \(String(describing: got)), want \(want)")
        }
    }
}
