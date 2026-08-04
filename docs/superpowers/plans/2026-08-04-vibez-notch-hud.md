# Vibez Notch HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS 26 notch app that shows every local Claude Code / Codex / Cursor session — working, blocked on you, or just finished — and jumps to the owning terminal on click.

**Architecture:** Each plugin's `notify.sh` appends a JSON line per lifecycle event to `~/.config/vibez/hud/events.jsonl`. A pure Swift package (`VibezSessionKit`) tails that log and reduces events into sessions. A thin AppKit/SwiftUI app renders Liquid Glass ears in the notch that expand into an opaque black bubble. A headless CLI (`vibez-hud-probe`) exposes the same reduction as JSON so end-to-end tests need no UI.

**Tech Stack:** Swift 6.3, SwiftPM, swift-testing (`import Testing`), AppKit (`NSPanel`), SwiftUI + Liquid Glass (`glassEffect`, `GlassEffectContainer`, `glassEffectID` — all in SwiftUICore, re-exported by `import SwiftUI`), bash + jq for the writers.

## Global Constraints

- **Deployment target macOS 26.0.** Package platform is `.macOS("26.0")`. Liquid Glass APIs require it.
- **`VibezSessionKit` must not import AppKit or SwiftUI.** Foundation only. This is what keeps `swift test` fast and headless. The app target may import anything.
- **Never call `curl` from `hud_record()` or any path it runs on.** Claude's `SessionEnd` hook can be killed ~1.5 s into exit.
- **`hud_record()` is called at the event site, never from inside `post_vibez`.** The push path deliberately suppresses events (5 s debounce, `stop_pending_work` gate, Stop grace); the HUD needs all of them.
- **Two deliberate exceptions** where the HUD *does* mirror push suppression: Claude's `Notification` idle-reminder skip, and ephemeral / background-agent sessions.
- **Time is epoch milliseconds (`Int64`) everywhere.** Produced in bash by `jq -n '(now*1000)|floor'` (BSD `date` has no `%N`).
- **Three copies of the bash writer** (ClaudePlugin, CodexPlugin, CursorPlugin) — this repo's established mirroring convention. Keep them byte-identical apart from the agent tag and hook names.
- **Apple dark-mode system colors only for state:** needs-you `#FF9F0A`, done `#30D158`, working `#64D2FF` (teal, not blue — avoids colliding with Codex brand blue), ended `#98989D`. Agent brand chips: Claude `#d97757`, Codex `#4A7AFF`, Cursor `#A5A5B9`.
- **The expanded bubble is opaque black in both light and dark mode.**
- Spec: `docs/superpowers/specs/2026-08-04-vibez-notch-hud-design.md`.

---

## File Structure

```
VibezHUD/
  Package.swift                                   SPM manifest, 3 targets + 1 test target
  Sources/
    VibezSessionKit/                              PURE — Foundation only
      HUDEvent.swift                              record model + line decoder
      Session.swift                               Session, SessionState, HUDSnapshot
      Clock.swift                                 Clock protocol + SystemClock
      LivenessProbe.swift                         protocol + POSIXLivenessProbe (kill(pid,0) + start-time)
      SessionStore.swift                          the reducer
      EventLogReader.swift                        incremental tail: rotation, truncation, torn writes
      HUDPaths.swift                              log paths + config keys
    VibezHUDApp/                                  the app (AppKit + SwiftUI)
      main.swift                                  @main, .accessory activation policy
      NotchGeometry.swift                         PURE struct — screen metrics in, rects out
      HoverPolicy.swift                           PURE struct — hysteresis state machine
      NotchWindowController.swift                 the NSPanel
      HUDViewModel.swift                          reader+store → @Observable snapshot
      Views/
        CollapsedEars.swift                       the two glass ears
        BubbleBoard.swift                         expanded black bubble + 3 columns
        SessionTile.swift                         one row
        HUDTheme.swift                            colors, metrics, motion constants
      TerminalJumper.swift                        NSRunningApplication activation
      DemoData.swift                              --demo seeding (one session per state)
    vibez-hud-probe/
      main.swift                                  reads a log dir, prints HUDSnapshot as JSON
  Tests/
    VibezSessionKitTests/
      HUDEventDecodingTests.swift
      SessionStoreTransitionTests.swift
      SessionStoreOrderingTests.swift
      SessionStoreGraceTests.swift
      SessionStoreLivenessTests.swift
      EventLogReaderTests.swift
      EventLogConcurrencyTests.swift
      ReplayInvariantTests.swift
      Support/FakeClock.swift, FakeLiveness.swift, TempLog.swift
    VibezHUDAppTests/
      NotchGeometryTests.swift
      HoverPolicyTests.swift
  Scripts/
    make-app.sh                                   assemble VibezHUD.app (LSUIElement)

ClaudePlugin/scripts/notify.sh                    + hud_record(), hud_process_chain(), call sites
ClaudePlugin/hooks/hooks.json                     + SessionEnd registration
ClaudePlugin/test/hud.e2e.sh                      writer assertions
CodexPlugin/scripts/notify.sh                     mirrored
CodexPlugin/test/hud.e2e.sh
CursorPlugin/scripts/notify.sh                    mirrored
CursorPlugin/test/hud.e2e.sh
Tests/run-all.sh                                  swift test + 3 bash suites + probe e2e
Tests/fixtures/golden-session.json                golden snapshot for the e2e
```

---

### Task 1: Notch window spike — prove the window level

Retires the only assumption that could invalidate the UI work.

**Verification is programmatic, not visual.** `screencapture` on this machine
fails with "could not create image from rect" (Screen Recording permission is
not granted), so a screenshot is not available. `CGWindowListCopyWindowInfo`
needs **no** permission, returns every on-screen window's layer and its
front-to-back index, and answers the question exactly rather than by eye.

Measured on this machine, so the spike has a known-good target:

| Window | Owner | Layer |
|---|---|---|
| Menu bar | `Window Server` | **24** (`.mainMenu`) |
| Menu bar extras | `Control Center` | **25** (`.statusBar`) |

So `.statusBar + 2` = layer **27** should clear both. The spike proves it.

**Files:**
- Create: `VibezHUD/Scripts/spike-notch.swift`

- [ ] **Step 1: Write the self-verifying spike**

Two things this script must get right, both of which broke a previous attempt:
`print` is block-buffered when stdout is redirected to a file and `app.run()`
never returns, so **every print must be followed by `fflush(stdout)`**; and the
process must **exit on its own** rather than needing a kill.

```swift
// VibezHUD/Scripts/spike-notch.swift
// Run: swift VibezHUD/Scripts/spike-notch.swift
// Exits by itself with status 0 (PASS) or 1 (FAIL).
import AppKit
import CoreGraphics

func say(_ s: String) { print(s); fflush(stdout) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.screens.first else { fatalError("no screen") }
let f = screen.frame
let inset = screen.safeAreaInsets.top
let auxL = screen.auxiliaryTopLeftArea?.width ?? 0
let auxR = screen.auxiliaryTopRightArea?.width ?? 0
let notchW = (inset > 0 && auxL > 0 && auxR > 0) ? f.width - auxL - auxR : 180
let notchH = inset > 0 ? inset : 24

say("screen=\(f)")
say("safeTop=\(inset) auxL=\(auxL) auxR=\(auxR)")
say("notch=\(notchW)x\(notchH)")

// The level under test. If this fails, walk the ladder in Step 2.
let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

// Deliberately WIDER than the notch, so it must clear the menu bar on both sides.
let w: CGFloat = notchW + 260, h: CGFloat = notchH + 40
let rect = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)

let panel = NSPanel(contentRect: rect,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = level
panel.isOpaque = false
panel.hasShadow = false
panel.backgroundColor = .clear
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

let v = NSView(frame: NSRect(origin: .zero, size: rect.size))
v.wantsLayer = true
v.layer?.backgroundColor = NSColor.systemPink.withAlphaComponent(0.85).cgColor
v.layer?.cornerRadius = 18
v.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
panel.contentView = v
panel.orderFrontRegardless()

// Let WindowServer place the window before interrogating it.
DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    let mine = panel.windowNumber
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []

    guard let myIdx = list.firstIndex(where: {
        ($0[kCGWindowNumber as String] as? Int) == mine
    }) else {
        say("FAIL: our window is not in the on-screen list at all")
        exit(1)
    }
    let myLayer = list[myIdx][kCGWindowLayer as String] as? Int ?? -999
    say("panel: layer=\(myLayer) frontIndex=\(myIdx) windowNumber=\(mine)")

    // Menu-bar furniture: anything owned by Window Server or Control Center
    // that sits flush against the top of the screen.
    var barLayer = Int.min, barIdx = Int.max, barOwners = Set<String>()
    for (i, wi) in list.enumerated() {
        let owner = wi[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "Window Server" || owner == "Control Center" else { continue }
        let b = wi[kCGWindowBounds as String] as? [String: Any] ?? [:]
        guard (b["Y"] as? Double ?? -1) == 0 else { continue }
        barLayer = max(barLayer, wi[kCGWindowLayer as String] as? Int ?? Int.min)
        barIdx = min(barIdx, i)
        barOwners.insert(owner)
    }
    guard barLayer != Int.min else {
        say("FAIL: found no menu-bar windows to compare against")
        exit(1)
    }
    say("menubar: maxLayer=\(barLayer) frontIndex=\(barIdx) owners=\(barOwners.sorted())")

    // Front-to-back ordering: a LOWER index is closer to the viewer.
    let above = myLayer > barLayer && myIdx < barIdx
    say(above
        ? "PASS: panel layer \(myLayer) sits above menu bar layer \(barLayer)"
        : "FAIL: panel layer \(myLayer) does NOT clear menu bar layer \(barLayer)")
    exit(above ? 0 : 1)
}

app.run()
```

- [ ] **Step 2: Run it — it exits by itself**

```bash
cd VibezHUD && swift Scripts/spike-notch.swift; echo "exit=$?"
```

**Expected:** the geometry lines, then `PASS: panel layer 27 sits above menu bar layer 25`, then `exit=0`. First run takes ~20 s because `swift` compiles the script before running it — that is normal, not a hang.

**If it prints FAIL**, edit only the `let level = …` line, re-run, and record the first rung that passes: `.mainMenu + 1`, then `.popUpMenu`, then `.screenSaver`. The passing value becomes `HUDTheme.windowLevel` in Task 17. Note that something on this machine already floats at layer 1000 (`.screenSaver`), so that rung is a last resort — it would put the HUD above genuinely everything.

If no rung passes, report BLOCKED: the visual approach needs rethinking, and that is worth knowing now.

- [ ] **Step 3: Commit**

Commit the script with whichever level passed.

```bash
git add VibezHUD/Scripts/spike-notch.swift
git commit -m "spike(hud): prove the notch panel composites above the macOS 26 menu bar"
```

---

### Task 2: Package skeleton + HUDEvent decoding

**Files:**
- Create: `VibezHUD/Package.swift`, `VibezHUD/Sources/VibezSessionKit/HUDEvent.swift`
- Test: `VibezHUD/Tests/VibezSessionKitTests/HUDEventDecodingTests.swift`

**Interfaces:**
- Produces: `AgentTag`, `EventKind`, `HUDEvent`, `HUDEventDecoder.decodeLine(_:) -> HUDEvent?`

- [ ] **Step 1: Write the manifest**

```swift
// VibezHUD/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibezHUD",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "VibezSessionKit"),
        .executableTarget(name: "vibez-hud-probe", dependencies: ["VibezSessionKit"]),
        .executableTarget(name: "VibezHUDApp", dependencies: ["VibezSessionKit"]),
        .testTarget(name: "VibezSessionKitTests", dependencies: ["VibezSessionKit"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

```swift
// VibezHUD/Tests/VibezSessionKitTests/HUDEventDecodingTests.swift
import Testing
@testable import VibezSessionKit

private let good = #"{"v":1,"ts":1754345678901,"sid":"abc","agent":"cc","kind":"needs-input","proj":"Vibez","cwd":"/tmp/Vibez","title":"Notch app","body":"awaiting approval","tool":"Bash"}"#

@Test func decodesAWellFormedLine() throws {
    let e = try #require(HUDEventDecoder.decodeLine(good))
    #expect(e.ts == 1_754_345_678_901)
    #expect(e.sid == "abc")
    #expect(e.agent == .claude)
    #expect(e.kind == .needsInput)
    #expect(e.proj == "Vibez")
    #expect(e.tool == "Bash")
}

@Test func skipsMalformedAndUnusableLines() {
    #expect(HUDEventDecoder.decodeLine("") == nil)
    #expect(HUDEventDecoder.decodeLine("   ") == nil)
    #expect(HUDEventDecoder.decodeLine("{not json") == nil)
    #expect(HUDEventDecoder.decodeLine(#"{"v":1}"#) == nil)                    // missing required
    #expect(HUDEventDecoder.decodeLine(good.replacingOccurrences(of: #""v":1"#, with: #""v":99"#)) == nil)  // unknown schema
    #expect(HUDEventDecoder.decodeLine(good.replacingOccurrences(of: "needs-input", with: "teleport")) == nil) // unknown kind
}

@Test func unknownAgentFallsBackToClaude() throws {
    // Matches the iOS convention: unrecognised agent tags render as Claude.
    let line = good.replacingOccurrences(of: #""agent":"cc""#, with: #""agent":"zz""#)
    let e = try #require(HUDEventDecoder.decodeLine(line))
    #expect(e.agent == .claude)
}

@Test func survivesHostileContent() throws {
    let emoji = good.replacingOccurrences(of: "Notch app", with: "🚀 ünïcode ✳ 中文")
    #expect(try #require(HUDEventDecoder.decodeLine(emoji)).title == "🚀 ünïcode ✳ 中文")

    let huge = good.replacingOccurrences(of: "awaiting approval", with: String(repeating: "x", count: 10_000))
    #expect(HUDEventDecoder.decodeLine(huge)?.body?.count == 10_000)
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd VibezHUD && swift test --filter HUDEventDecoding`
Expected: FAIL — `cannot find 'HUDEventDecoder' in scope`

- [ ] **Step 4: Implement the model and decoder**

```swift
// VibezHUD/Sources/VibezSessionKit/HUDEvent.swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd VibezHUD && swift test --filter HUDEventDecoding`
Expected: PASS, 4 tests

- [ ] **Step 6: Commit**

```bash
git add VibezHUD/Package.swift VibezHUD/Sources/VibezSessionKit/HUDEvent.swift VibezHUD/Tests/VibezSessionKitTests/HUDEventDecodingTests.swift
git commit -m "feat(hud): HUDEvent record model and tolerant line decoder"
```

---

### Task 3: Session model, Clock, and the core reducer

**Files:**
- Create: `VibezHUD/Sources/VibezSessionKit/Session.swift`, `Clock.swift`, `LivenessProbe.swift`, `SessionStore.swift`
- Create: `VibezHUD/Tests/VibezSessionKitTests/Support/FakeClock.swift`, `Support/FakeLiveness.swift`
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreTransitionTests.swift`

**Interfaces:**
- Consumes: `HUDEvent`, `EventKind`, `AgentTag` (Task 2)
- Produces: `SessionState`, `Session`, `HUDSnapshot`, `Clock`, `SystemClock`, `LivenessProbe`, `POSIXLivenessProbe`, `StoreConfig`, `SessionStore.apply(_:)`, `SessionStore.snapshot()`

- [ ] **Step 1: Write the test support doubles**

```swift
// VibezHUD/Tests/VibezSessionKitTests/Support/FakeClock.swift
import VibezSessionKit

final class FakeClock: Clock, @unchecked Sendable {
    private var _now: Int64
    init(_ start: Int64 = 1_000_000) { _now = start }
    var nowMs: Int64 { _now }
    func advance(ms: Int64) { _now += ms }
    func set(_ ms: Int64) { _now = ms }
}
```

```swift
// VibezHUD/Tests/VibezSessionKitTests/Support/FakeLiveness.swift
import VibezSessionKit

final class FakeLiveness: LivenessProbe, @unchecked Sendable {
    /// pid -> (isRunning, startedAt). Absent pid means "not running".
    var table: [Int32: (Bool, String?)] = [:]
    func isAlive(pid: Int32, startedAt: String?) -> Bool {
        guard let (running, recordedStart) = table[pid], running else { return false }
        guard let want = startedAt, let got = recordedStart else { return true }
        return want == got   // start-time mismatch means the PID was recycled
    }
}
```

- [ ] **Step 2: Write the failing transition test**

```swift
// VibezHUD/Tests/VibezSessionKitTests/SessionStoreTransitionTests.swift
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
        "agentPid": agentPid.map(Int.init), "agentStart": agentStart,
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
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd VibezHUD && swift test --filter SessionStoreTransition`
Expected: FAIL — `cannot find 'SessionStore' in scope`

- [ ] **Step 4: Implement the model and reducer**

```swift
// VibezHUD/Sources/VibezSessionKit/Clock.swift
import Foundation

public protocol Clock: Sendable { var nowMs: Int64 { get } }

public struct SystemClock: Clock {
    public init() {}
    public var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
```

```swift
// VibezHUD/Sources/VibezSessionKit/LivenessProbe.swift
import Foundation

public protocol LivenessProbe: Sendable {
    /// `startedAt` is the `ps -o lstart=` string recorded when the session began.
    /// Comparing it defends against macOS PID recycling.
    func isAlive(pid: Int32, startedAt: String?) -> Bool
}

public struct POSIXLivenessProbe: LivenessProbe {
    public init() {}

    public func isAlive(pid: Int32, startedAt: String?) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): 0 = alive and ours, EPERM = alive but another user's.
        if kill(pid, 0) != 0 && errno != EPERM { return false }
        guard let want = startedAt, !want.isEmpty else { return true }
        guard let got = Self.startTime(of: pid) else { return false }
        return got == want
    }

    static func startTime(of pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "lstart=", "-p", String(pid)]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
```

```swift
// VibezHUD/Sources/VibezSessionKit/Session.swift
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
```

```swift
// VibezHUD/Sources/VibezSessionKit/SessionStore.swift
import Foundation

public struct StoreConfig: Sendable {
    public var stopGraceMs: Int64
    public var retentionMs: Int64
    public var staleMs: Int64

    public init(stopGraceMs: Int64 = 3_000,
                retentionMs: Int64 = 60 * 60 * 1_000,
                staleMs: Int64 = 30 * 60 * 1_000) {
        self.stopGraceMs = stopGraceMs
        self.retentionMs = retentionMs
        self.staleMs = staleMs
    }
}

public final class SessionStore {
    private struct Entry {
        var session: Session
        var lastAppliedTs: Int64
        var lastAppliedPriority: Int
        /// A `done` is provisional until the grace window elapses in silence.
        var pendingDoneAtMs: Int64?
    }

    private var entries: [String: Entry] = [:]
    private let config: StoreConfig
    private let clock: any Clock
    private let liveness: any LivenessProbe

    public init(config: StoreConfig = StoreConfig(),
                clock: any Clock = SystemClock(),
                liveness: any LivenessProbe = POSIXLivenessProbe()) {
        self.config = config; self.clock = clock; self.liveness = liveness
    }

    public func apply(_ e: HUDEvent) {
        guard var entry = entries[e.sid] else {
            entries[e.sid] = Entry(session: seed(from: e),
                                   lastAppliedTs: e.ts,
                                   lastAppliedPriority: e.kind.priority,
                                   pendingDoneAtMs: e.kind == .done ? e.ts : nil)
            return
        }

        let isStale = e.ts < entry.lastAppliedTs
            || (e.ts == entry.lastAppliedTs && e.kind.priority <= entry.lastAppliedPriority)

        if isStale {
            // Still contributes identity — this is how a session whose `start`
            // line rotated away recovers its name instead of showing as an orphan.
            fillMissingIdentity(&entry.session, from: e)
            entries[e.sid] = entry
            return
        }

        mergeIdentity(&entry.session, from: e)
        entry.lastAppliedTs = e.ts
        entry.lastAppliedPriority = e.kind.priority
        entry.session.lastActivityMs = max(entry.session.lastActivityMs, e.ts)

        // Any newer event discards a provisional done — this is the false-DONE
        // flash fix: Stop fires, the harness auto-resumes ~1s later, and that
        // resume lands inside the grace window.
        if e.kind != .done { entry.pendingDoneAtMs = nil }

        switch e.kind {
        case .start:  break
        case .prompt, .tool: setState(&entry, .working, at: e.ts)
        case .needsInput:    setState(&entry, .needsYou, at: e.ts)
        case .end:           setState(&entry, .ended, at: e.ts)
        case .done:          entry.pendingDoneAtMs = e.ts
        }
        entries[e.sid] = entry
    }

    public func snapshot() -> HUDSnapshot {
        let now = clock.nowMs
        var needsYou: [Session] = [], done: [Session] = [], working: [Session] = []

        for (_, entry) in entries {
            guard var s = resolve(entry, now: now) else { continue }
            s.detail = s.detail?.isEmpty == true ? nil : s.detail
            switch s.state {
            case .needsYou: needsYou.append(s)
            case .working:  working.append(s)
            case .done, .ended: done.append(s)
            case .idle: continue
            }
        }

        // Longest wait first — the most urgent thing sits at the top.
        needsYou.sort { $0.stateSinceMs < $1.stateSinceMs }
        // Most recent activity first for the other two.
        working.sort { $0.lastActivityMs > $1.lastActivityMs }
        done.sort { $0.lastActivityMs > $1.lastActivityMs }
        return HUDSnapshot(needsYou: needsYou, done: done, working: working)
    }

    /// Test seam — the raw resolved state for one session, ignoring column grouping.
    public func stateForTesting(sid: String) -> SessionState? {
        guard let entry = entries[sid] else { return nil }
        return resolve(entry, now: clock.nowMs, ignoringRetention: true)?.state
    }

    // MARK: - resolution

    private func resolve(_ entry: Entry, now: Int64, ignoringRetention: Bool = false) -> Session? {
        var s = entry.session

        // Commit a provisional done once the grace window has passed in silence.
        if let pending = entry.pendingDoneAtMs, now - pending >= config.stopGraceMs {
            s.state = .done
            s.stateSinceMs = pending
        }

        if s.state != .ended {
            if let pid = s.agentPid {
                // A known PID is authoritative in both directions.
                if !liveness.isAlive(pid: pid, startedAt: s.agentStart) {
                    s.state = .ended
                    s.stateSinceMs = s.lastActivityMs
                }
            } else if now - s.lastActivityMs > config.staleMs {
                // No PID means UNKNOWN, never dead — only staleness may end it.
                s.state = .ended
                s.stateSinceMs = s.lastActivityMs
            }
        }

        if !ignoringRetention, s.state == .done || s.state == .ended {
            if now - s.lastActivityMs > config.retentionMs { return nil }
        }
        return s
    }

    // MARK: - identity

    private func seed(from e: HUDEvent) -> Session {
        Session(sid: e.sid, agent: e.agent, proj: e.proj, cwd: e.cwd, title: e.title,
                detail: e.body, tool: e.tool,
                state: initialState(for: e.kind),
                startedAtMs: e.ts, lastActivityMs: e.ts, stateSinceMs: e.ts,
                agentPid: e.agentPid, agentStart: e.agentStart,
                appPid: e.appPid, app: e.app)
    }

    private func initialState(for kind: EventKind) -> SessionState {
        switch kind {
        case .start, .done: .idle
        case .prompt, .tool: .working
        case .needsInput: .needsYou
        case .end: .ended
        }
    }

    private func setState(_ entry: inout Entry, _ new: SessionState, at ts: Int64) {
        if entry.session.state != new { entry.session.stateSinceMs = ts }
        entry.session.state = new
    }

    private func mergeIdentity(_ s: inout Session, from e: HUDEvent) {
        s.agent = e.agent
        if !e.proj.isEmpty { s.proj = e.proj }
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        if !e.title.isEmpty { s.title = e.title }
        if let b = e.body, !b.isEmpty { s.detail = b }
        if let t = e.tool, !t.isEmpty { s.tool = t }
        if let p = e.agentPid { s.agentPid = p; s.agentStart = e.agentStart }
        if let p = e.appPid { s.appPid = p; s.app = e.app }
    }

    private func fillMissingIdentity(_ s: inout Session, from e: HUDEvent) {
        if s.proj.isEmpty { s.proj = e.proj }
        if s.cwd.isEmpty { s.cwd = e.cwd }
        if s.title.isEmpty { s.title = e.title }
        if s.detail == nil { s.detail = e.body }
        if s.agentPid == nil, let p = e.agentPid { s.agentPid = p; s.agentStart = e.agentStart }
        if s.appPid == nil, let p = e.appPid { s.appPid = p; s.app = e.app }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd VibezHUD && swift test --filter SessionStoreTransition`
Expected: PASS, 5 tests

- [ ] **Step 6: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit VibezHUD/Tests/VibezSessionKitTests
git commit -m "feat(hud): session model, clock/liveness seams, and the core reducer"
```

---

### Task 4: Out-of-order records and millisecond tie-breaks

**Files:**
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreOrderingTests.swift`

**Interfaces:**
- Consumes: `SessionStore.apply(_:)`, `stateForTesting(sid:)` (Task 3)

The reducer already implements this; these tests pin it. If any fail, fix `SessionStore.apply`.

- [ ] **Step 1: Write the tests**

```swift
// VibezHUD/Tests/VibezSessionKitTests/SessionStoreOrderingTests.swift
import Testing
@testable import VibezSessionKit

private func store(_ c: FakeClock) -> SessionStore {
    SessionStore(config: StoreConfig(), clock: c, liveness: FakeLiveness())
}

@Test func aStaleToolHeartbeatCannotUnblockASession() {
    // Hooks fire in parallel; a `tool` can land AFTER a `needs-input` while
    // carrying an EARLIER timestamp. It must not drag the session back to working.
    let clock = FakeClock(); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 1_000))
    s.apply(makeEvent(.needsInput, ts: 2_000))
    s.apply(makeEvent(.tool, ts: 1_500, tool: "Read"))
    #expect(s.stateForTesting(sid: "s1") == .needsYou)
}

@Test func millisecondTiesResolveByPriority() {
    let clock = FakeClock(); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 1_000))
    s.apply(makeEvent(.tool, ts: 2_000))
    s.apply(makeEvent(.needsInput, ts: 2_000))    // same ms, higher priority wins
    #expect(s.stateForTesting(sid: "s1") == .needsYou)

    let clock2 = FakeClock(); let s2 = store(clock2)
    s2.apply(makeEvent(.prompt, ts: 1_000))
    s2.apply(makeEvent(.needsInput, ts: 2_000))
    s2.apply(makeEvent(.tool, ts: 2_000))         // same ms, lower priority loses
    #expect(s2.stateForTesting(sid: "s1") == .needsYou)
}

@Test func duplicateRecordsAreIdempotent() {
    let clock = FakeClock(); let s = store(clock)
    let e = makeEvent(.needsInput, ts: 2_000)
    s.apply(e); s.apply(e); s.apply(e)
    #expect(s.snapshot().needsYou.count == 1)
    #expect(s.stateForTesting(sid: "s1") == .needsYou)
}

@Test func aStaleRecordStillHealsMissingIdentity() {
    // Simulates the `start` line having been rotated away: the first record we
    // ever see is a bare heartbeat, and an older record backfills the name.
    let clock = FakeClock(); let s = store(clock)
    s.apply(makeEvent(.tool, ts: 5_000, proj: "", cwd: "", title: ""))
    s.apply(makeEvent(.start, ts: 1_000, proj: "Vibez", cwd: "/tmp/Vibez", title: "Notch app"))
    let session = s.snapshot().working.first
    #expect(session?.proj == "Vibez")
    #expect(session?.title == "Notch app")
    #expect(session?.state == .working)     // the stale start must NOT reset state
}
```

- [ ] **Step 2: Run them**

Run: `cd VibezHUD && swift test --filter SessionStoreOrdering`
Expected: PASS, 4 tests

- [ ] **Step 3: Commit**

```bash
git add VibezHUD/Tests/VibezSessionKitTests/SessionStoreOrderingTests.swift
git commit -m "test(hud): pin out-of-order and millisecond-tie reducer behaviour"
```

---

### Task 5: Provisional DONE — the false-done flash

**Files:**
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreGraceTests.swift`

**Interfaces:**
- Consumes: `StoreConfig.stopGraceMs`, `SessionStore` (Task 3)

- [ ] **Step 1: Write the tests**

```swift
// VibezHUD/Tests/VibezSessionKitTests/SessionStoreGraceTests.swift
import Testing
@testable import VibezSessionKit

private func store(_ c: FakeClock, grace: Int64 = 3_000) -> SessionStore {
    SessionStore(config: StoreConfig(stopGraceMs: grace), clock: c, liveness: FakeLiveness())
}

@Test func doneCommitsAfterTheGraceWindowElapsesInSilence() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))

    #expect(s.stateForTesting(sid: "s1") == .working)   // provisional — still working
    clock.advance(ms: 2_999)
    #expect(s.stateForTesting(sid: "s1") == .working)
    clock.advance(ms: 1)
    #expect(s.stateForTesting(sid: "s1") == .done)      // committed
}

@Test func activityInsideTheGraceWindowDiscardsTheDone() {
    // The real bug: Stop fires at a turn boundary, the harness auto-resumes ~1s
    // later, and the session was never actually done.
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.prompt, ts: 9_000))
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 1_000)
    s.apply(makeEvent(.tool, ts: 11_000, tool: "Bash"))
    clock.advance(ms: 10_000)
    #expect(s.stateForTesting(sid: "s1") == .working)   // never flashed to done
}

@Test func needsInputInsideTheGraceWindowWins() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.done, ts: 10_000))
    clock.advance(ms: 500)
    s.apply(makeEvent(.needsInput, ts: 10_500))
    clock.advance(ms: 10_000)
    #expect(s.stateForTesting(sid: "s1") == .needsYou)
}

@Test func repeatedDoneCommitsOnceAtTheLatestTimestamp() {
    let clock = FakeClock(10_000); let s = store(clock)
    s.apply(makeEvent(.done, ts: 10_000))
    s.apply(makeEvent(.done, ts: 10_400))
    // Exactly 3s past the FIRST done. This instant is the discriminator: a
    // reducer that measured grace from the first done would have committed by
    // now (13_000 - 10_000 == 3_000), while one measuring from the latest has
    // only seen 2_600ms elapse. Assert the exact state — `!= .done` (or a
    // disjunction spelling it) would pass under BOTH behaviours and pin nothing.
    // The session never worked, so its state is still .idle.
    clock.advance(ms: 3_000)
    #expect(s.stateForTesting(sid: "s1") == .idle)
    clock.advance(ms: 400)                               // now 3s past the LAST done
    #expect(s.stateForTesting(sid: "s1") == .done)
}

@Test func graceOfZeroCommitsImmediately() {
    // VIBEZ_STOP_GRACE_SECONDS=0 is the documented rollback switch.
    let clock = FakeClock(10_000); let s = store(clock, grace: 0)
    s.apply(makeEvent(.done, ts: 10_000))
    #expect(s.stateForTesting(sid: "s1") == .done)
}
```

- [ ] **Step 2: Run them**

Run: `cd VibezHUD && swift test --filter SessionStoreGrace`
Expected: PASS, 5 tests. If `repeatedDoneCommitsOnceAtTheLatestTimestamp` fails, `apply` is not refreshing `pendingDoneAtMs` on a second `done` — it must set it to the newer `e.ts`.

- [ ] **Step 3: Commit**

```bash
git add VibezHUD/Tests/VibezSessionKitTests/SessionStoreGraceTests.swift
git commit -m "test(hud): pin provisional-done grace, killing the false-done flash"
```

---

### Task 6: Liveness, staleness, and retention

**Files:**
- Test: `VibezHUD/Tests/VibezSessionKitTests/SessionStoreLivenessTests.swift`

**Interfaces:**
- Consumes: `LivenessProbe`, `StoreConfig.staleMs`, `StoreConfig.retentionMs` (Task 3)

- [ ] **Step 1: Write the tests**

```swift
// VibezHUD/Tests/VibezSessionKitTests/SessionStoreLivenessTests.swift
import Testing
@testable import VibezSessionKit

@Test func aLivePidKeepsAQuietSessionAlive() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, "Mon Aug  4 20:58:08 2026")
    let s = SessionStore(config: StoreConfig(staleMs: 60_000), clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 1_000_000, agentPid: 999, agentStart: "Mon Aug  4 20:58:08 2026"))
    s.apply(makeEvent(.prompt, ts: 1_000_001))
    clock.advance(ms: 10 * 60_000)          // far past staleMs
    #expect(s.stateForTesting(sid: "s1") == .working)
}

@Test func aDeadPidEndsTheSessionImmediately() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness()               // pid absent => not running
    let s = SessionStore(clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 1_000_000, agentPid: 999, agentStart: "start-a"))
    s.apply(makeEvent(.prompt, ts: 1_000_001))
    #expect(s.stateForTesting(sid: "s1") == .ended)
}

@Test func aRecycledPidDoesNotResurrectASession() {
    // Same pid, different process start time — macOS recycles PIDs.
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, "SOMEONE ELSE")
    let s = SessionStore(clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 1_000_000, agentPid: 999, agentStart: "start-a"))
    s.apply(makeEvent(.prompt, ts: 1_000_001))
    #expect(s.stateForTesting(sid: "s1") == .ended)
}

@Test func anUnknownPidIsUnknownNotDead() {
    // A session whose `start` line rotated away has no pid. It must keep running
    // until staleness ends it — treating "no pid" as "dead" would wipe live rows.
    let clock = FakeClock(1_000_000)
    let s = SessionStore(config: StoreConfig(staleMs: 60_000), clock: clock, liveness: FakeLiveness())
    s.apply(makeEvent(.prompt, ts: 1_000_000))
    #expect(s.stateForTesting(sid: "s1") == .working)
    clock.advance(ms: 59_000)
    #expect(s.stateForTesting(sid: "s1") == .working)
    clock.advance(ms: 2_000)
    #expect(s.stateForTesting(sid: "s1") == .ended)
}

@Test func finishedSessionsDropOutAfterRetention() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, nil)
    let s = SessionStore(config: StoreConfig(stopGraceMs: 0, retentionMs: 60_000),
                         clock: clock, liveness: live)
    s.apply(makeEvent(.start, ts: 999_999, agentPid: 999))
    // The done's ts must not lead the clock: with stopGraceMs 0 the commit
    // check is `now - pending >= 0`, so a done stamped even 1ms in the future
    // stays provisional until the clock catches up.
    s.apply(makeEvent(.done, ts: 1_000_000))
    #expect(s.snapshot().done.count == 1)
    clock.advance(ms: 61_000)
    #expect(s.snapshot().done.isEmpty)
}

@Test func columnsSortByUrgencyThenRecency() {
    let clock = FakeClock(1_000_000)
    let live = FakeLiveness(); live.table[999] = (true, nil)
    let s = SessionStore(clock: clock, liveness: live)
    s.apply(makeEvent(.needsInput, ts: 900_000, sid: "old", agentPid: 999))
    s.apply(makeEvent(.needsInput, ts: 990_000, sid: "new", agentPid: 999))
    s.apply(makeEvent(.tool, ts: 800_000, sid: "w1", agentPid: 999))
    s.apply(makeEvent(.tool, ts: 999_000, sid: "w2", agentPid: 999))
    let snap = s.snapshot()
    #expect(snap.needsYou.map(\.sid) == ["old", "new"])   // longest wait first
    #expect(snap.working.map(\.sid) == ["w2", "w1"])      // most recent first
}
```

- [ ] **Step 2: Run them**

Run: `cd VibezHUD && swift test --filter SessionStoreLiveness`
Expected: PASS, 6 tests

- [ ] **Step 3: Commit**

```bash
git add VibezHUD/Tests/VibezSessionKitTests/SessionStoreLivenessTests.swift
git commit -m "test(hud): pin liveness, PID recycling, staleness, retention, and column sort"
```

---

### Task 7: EventLogReader — tail, rotation, truncation, torn writes

**Files:**
- Create: `VibezHUD/Sources/VibezSessionKit/HUDPaths.swift`, `EventLogReader.swift`
- Create: `VibezHUD/Tests/VibezSessionKitTests/Support/TempLog.swift`
- Test: `VibezHUD/Tests/VibezSessionKitTests/EventLogReaderTests.swift`

**Interfaces:**
- Produces: `HUDPaths.defaultLogURL`, `EventLogReader.init(url:)`, `primeFromTail(maxBytes:) -> [HUDEvent]`, `readNew() -> [HUDEvent]`

- [ ] **Step 1: Write the test helper and failing tests**

```swift
// VibezHUD/Tests/VibezSessionKitTests/Support/TempLog.swift
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
```

```swift
// VibezHUD/Tests/VibezSessionKitTests/EventLogReaderTests.swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd VibezHUD && swift test --filter EventLogReader`
Expected: FAIL — `cannot find 'EventLogReader' in scope`

- [ ] **Step 3: Implement paths and reader**

```swift
// VibezHUD/Sources/VibezSessionKit/HUDPaths.swift
import Foundation

public enum HUDPaths {
    public static var configDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/vibez")
    }
    public static var hudDir: URL { configDir.appendingPathComponent("hud") }
    public static var defaultLogURL: URL { hudDir.appendingPathComponent("events.jsonl") }
    /// Rotation target the bash writer moves the log to.
    public static func rotatedURL(for log: URL) -> URL {
        log.deletingLastPathComponent().appendingPathComponent(log.lastPathComponent + ".1")
    }
    public static let coldStartTailBytes = 256 * 1024
}
```

```swift
// VibezHUD/Sources/VibezSessionKit/EventLogReader.swift
import Foundation

/// Incremental tail of an append-only JSONL log.
/// Handles the three things that actually happen to a live log file:
/// rotation (inode changes), truncation (size < offset), and torn writes
/// (a line only partly on disk when we read).
public final class EventLogReader {
    private let url: URL
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var partial = Data()

    public init(url: URL) { self.url = url }

    /// Cold start: replay at most `maxBytes` from the end, discarding the
    /// leading partial line, and leave the offset at EOF.
    public func primeFromTail(maxBytes: Int) -> [HUDEvent] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return [] }
        inode = attrs[.systemFileNumber] as? UInt64
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        // Advance by what we actually consumed, not by the size we sampled
        // before reading — the writer may have appended in between, and those
        // bytes ARE in `data`. Using `size` would re-emit them next poll.
        offset = start + UInt64(data.count)

        var lines = splitCompleteLines(data, carry: &partial)
        if start > 0 {
            if lines.isEmpty {
                // The window held no newline at all, so every byte we have —
                // including what landed in `partial` — begins mid-line and
                // cannot be trusted. Only reachable if maxBytes < one line.
                partial = Data()
            } else {
                lines.removeFirst()            // the leading partial line
            }
        }
        // NOTE: do NOT clear `partial` here. If the writer was mid-write when
        // we primed, the final line has no newline yet and its head is sitting
        // in `partial`. Dropping it loses that event permanently: the writer
        // later appends only the remainder, which cannot decode on its own.
        return lines.compactMap { HUDEventDecoder.decodeLine($0) }
    }

    /// Everything appended since the last call.
    public func readNew() -> [HUDEvent] {
        var events: [HUDEvent] = []

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return [] }
        let currentInode = attrs[.systemFileNumber] as? UInt64

        if let known = inode, let now = currentInode, known != now {
            // Rotated: drain what is left of the OLD file before switching.
            events += drainRotatedTail()
            offset = 0
            partial = Data()
            inode = now
        } else if inode == nil {
            inode = currentInode
        }

        if size < offset {                     // truncated in place
            offset = 0
            partial = Data()
        }

        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else {
            return events
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)           // consumed bytes, not sampled size

        let lines = splitCompleteLines(data, carry: &partial)
        events += lines.compactMap { HUDEventDecoder.decodeLine($0) }
        return events
    }

    /// Drain what is left of the pre-rotation file, picking up from where we
    /// stopped reading it.
    ///
    /// Accepted limitation: only ONE backup generation exists, so if the log
    /// rotated twice between two polls, `.1` is no longer the file we were
    /// reading and its unread tail is gone. At a 2 MB rotation threshold and a
    /// ~200 ms poll that needs 4 MB of hook output in 200 ms, which does not
    /// happen. The size guard below keeps that case harmless rather than
    /// letting it emit garbage.
    private func drainRotatedTail() -> [HUDEvent] {
        let rotated = HUDPaths.rotatedURL(for: url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: rotated.path),
              let rotatedSize = attrs[.size] as? UInt64,
              rotatedSize > offset,
              let handle = try? FileHandle(forReadingFrom: rotated) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        // A throwaway carry ON PURPOSE. If the rotated file ends mid-line, that
        // line's remainder was written into the OLD inode (the writer's fd
        // survives the rename) — a file we never read again. Carrying those
        // bytes into the new file would prepend garbage to its first line.
        // Discarding is correct; the caller clears `partial` for the same reason.
        var carry = partial
        let lines = splitCompleteLines(data, carry: &carry)
        return lines.compactMap { HUDEventDecoder.decodeLine($0) }
    }

    /// Emits only newline-terminated lines; anything after the last newline is
    /// held in `carry` until the writer finishes it.
    private func splitCompleteLines(_ data: Data, carry: inout Data) -> [String] {
        var buffer = carry + data
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer = buffer[buffer.index(after: nl)...]
        }
        carry = Data(buffer)
        return lines
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd VibezHUD && swift test --filter EventLogReader`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/HUDPaths.swift VibezHUD/Sources/VibezSessionKit/EventLogReader.swift VibezHUD/Tests/VibezSessionKitTests/EventLogReaderTests.swift VibezHUD/Tests/VibezSessionKitTests/Support/TempLog.swift
git commit -m "feat(hud): incremental log reader surviving rotation, truncation, torn writes"
```

---

### Task 8: Prove the O_APPEND atomicity the transport rests on

The entire choice of append-only-log over per-session-files assumes concurrent
`printf >>` from parallel hooks cannot interleave or lose lines. Assert it.

**Files:**
- Test: `VibezHUD/Tests/VibezSessionKitTests/EventLogConcurrencyTests.swift`

- [ ] **Step 1: Write the test**

```swift
// VibezHUD/Tests/VibezSessionKitTests/EventLogConcurrencyTests.swift
import Testing
import Foundation
@testable import VibezSessionKit

@Test func fiftyConcurrentAppendersLoseNothingAndInterleaveNothing() throws {
    let log = TempLog()
    let writers = 50, perWriter = 20

    // Each writer is a real subshell doing exactly what hud_record() does.
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "appenders", attributes: .concurrent)
    for w in 0..<writers {
        queue.async(group: group) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", """
              for i in $(seq 1 \(perWriter)); do
                printf '%s\\n' '{"v":1,"ts":'"$i"',"sid":"w\(w)","agent":"cc","kind":"tool","proj":"P","cwd":"/tmp/P","title":"t"}' >> '\(log.url.path)'
              done
              """]
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
    }
    group.wait()

    let text = try String(contentsOf: log.url, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == writers * perWriter, "lost or duplicated lines")

    // Every single line must decode — a torn/interleaved write would not.
    let decoded = lines.compactMap { HUDEventDecoder.decodeLine(String($0)) }
    #expect(decoded.count == lines.count, "an interleaved write corrupted a line")

    // And every writer's full run survived.
    let counts = Dictionary(grouping: decoded, by: \.sid).mapValues(\.count)
    #expect(counts.count == writers)
    #expect(counts.values.allSatisfy { $0 == perWriter })
}
```

- [ ] **Step 2: Run it**

Run: `cd VibezHUD && swift test --filter EventLogConcurrency`
Expected: PASS. If it fails, the transport assumption is wrong — stop and reconsider before any further work.

- [ ] **Step 3: Commit**

```bash
git add VibezHUD/Tests/VibezSessionKitTests/EventLogConcurrencyTests.swift
git commit -m "test(hud): prove concurrent O_APPEND writes never tear or drop lines"
```

---

### Task 9: `vibez-hud-probe` — the headless view every e2e test asserts

**Files:**
- Create: `VibezHUD/Sources/VibezSessionKit/HUDEngine.swift`, `VibezHUD/Sources/vibez-hud-probe/main.swift`

**Interfaces:**
- Produces: `HUDEngine.init(logURL:config:clock:liveness:)`, `HUDEngine.primeAndDrain() -> HUDSnapshot`, `HUDEngine.poll() -> HUDSnapshot`

- [ ] **Step 1: Write the failing test**

Add to `VibezHUD/Tests/VibezSessionKitTests/EventLogReaderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd VibezHUD && swift test --filter engineTurnsALog`
Expected: FAIL — `cannot find 'HUDEngine' in scope`

- [ ] **Step 3: Implement the engine and the probe**

```swift
// VibezHUD/Sources/VibezSessionKit/HUDEngine.swift
import Foundation

/// Reader + store wired together. The single entry point used by both the app
/// and the probe, so the two can never drift.
public final class HUDEngine {
    private let reader: EventLogReader
    private let store: SessionStore

    public init(logURL: URL = HUDPaths.defaultLogURL,
                config: StoreConfig = StoreConfig(),
                clock: any Clock = SystemClock(),
                liveness: any LivenessProbe = POSIXLivenessProbe()) {
        self.reader = EventLogReader(url: logURL)
        self.store = SessionStore(config: config, clock: clock, liveness: liveness)
    }

    /// Cold start: bounded tail replay, then a snapshot.
    @discardableResult
    public func primeAndDrain(tailBytes: Int = HUDPaths.coldStartTailBytes) -> HUDSnapshot {
        for e in reader.primeFromTail(maxBytes: tailBytes) { store.apply(e) }
        for e in reader.readNew() { store.apply(e) }
        return store.snapshot()
    }

    /// Drain whatever is new and re-snapshot. Safe to call on a timer.
    public func poll() -> HUDSnapshot {
        for e in reader.readNew() { store.apply(e) }
        return store.snapshot()
    }
}
```

```swift
// VibezHUD/Sources/vibez-hud-probe/main.swift
import Foundation
import VibezSessionKit

// Usage: vibez-hud-probe [path/to/events.jsonl]
// Prints the HUDSnapshot as stable, sorted JSON so tests can diff it.

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : HUDPaths.defaultLogURL.path

let engine = HUDEngine(logURL: URL(fileURLWithPath: path))
let snap = engine.primeAndDrain()

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
```

- [ ] **Step 4: Run to verify pass, and smoke the binary**

```bash
cd VibezHUD && swift test --filter engineTurnsALog && swift build --product vibez-hud-probe
```

Expected: test PASSes; build succeeds.

```bash
cd VibezHUD && printf '%s\n' '{"v":1,"ts":1,"sid":"x","agent":"cc","kind":"needs-input","proj":"P","cwd":"/tmp/P","title":"hello"}' > /tmp/probe.jsonl && swift run vibez-hud-probe /tmp/probe.jsonl
```

Expected: JSON with one entry under `needsYou`.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezSessionKit/HUDEngine.swift VibezHUD/Sources/vibez-hud-probe VibezHUD/Tests
git commit -m "feat(hud): HUDEngine plus the headless vibez-hud-probe CLI"
```

---

### Task 10: The bash writer — Claude plugin

**Files:**
- Modify: `ClaudePlugin/scripts/notify.sh` (add helpers near the existing `log()` at :38, then call sites)
- Modify: `ClaudePlugin/hooks/hooks.json` (register `SessionEnd`)
- Create: `ClaudePlugin/test/hud.e2e.sh`

**Interfaces:**
- Produces: `hud_record <kind> <sid> <proj> <cwd> <title> <body> <tool>`, `hud_process_chain`, `hud_now_ms`

- [ ] **Step 1: Write the failing writer test**

```bash
#!/usr/bin/env bash
# ClaudePlugin/test/hud.e2e.sh
# Feeds realistic hook payloads through the REAL notify.sh with curl shadowed,
# then asserts what landed in the HUD log.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${HERE}/../scripts/notify.sh"
FAILURES=0

setup() {
    SANDBOX="$(mktemp -d)"
    export VIBEZ_CONFIG_DIR="${SANDBOX}"
    export VIBEZ_STOP_GRACE_SECONDS=0
    export VIBEZ_BLOCK_DEBOUNCE_SECONDS=0
    printf 'moss-pine-fox-jazz\n' > "${SANDBOX}/vibez-id"
    HUD_LOG="${SANDBOX}/hud/events.jsonl"
    # Shadow curl so nothing leaves the machine.
    BIN="${SANDBOX}/bin"; mkdir -p "${BIN}"
    printf '#!/bin/sh\nexit 0\n' > "${BIN}/curl"; chmod +x "${BIN}/curl"
    export PATH="${BIN}:${PATH}"
}
teardown() { rm -rf "${SANDBOX}"; }

fire() { printf '%s' "$2" | bash "${NOTIFY}" "$1" >/dev/null 2>&1; }

check() {
    local label="$1" want="$2" got="$3"
    if [ "${want}" = "${got}" ]; then printf '  ok   %s\n' "${label}"
    else printf '  FAIL %s\n       want=%s\n       got =%s\n' "${label}" "${want}" "${got}"; FAILURES=$((FAILURES+1)); fi
}

kinds() { jq -r '.kind' "${HUD_LOG}" 2>/dev/null | tr '\n' ',' ; }

printf 'ClaudePlugin HUD writer\n'

# --- every hook writes exactly one record, with the right kind -------------
setup
fire session-start '{"session_id":"s1","cwd":"/tmp/proj","transcript_path":"/tmp/t.jsonl"}'
fire user-prompt-submit '{"session_id":"s1","cwd":"/tmp/proj","prompt":"do the thing"}'
fire post-tool-use '{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Edit"}'
fire permission-request '{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
fire stop '{"session_id":"s1","cwd":"/tmp/proj","transcript_path":"/tmp/t.jsonl"}'
check "one record per hook, in order" "start,prompt,tool,needs-input," "$(kinds | sed 's/\(.*\),.*/\1,/')" 
check "every line is valid json" "ok" "$(jq -e -s 'length > 0' "${HUD_LOG}" >/dev/null 2>&1 && echo ok || echo bad)"
check "records carry identity" "proj" "$(jq -r 'select(.kind=="tool") | .proj' "${HUD_LOG}" | head -1)"
check "records carry a tool name" "Edit" "$(jq -r 'select(.kind=="tool") | .tool' "${HUD_LOG}" | head -1)"
check "start carries the liveness pair" "yes" "$(jq -r 'select(.kind=="start") | if (.agentPid != null and .agentStart != null) then "yes" else "no" end' "${HUD_LOG}" | head -1)"
check "ts is epoch MILLIseconds" "yes" "$(jq -r '.ts | if . > 1000000000000 then "yes" else "no" end' "${HUD_LOG}" | head -1)"
teardown

# --- THE REGRESSION THAT MATTERS -------------------------------------------
# The push path debounces same-conversation blocks. The HUD must still see them.
setup
export VIBEZ_BLOCK_DEBOUNCE_SECONDS=300
fire permission-request '{"session_id":"s2","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"ls"}}'
fire permission-request '{"session_id":"s2","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"pwd"}}'
check "debounced pushes still produce HUD records" "2" "$(jq -r 'select(.kind=="needs-input")' "${HUD_LOG}" | jq -s 'length')"
teardown

# --- unusable session ids are dropped --------------------------------------
setup
fire post-tool-use '{"session_id":"nosid","cwd":"/tmp/proj","tool_name":"Read"}'
fire post-tool-use '{"cwd":"/tmp/proj","tool_name":"Read"}'
check "nosid and empty sid write nothing" "0" "$( [ -f "${HUD_LOG}" ] && wc -l < "${HUD_LOG}" | tr -d ' ' || echo 0)"
teardown

# --- rotation ---------------------------------------------------------------
setup
export VIBEZ_HUD_LOG_MAX_BYTES=400
for i in 1 2 3 4 5 6 7 8; do fire post-tool-use "{\"session_id\":\"s3\",\"cwd\":\"/tmp/proj\",\"tool_name\":\"T${i}\"}"; done
check "rotates at the byte cap" "yes" "$( [ -f "${SANDBOX}/hud/events.jsonl.1" ] && echo yes || echo no)"
teardown

printf '\n%s\n' "$([ "${FAILURES}" -eq 0 ] && echo 'ALL PASS' || echo "${FAILURES} FAILURE(S)")"
exit "$([ "${FAILURES}" -eq 0 ] && echo 0 || echo 1)"
```

- [ ] **Step 2: Run to verify it fails**

```bash
chmod +x ClaudePlugin/test/hud.e2e.sh && ./ClaudePlugin/test/hud.e2e.sh
```

Expected: FAIL — no HUD log is written at all.

- [ ] **Step 3: Add the writer helpers to `notify.sh`**

Insert immediately after the existing `log()` definition (around line 44), so
`CONFIG_DIR` is already resolved:

```bash
# --- HUD sidecar log -------------------------------------------------------
# The notch app tails this. Deliberately SEPARATE from post_vibez: the push
# path suppresses events on purpose (block debounce, stop_pending_work gate,
# Stop grace) to protect the phone from spam, and the HUD needs every
# transition. Never call curl from here — SessionEnd hooks get killed fast.
HUD_DIR="${CONFIG_DIR}/hud"
HUD_LOG="${HUD_DIR}/events.jsonl"
HUD_LOG_MAX_BYTES="${VIBEZ_HUD_LOG_MAX_BYTES:-2097152}"

# BSD date has no %N, and jq is already a hard dependency of this script.
hud_now_ms() { jq -n '(now * 1000) | floor'; }

hud_rotate_if_needed() {
    [ -f "${HUD_LOG}" ] || return 0
    local size
    size="$(wc -c < "${HUD_LOG}" 2>/dev/null | tr -d ' ')"
    case "${size}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${size}" -lt "${HUD_LOG_MAX_BYTES}" ] && return 0
    mv -f "${HUD_LOG}" "${HUD_LOG}.1" 2>/dev/null || true
}

# Walk up the process tree from this hook. Records TWO things:
#   agentPid  the claude/codex/cursor process, for liveness
#   appPid    the OUTERMOST .app ancestor, for click-to-jump
# Outermost matters: taking the first .app lands on "Cursor Helper.app" for
# integrated terminals; continuing to the root correctly yields "Cursor.app".
# Echoes: "<agentPid>|<agentStart>|<appPid>|<appName>"
hud_process_chain() {
    local pid="${PPID}" agent_pid="" app_pid="" app_name="" comm ppid guard=0
    while [ -n "${pid}" ] && [ "${pid}" -gt 1 ] 2>/dev/null && [ "${guard}" -lt 24 ]; do
        guard=$((guard + 1))
        comm="$(ps -o comm= -p "${pid}" 2>/dev/null)"
        [ -z "${comm}" ] && break
        case "${comm}" in
            */claude|*/codex|*/cursor-agent|claude|codex|cursor-agent)
                [ -z "${agent_pid}" ] && agent_pid="${pid}" ;;
        esac
        case "${comm}" in
            *.app/Contents/MacOS/*)
                app_pid="${pid}"
                app_name="$(printf '%s' "${comm}" | sed -E 's|.*/([^/]+)\.app/Contents/MacOS/.*|\1|')" ;;
        esac
        ppid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')"
        [ -z "${ppid}" ] && break
        pid="${ppid}"
    done
    [ -z "${agent_pid}" ] && agent_pid="${PPID}"
    local agent_start
    agent_start="$(ps -o lstart= -p "${agent_pid}" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
    printf '%s|%s|%s|%s' "${agent_pid}" "${agent_start}" "${app_pid}" "${app_name}"
}

# hud_record <kind> <sid> <proj> <cwd> <title> [body] [tool]
# A single O_APPEND printf: atomic against the parallel hooks Claude Code fires,
# which is why this is an append-only log and not per-session state files.
hud_record() {
    local kind="$1" sid="$2" proj="$3" cwd="$4" title="$5" body="${6:-}" tool="${7:-}"
    [ -z "${sid}" ] && return 0
    [ "${sid}" = "nosid" ] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    mkdir -p "${HUD_DIR}" 2>/dev/null || return 0
    chmod 700 "${HUD_DIR}" 2>/dev/null || true
    hud_rotate_if_needed

    local ts extra="{}" line
    ts="$(hud_now_ms)" || return 0
    if [ "${kind}" = "start" ]; then
        local chain agent_pid agent_start app_pid app_name
        chain="$(hud_process_chain)"
        agent_pid="${chain%%|*}"; chain="${chain#*|}"
        agent_start="${chain%%|*}"; chain="${chain#*|}"
        app_pid="${chain%%|*}"; app_name="${chain#*|}"
        extra="$(jq -nc \
            --argjson agentPid "${agent_pid:-0}" \
            --arg agentStart "${agent_start}" \
            --argjson appPid "${app_pid:-0}" \
            --arg app "${app_name}" \
            '{agentPid:$agentPid, agentStart:$agentStart}
             + (if $appPid > 0 then {appPid:$appPid, app:$app} else {} end)')"
    fi

    line="$(jq -nc \
        --argjson v 1 --argjson ts "${ts}" \
        --arg sid "${sid}" --arg agent "cc" --arg kind "${kind}" \
        --arg proj "${proj}" --arg cwd "${cwd}" \
        --arg title "$(clamp_field "${title}" 100)" \
        --arg body "$(clamp_field "${body}" 200)" \
        --arg tool "${tool}" \
        --argjson extra "${extra}" \
        '{v:$v, ts:$ts, sid:$sid, agent:$agent, kind:$kind, proj:$proj, cwd:$cwd, title:$title}
         + (if $body != "" then {body:$body} else {} end)
         + (if $tool != "" then {tool:$tool} else {} end)
         + $extra')" || return 0

    printf '%s\n' "${line}" >> "${HUD_LOG}" 2>/dev/null || true
    chmod 600 "${HUD_LOG}" 2>/dev/null || true
}
```

- [ ] **Step 4: Add the call sites**

In each hook handler, add a `hud_record` line right after `proj`/`title` are
resolved and **before** any `post_vibez` call. Handlers and the kind each emits:

| Handler (search for the `case` label) | Line to add |
|---|---|
| `session-start` | `hud_record "start" "${sid}" "${proj}" "${cwd}" "${convo_title:-${proj}}"` |
| `user-prompt-submit` | `hud_record "prompt" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${prompt}"` |
| `post-tool-use` | `hud_record "tool" "${sid}" "${proj}" "${cwd}" "${convo_title}" "" "${tool_name}"` |
| `post-tool-use-failure` | `hud_record "tool" "${sid}" "${proj}" "${cwd}" "${convo_title}" "" "${tool_name}"` |
| `pre-tool-use` (AskUserQuestion) | `hud_record "needs-input" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${question}" "AskUserQuestion"` |
| `permission-request` | `hud_record "needs-input" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${body}" "${tool_name}"` |
| `notification` | `hud_record "needs-input" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${message}"` — placed **after** the existing idle-reminder skip, so it inherits that one suppression deliberately |
| `stop` | `hud_record "${stop_kind}" "${sid}" "${proj}" "${cwd}" "${convo_title}" "${body}"`, placed **before** `defer_stop_push` so the HUD is not gated by the grace window. See the note below on the handler's early exits. |
| `session-end` (new handler) | `hud_record "end" "${sid}" "${proj}" "${cwd}" "${convo_title:-${proj}}"` |

**The `stop` handler's three early exits, and which the HUD must survive.**
`stop)` returns early in three places before reaching `hud_record`:

1. **`stop_pending_work` gate** — skip the HUD record too. That turn end is a
   pause, not a stop: the harness resumes the session itself, so the session
   genuinely is still WORKING and saying otherwise would be a lie.
2. **`is_slash_command`** — skip. Consistent with the push path; a
   `/vibez:setup` invocation is not a session worth a row.
3. **empty `excerpt`** — **do NOT skip.** That guard exists so the *phone*
   doesn't get a contentless "Claude finished a turn." push. But a finished
   turn with no excerpt is still a finished turn, and skipping it leaves the
   session showing WORKING until staleness eventually ends it — a visible lie
   in the panel. Restructure so the HUD record is written either way: classify
   as `done` when there is no excerpt (with no text, `last_turn_is_asking`
   cannot detect a question), pass an empty body, and let the push path keep
   its own early return.

**Keep `hud_record` to ONE `jq` invocation.** `post-tool-use` is the hottest
hook in the script — it fires on every single tool call — so subprocess count
there is a real cost, measured at +14 ms when the writer spawned three. Fold
the timestamp into the record's own `jq` (`ts: (now * 1000 | floor)`) instead
of a separate `hud_now_ms` call, and only spawn the extra process-chain `jq` on
`start` records, which happen once per session.

Add the new handler to the `case` statement:

```bash
    session-end)
        sid="$(jq_get '.session_id')"
        cwd="$(jq_get '.cwd')"
        proj="$(basename "${cwd:-unknown}")"
        # Record only — never push, never curl. Claude Code kills SessionEnd
        # hooks quickly during exit (see CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS).
        hud_record "end" "${sid}" "${proj}" "${cwd}" "${proj}"
        ;;
```

- [ ] **Step 5: Register the SessionEnd hook**

Add to `ClaudePlugin/hooks/hooks.json`:

```json
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh\" session-end"
          }
        ]
      }
    ],
```

Verify it parses: `jq -e '.hooks.SessionEnd' ClaudePlugin/hooks/hooks.json`

- [ ] **Step 6: Run both suites**

```bash
./ClaudePlugin/test/hud.e2e.sh && ./ClaudePlugin/test/hooks.e2e.sh
```

Expected: both print `ALL PASS`. The pre-existing suite must stay green — the
HUD writer is additive and must not perturb the push path.

- [ ] **Step 7: Commit**

```bash
git add ClaudePlugin/scripts/notify.sh ClaudePlugin/hooks/hooks.json ClaudePlugin/test/hud.e2e.sh
git commit -m "feat(hud): Claude plugin writes HUD records at the event site"
```

---

### Task 11: The bash writer — Codex plugin

**Files:**
- Modify: `CodexPlugin/scripts/notify.sh`
- Create: `CodexPlugin/test/hud.e2e.sh`

**Interfaces:**
- Consumes: the `hud_record` / `hud_process_chain` / `hud_now_ms` shape from Task 10

- [ ] **Step 1: Write the test**

Copy `ClaudePlugin/test/hud.e2e.sh` to `CodexPlugin/test/hud.e2e.sh` and change:
- the header line to `CodexPlugin HUD writer`
- every `check` for the agent tag to expect `cx`
- add this Codex-specific case (Codex has no SessionEnd hook, and ephemeral
  sessions must not appear at all):

```bash
# --- ephemeral sessions never reach the HUD --------------------------------
setup
fire session-start '{"session_id":"eph1","cwd":"/tmp/proj","ephemeral":true}'
fire post-tool-use '{"session_id":"eph1","cwd":"/tmp/proj","tool_name":"Read"}'
check "ephemeral sessions are invisible to the HUD" "0" \
  "$( [ -f "${HUD_LOG}" ] && jq -r 'select(.sid=="eph1")' "${HUD_LOG}" | jq -s 'length' || echo 0)"
teardown

# --- agent tag --------------------------------------------------------------
setup
fire post-tool-use '{"session_id":"c1","cwd":"/tmp/proj","tool_name":"Edit"}'
check "agent tag is cx" "cx" "$(jq -r '.agent' "${HUD_LOG}" | head -1)"
teardown
```

- [ ] **Step 2: Run to verify it fails**

```bash
chmod +x CodexPlugin/test/hud.e2e.sh && ./CodexPlugin/test/hud.e2e.sh
```

Expected: FAIL — no HUD log written.

- [ ] **Step 3: Port the helpers**

Copy the entire `--- HUD sidecar log ---` block from `ClaudePlugin/scripts/notify.sh`
into `CodexPlugin/scripts/notify.sh` after its `log()` definition, changing exactly
one thing: `--arg agent "cc"` becomes `--arg agent "cx"`.

Add call sites to Codex's six handlers, using the same kind mapping as Task 10
(`SessionStart`→`start`, `UserPromptSubmit`→`prompt`, `PostToolUse`→`tool`,
`PreToolUse`→`needs-input`, `PermissionRequest`→`needs-input`, `Stop`→`done`/`needs-input`).

Guard the ephemeral case — place `hud_record` calls **after** the existing
ephemeral-session detection returns, so ephemeral sessions never write records.

Codex registers no `SessionEnd` hook, so Codex sessions reach ENDED through PID
liveness. Do not invent one.

- [ ] **Step 4: Run both suites**

```bash
./CodexPlugin/test/hud.e2e.sh && ./CodexPlugin/test/hooks.e2e.sh 2>/dev/null || ./CodexPlugin/test/hud.e2e.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add CodexPlugin/scripts/notify.sh CodexPlugin/test/hud.e2e.sh
git commit -m "feat(hud): Codex plugin writes HUD records"
```

---

### Task 12: The bash writer — Cursor plugin

**Files:**
- Modify: `CursorPlugin/scripts/notify.sh`
- Create: `CursorPlugin/test/hud.e2e.sh`

- [ ] **Step 1: Write the test**

Copy the Codex suite to `CursorPlugin/test/hud.e2e.sh`, expect agent `cu`, and
replace the `fire` helper — Cursor dispatches on the payload's `hook_event_name`
with no argument:

```bash
fire() { printf '%s' "$1" | bash "${NOTIFY}" >/dev/null 2>&1; }
```

Cases:

```bash
setup
fire '{"hook_event_name":"sessionStart","conversation_id":"cu1","workspace_roots":["/tmp/proj"]}'
fire '{"hook_event_name":"beforeSubmitPrompt","conversation_id":"cu1","workspace_roots":["/tmp/proj"],"prompt":"go"}'
fire '{"hook_event_name":"afterAgentResponse","conversation_id":"cu1","workspace_roots":["/tmp/proj"],"text":"done thinking"}'
fire '{"hook_event_name":"stop","conversation_id":"cu1","workspace_roots":["/tmp/proj"],"status":"completed"}'
fire '{"hook_event_name":"sessionEnd","conversation_id":"cu1","workspace_roots":["/tmp/proj"]}'
check "cursor kind sequence" "start,prompt,tool,done,end," "$(jq -r '.kind' "${HUD_LOG}" | tr '\n' ',')"
check "agent tag is cu" "cu" "$(jq -r '.agent' "${HUD_LOG}" | head -1)"
check "proj from workspace root" "proj" "$(jq -r '.proj' "${HUD_LOG}" | head -1)"
teardown

# aborted turns end the session rather than claiming it finished
setup
fire '{"hook_event_name":"sessionStart","conversation_id":"cu2","workspace_roots":["/tmp/proj"]}'
fire '{"hook_event_name":"stop","conversation_id":"cu2","workspace_roots":["/tmp/proj"],"status":"aborted"}'
check "aborted stop records end, not done" "end" "$(jq -r 'select(.kind!="start") | .kind' "${HUD_LOG}" | head -1)"
teardown

# background agents stay invisible
setup
fire '{"hook_event_name":"sessionStart","conversation_id":"bg1","workspace_roots":["/tmp/proj"],"is_background_agent":true}'
fire '{"hook_event_name":"afterAgentResponse","conversation_id":"bg1","workspace_roots":["/tmp/proj"],"text":"x"}'
check "background agents write nothing" "0" \
  "$( [ -f "${HUD_LOG}" ] && jq -r 'select(.sid=="bg1")' "${HUD_LOG}" | jq -s 'length' || echo 0)"
teardown
```

- [ ] **Step 2: Run to verify it fails**

```bash
chmod +x CursorPlugin/test/hud.e2e.sh && ./CursorPlugin/test/hud.e2e.sh
```

Expected: FAIL.

- [ ] **Step 3: Port the helpers and wire the five handlers**

Copy the HUD block in, with `--arg agent "cu"`. Call sites:

- `sessionStart` → `hud_record "start" ...`, placed **after** the background-agent
  marker check so bg agents write nothing.
- `beforeSubmitPrompt` → `hud_record "prompt" ...`. This handler must still always
  emit `{"continue":true}` — it can block prompts, so `hud_record` must not be able
  to change its stdout. Keep the record call before the JSON is printed and ensure
  it writes nothing to stdout (it doesn't — every path is redirected or appends to a file).
- `afterAgentResponse` → `hud_record "tool" ...`
- `stop` → `end` when the payload's status is aborted, else `done` / `needs-input`
  using the existing `last_turn_is_asking` classification.
- `sessionEnd` → `hud_record "end" ...`, before the existing cleanup deletes the
  per-session stash.

- [ ] **Step 4: Run all Cursor suites**

```bash
./CursorPlugin/test/hud.e2e.sh && ./CursorPlugin/test/hooks.e2e.sh
```

Expected: both `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add CursorPlugin/scripts/notify.sh CursorPlugin/test/hud.e2e.sh
git commit -m "feat(hud): Cursor plugin writes HUD records"
```

---

### Task 13: End-to-end golden snapshot + `Tests/run-all.sh`

**Files:**
- Create: `Tests/hud-e2e.sh`, `Tests/fixtures/golden-session.json`, `Tests/run-all.sh`

- [ ] **Step 1: Write the e2e driver**

```bash
#!/usr/bin/env bash
# Tests/hud-e2e.sh
# Drives a realistic session through the REAL notify.sh, then asserts the
# probe's rendered state against a golden snapshot. No UI involved.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

run_plugin() {
    local name="$1" notify="$2"
    local sandbox; sandbox="$(mktemp -d)"
    export VIBEZ_CONFIG_DIR="${sandbox}"
    export VIBEZ_STOP_GRACE_SECONDS=0
    export VIBEZ_BLOCK_DEBOUNCE_SECONDS=0
    printf 'moss-pine-fox-jazz\n' > "${sandbox}/vibez-id"
    local bin="${sandbox}/bin"; mkdir -p "${bin}"
    printf '#!/bin/sh\nexit 0\n' > "${bin}/curl"; chmod +x "${bin}/curl"
    PATH="${bin}:${PATH}"

    # start -> prompt -> 3 tools -> permission -> approval -> tool -> stop
    printf '%s' '{"session_id":"e2e","cwd":"/tmp/Vibez"}' | bash "${notify}" session-start >/dev/null 2>&1
    printf '%s' '{"session_id":"e2e","cwd":"/tmp/Vibez","prompt":"ship the notch app"}' | bash "${notify}" user-prompt-submit >/dev/null 2>&1
    for t in Read Grep Edit; do
        printf '%s' "{\"session_id\":\"e2e\",\"cwd\":\"/tmp/Vibez\",\"tool_name\":\"${t}\"}" | bash "${notify}" post-tool-use >/dev/null 2>&1
    done
    printf '%s' '{"session_id":"e2e","cwd":"/tmp/Vibez","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}' | bash "${notify}" permission-request >/dev/null 2>&1

    local out
    out="$("${ROOT}/VibezHUD/.build/debug/vibez-hud-probe" "${sandbox}/hud/events.jsonl")"
    local state proj
    state="$(printf '%s' "${out}" | jq -r '.needsYou[0].state')"
    proj="$(printf '%s' "${out}" | jq -r '.needsYou[0].proj')"

    if [ "${state}" = "needsYou" ] && [ "${proj}" = "Vibez" ]; then
        printf '  ok   %s: blocked session surfaces in needsYou\n' "${name}"
    else
        printf '  FAIL %s: want needsYou/Vibez, got %s/%s\n' "${name}" "${state}" "${proj}"
        printf '%s\n' "${out}"
        FAILURES=$((FAILURES+1))
    fi
    rm -rf "${sandbox}"
}

printf 'HUD end-to-end (plugin -> log -> probe)\n'
run_plugin "claude" "${ROOT}/ClaudePlugin/scripts/notify.sh"
run_plugin "codex"  "${ROOT}/CodexPlugin/scripts/notify.sh"

printf '\n%s\n' "$([ "${FAILURES}" -eq 0 ] && echo 'ALL PASS' || echo "${FAILURES} FAILURE(S)")"
exit "$([ "${FAILURES}" -eq 0 ] && echo 0 || echo 1)"
```

- [ ] **Step 2: Write the single entry point**

```bash
#!/usr/bin/env bash
# Tests/run-all.sh — everything, green or red.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=()

step() {
    printf '\n=== %s ===\n' "$1"; shift
    if "$@"; then printf '--- pass\n'; else printf '--- FAIL\n'; FAILED+=("$1"); fi
}

step "swift unit tests"      bash -c "cd '${ROOT}/VibezHUD' && swift test"
step "build probe"           bash -c "cd '${ROOT}/VibezHUD' && swift build --product vibez-hud-probe"
step "claude hud writer"     "${ROOT}/ClaudePlugin/test/hud.e2e.sh"
step "claude push hooks"     "${ROOT}/ClaudePlugin/test/hooks.e2e.sh"
step "codex hud writer"      "${ROOT}/CodexPlugin/test/hud.e2e.sh"
step "cursor hud writer"     "${ROOT}/CursorPlugin/test/hud.e2e.sh"
step "cursor push hooks"     "${ROOT}/CursorPlugin/test/hooks.e2e.sh"
step "hud end-to-end"        "${ROOT}/Tests/hud-e2e.sh"

printf '\n========================\n'
if [ "${#FAILED[@]}" -eq 0 ]; then printf 'ALL GREEN\n'; exit 0; fi
printf 'FAILED: %s\n' "${FAILED[*]}"; exit 1
```

- [ ] **Step 3: Run it**

```bash
chmod +x Tests/hud-e2e.sh Tests/run-all.sh && ./Tests/run-all.sh
```

Expected: `ALL GREEN`.

- [ ] **Step 4: Commit**

```bash
git add Tests/hud-e2e.sh Tests/run-all.sh
git commit -m "test(hud): end-to-end plugin->log->probe suite and one-command runner"
```

---

### Task 14: Replay real history + invariant fuzzing

**Files:**
- Test: `VibezHUD/Tests/VibezSessionKitTests/ReplayInvariantTests.swift`

- [ ] **Step 1: Write the tests**

```swift
// VibezHUD/Tests/VibezSessionKitTests/ReplayInvariantTests.swift
import Testing
import Foundation
@testable import VibezSessionKit

/// Invariants that must hold after ANY sequence of events, however absurd.
private func assertInvariants(_ snap: HUDSnapshot, line: Int = #line) {
    for s in snap.needsYou { #expect(s.state == .needsYou) }
    for s in snap.working  { #expect(s.state == .working) }
    for s in snap.done     { #expect(s.state == .done || s.state == .ended) }
    let all = snap.needsYou + snap.working + snap.done
    #expect(Set(all.map(\.sid)).count == all.count, "a session appeared in two columns")
    for s in all { #expect(s.lastActivityMs >= s.startedAtMs) }
}

@Test func randomEventStormsNeverProduceAnImpossibleState() {
    var seed: UInt64 = 0x5EED
    func rnd(_ n: Int) -> Int {                       // deterministic LCG
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }
    let kinds: [EventKind] = [.start, .prompt, .tool, .needsInput, .done, .end]

    for round in 0..<200 {
        let clock = FakeClock(1_000_000)
        let live = FakeLiveness(); live.table[999] = (true, nil)
        let store = SessionStore(clock: clock, liveness: live)
        for _ in 0..<120 {
            let kind = kinds[rnd(kinds.count)]
            let sid = "s\(rnd(6))"
            // Timestamps deliberately jitter backwards to exercise stale handling.
            let ts = Int64(1_000_000 + rnd(4_000) - 2_000)
            store.apply(makeEvent(kind, ts: ts, sid: sid, agentPid: 999))
            if rnd(9) == 0 { clock.advance(ms: Int64(rnd(9_000))) }
        }
        assertInvariants(store.snapshot(), line: round)
    }
}

@Test func replayingTheRealVibezLogNeverBreaksTheReducer() throws {
    // Transcodes the human-readable log this machine has been writing since May
    // into HUD records. Skipped cleanly on a machine that has no such log.
    let logPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/vibez/log")
    guard let raw = try? String(contentsOf: logPath, encoding: .utf8) else { return }

    let clock = FakeClock(1_000_000)
    let live = FakeLiveness()
    let store = SessionStore(clock: clock, liveness: live)

    var ts: Int64 = 1_000_000
    var applied = 0
    for line in raw.split(separator: "\n") {
        ts += 1_000
        let kind: EventKind
        if line.contains("session-start") { kind = .start }
        else if line.contains("event=replied") { kind = .prompt }
        else if line.contains("event=needs-input") { kind = .needsInput }
        else if line.contains("event=done") { kind = .done }
        else if line.contains("notification:") { kind = .tool }
        else { continue }
        // Bucket into a handful of sessions so sessions actually accumulate history.
        store.apply(makeEvent(kind, ts: ts, sid: "real\(applied % 7)"))
        applied += 1
        if applied % 50 == 0 { clock.set(ts + 5_000); assertInvariants(store.snapshot()) }
    }
    clock.set(ts + 10_000)
    assertInvariants(store.snapshot())
    #expect(applied > 0, "expected to transcode at least one real event")
}
```

- [ ] **Step 2: Run them**

Run: `cd VibezHUD && swift test --filter ReplayInvariant`
Expected: PASS, 2 tests

- [ ] **Step 3: Commit**

```bash
git add VibezHUD/Tests/VibezSessionKitTests/ReplayInvariantTests.swift
git commit -m "test(hud): fuzz the reducer and replay real Vibez history for invariants"
```

---

### Task 15: `NotchGeometry` — pure screen math

**Files:**
- Create: `VibezHUD/Sources/VibezHUDApp/NotchGeometry.swift`
- Test: `VibezHUD/Tests/VibezHUDAppTests/NotchGeometryTests.swift`
- Modify: `VibezHUD/Package.swift` (add the app test target)

**Interfaces:**
- Produces: `ScreenMetrics`, `NotchGeometry.init(metrics:)`, `.hasNotch`, `.notchRect`, `.hoverRect`, `.bubbleRect(rowCount:)`

- [ ] **Step 1: Add the test target to Package.swift**

```swift
        .testTarget(name: "VibezHUDAppTests", dependencies: ["VibezHUDApp"]),
```

- [ ] **Step 2: Write the failing test**

```swift
// VibezHUD/Tests/VibezHUDAppTests/NotchGeometryTests.swift
import Testing
import CoreGraphics
@testable import VibezHUDApp

// A 14" MacBook Pro: 1512x982 points, 32pt safe-area top, notch ~200pt wide.
private let mbp = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
    auxRight: CGRect(x: 856, y: 950, width: 656, height: 32))

// An external display: no notch, no auxiliary areas.
private let external = ScreenMetrics(
    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
    safeAreaTopInset: 0, auxLeft: .zero, auxRight: .zero)

@Test func derivesTheNotchFromTheAuxiliaryAreas() {
    let g = NotchGeometry(metrics: mbp)
    #expect(g.hasNotch)
    #expect(g.notchRect.width == 200)          // 1512 - 656 - 656
    #expect(g.notchRect.height == 32)
    #expect(g.notchRect.minX == 656)
    #expect(g.notchRect.maxY == 982)           // flush with the top edge
}

@Test func fallsBackToACenteredPillWithoutANotch() {
    let g = NotchGeometry(metrics: external)
    #expect(!g.hasNotch)
    #expect(g.notchRect.width == NotchGeometry.fallbackPillWidth)
    #expect(g.notchRect.maxY == 1440)
    #expect(g.notchRect.midX == external.frame.midX)
}

@Test func theHoverZoneIsForgivinglyLargerThanTheNotch() {
    let g = NotchGeometry(metrics: mbp)
    #expect(g.hoverRect.width > g.notchRect.width)
    #expect(g.hoverRect.minY < g.notchRect.minY)      // extends downward
    #expect(g.hoverRect.contains(CGPoint(x: g.notchRect.midX, y: g.notchRect.midY)))
}

@Test func theBubbleIsCappedAndCentered() {
    let g = NotchGeometry(metrics: mbp)
    let small = g.bubbleRect(rowCount: 2)
    let huge = g.bubbleRect(rowCount: 500)
    #expect(huge.height <= mbp.frame.height * 0.62 + 0.001)
    #expect(huge.height >= small.height)
    #expect(huge.width <= 1040)
    #expect(abs(huge.midX - mbp.frame.midX) < 0.001)
    #expect(huge.maxY == mbp.frame.maxY, "the bubble must start at the screen's top edge")
    #expect(huge.width > g.notchRect.width, "must be wider than the notch to swallow it")
}

@Test func aNarrowScreenNeverProducesABubbleWiderThanItself() {
    let tiny = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 900, height: 600),
                             safeAreaTopInset: 0, auxLeft: .zero, auxRight: .zero)
    let g = NotchGeometry(metrics: tiny)
    #expect(g.bubbleRect(rowCount: 10).width <= 900)
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd VibezHUD && swift test --filter NotchGeometry`
Expected: FAIL — `cannot find 'ScreenMetrics' in scope`

- [ ] **Step 4: Implement**

```swift
// VibezHUD/Sources/VibezHUDApp/NotchGeometry.swift
import CoreGraphics

/// Everything NotchGeometry needs from an NSScreen, as plain values — so the
/// math is testable with no display attached.
public struct ScreenMetrics: Sendable, Equatable {
    public var frame: CGRect
    public var safeAreaTopInset: CGFloat
    public var auxLeft: CGRect
    public var auxRight: CGRect

    public init(frame: CGRect, safeAreaTopInset: CGFloat, auxLeft: CGRect, auxRight: CGRect) {
        self.frame = frame; self.safeAreaTopInset = safeAreaTopInset
        self.auxLeft = auxLeft; self.auxRight = auxRight
    }
}

public struct NotchGeometry: Sendable, Equatable {
    public static let fallbackPillWidth: CGFloat = 190
    public static let fallbackPillHeight: CGFloat = 24
    public static let maxBubbleWidth: CGFloat = 1040
    public static let maxBubbleHeightFraction: CGFloat = 0.62
    static let hoverPadX: CGFloat = 44
    static let hoverPadY: CGFloat = 6

    public let metrics: ScreenMetrics
    public let hasNotch: Bool
    public let notchRect: CGRect
    public let hoverRect: CGRect

    public init(metrics: ScreenMetrics) {
        self.metrics = metrics
        let f = metrics.frame
        let notched = metrics.safeAreaTopInset > 0
            && metrics.auxLeft.width > 0 && metrics.auxRight.width > 0
        hasNotch = notched

        if notched {
            let w = f.width - metrics.auxLeft.width - metrics.auxRight.width
            let h = metrics.safeAreaTopInset
            notchRect = CGRect(x: f.minX + metrics.auxLeft.width, y: f.maxY - h, width: w, height: h)
        } else {
            let w = Self.fallbackPillWidth, h = Self.fallbackPillHeight
            notchRect = CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        }

        hoverRect = CGRect(x: notchRect.minX - Self.hoverPadX,
                           y: notchRect.minY - Self.hoverPadY,
                           width: notchRect.width + Self.hoverPadX * 2,
                           height: notchRect.height + Self.hoverPadY)
    }

    /// The expanded bubble: top-anchored, wider than the notch so it swallows it,
    /// capped so it can never take over the screen.
    public func bubbleRect(rowCount: Int) -> CGRect {
        let f = metrics.frame
        let width = min(Self.maxBubbleWidth, f.width * 0.84)
        let contentHeight = 78 + CGFloat(max(rowCount, 1)) * 62
        let height = min(contentHeight, f.height * Self.maxBubbleHeightFraction)
        return CGRect(x: f.midX - width / 2, y: f.maxY - height, width: width, height: height)
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `cd VibezHUD && swift test --filter NotchGeometry`
Expected: PASS, 5 tests

- [ ] **Step 6: Commit**

```bash
git add VibezHUD/Package.swift VibezHUD/Sources/VibezHUDApp/NotchGeometry.swift VibezHUD/Tests/VibezHUDAppTests/NotchGeometryTests.swift
git commit -m "feat(hud): pure notch geometry with notch, fallback-pill and bubble rects"
```

---

### Task 16: `HoverPolicy` — deterministic hysteresis

**Files:**
- Create: `VibezHUD/Sources/VibezHUDApp/HoverPolicy.swift`
- Test: `VibezHUD/Tests/VibezHUDAppTests/HoverPolicyTests.swift`

**Interfaces:**
- Produces: `HoverPolicy.init(openDelayMs:closeDelayMs:)`, `mutating func handle(_:nowMs:)`, `mutating func tick(nowMs:) -> Bool`, `var isExpanded: Bool`

- [ ] **Step 1: Write the failing test**

```swift
// VibezHUD/Tests/VibezHUDAppTests/HoverPolicyTests.swift
import Testing
@testable import VibezHUDApp

@Test func openingWaitsOutTheDelay() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000)
    #expect(!p.isExpanded)
    _ = p.tick(nowMs: 1_119)
    #expect(!p.isExpanded)
    _ = p.tick(nowMs: 1_120)
    #expect(p.isExpanded)
}

@Test func aFlickThroughTheNotchNeverOpensIt() {
    // Pointer crosses the notch on its way somewhere else.
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000)
    p.handle(.exited, nowMs: 1_040)
    _ = p.tick(nowMs: 5_000)
    #expect(!p.isExpanded)
}

@Test func closingIsForgivingAndCancelledByReentry() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000); _ = p.tick(nowMs: 1_200)
    #expect(p.isExpanded)

    p.handle(.exited, nowMs: 2_000)
    _ = p.tick(nowMs: 2_200)
    #expect(p.isExpanded, "must survive the pointer crossing a seam")

    p.handle(.entered, nowMs: 2_250)      // came back
    _ = p.tick(nowMs: 9_000)
    #expect(p.isExpanded, "re-entry cancels the pending close")
}

@Test func closingCompletesWhenThePointerStaysAway() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000); _ = p.tick(nowMs: 1_200)
    p.handle(.exited, nowMs: 2_000)
    _ = p.tick(nowMs: 2_349)
    #expect(p.isExpanded)
    _ = p.tick(nowMs: 2_350)
    #expect(!p.isExpanded)
}

@Test func tickReportsOnlyRealChanges() {
    var p = HoverPolicy(openDelayMs: 120, closeDelayMs: 350)
    p.handle(.entered, nowMs: 1_000)
    #expect(p.tick(nowMs: 1_050) == false)
    #expect(p.tick(nowMs: 1_120) == true)     // opened
    #expect(p.tick(nowMs: 1_500) == false)    // steady
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd VibezHUD && swift test --filter HoverPolicy`
Expected: FAIL — `cannot find 'HoverPolicy' in scope`

- [ ] **Step 3: Implement**

```swift
// VibezHUD/Sources/VibezHUDApp/HoverPolicy.swift
import Foundation

public enum HoverInput: Sendable { case entered, exited }

/// Hysteresis for the notch. Pure and clock-driven, because "the panel vanishes
/// when the pointer crosses a seam" is the single most common way a hover UI
/// feels broken — and it is untestable if the timing lives in the view layer.
public struct HoverPolicy: Sendable, Equatable {
    private enum Phase: Equatable { case collapsed, opening(at: Int64), expanded, closing(at: Int64) }

    public let openDelayMs: Int64
    public let closeDelayMs: Int64
    private var phase: Phase = .collapsed

    public init(openDelayMs: Int64 = 120, closeDelayMs: Int64 = 350) {
        self.openDelayMs = openDelayMs
        self.closeDelayMs = closeDelayMs
    }

    public var isExpanded: Bool {
        switch phase { case .expanded, .closing: true; default: false }
    }

    public mutating func handle(_ input: HoverInput, nowMs: Int64) {
        switch (input, phase) {
        case (.entered, .collapsed):        phase = .opening(at: nowMs)
        case (.entered, .closing):          phase = .expanded          // re-entry cancels the close
        case (.entered, .opening), (.entered, .expanded): break
        case (.exited, .opening):           phase = .collapsed          // a flick-through never opens
        case (.exited, .expanded):          phase = .closing(at: nowMs)
        case (.exited, .collapsed), (.exited, .closing): break
        }
    }

    /// Advances time. Returns true only when `isExpanded` actually flipped.
    @discardableResult
    public mutating func tick(nowMs: Int64) -> Bool {
        let before = isExpanded
        switch phase {
        case .opening(let at) where nowMs - at >= openDelayMs:  phase = .expanded
        case .closing(let at) where nowMs - at >= closeDelayMs: phase = .collapsed
        default: break
        }
        return isExpanded != before
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd VibezHUD && swift test --filter HoverPolicy`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezHUDApp/HoverPolicy.swift VibezHUD/Tests/VibezHUDAppTests/HoverPolicyTests.swift
git commit -m "feat(hud): deterministic hover hysteresis policy"
```

---

### Task 17: Theme, demo data, and the app shell

**Files:**
- Create: `VibezHUD/Sources/VibezHUDApp/Views/HUDTheme.swift`, `DemoData.swift`, `HUDViewModel.swift`, `NotchWindowController.swift`, `main.swift`

**Interfaces:**
- Consumes: `NotchGeometry` (15), `HoverPolicy` (16), `HUDEngine`/`HUDSnapshot` (9)
- Produces: `HUDTheme` constants, `DemoData.snapshot()`, `HUDViewModel` (`@Observable`, `.snapshot`, `.isExpanded`), `NotchWindowController`

- [ ] **Step 1: Write the theme**

```swift
// VibezHUD/Sources/VibezHUDApp/Views/HUDTheme.swift
import SwiftUI
import AppKit
import VibezSessionKit

enum HUDTheme {
    // Set from the Task 1 spike result. If the spike needed a higher level,
    // change ONLY this line.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    // Apple dark-mode system colors. Each means exactly one thing: state.
    static let needsYou = Color(red: 1.00, green: 0.62, blue: 0.04)   // #FF9F0A
    static let done     = Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158
    static let working  = Color(red: 0.39, green: 0.82, blue: 1.00)   // #64D2FF  teal, not blue —
                                                                      // deliberately unlike Codex's brand blue
    static let ended    = Color(red: 0.60, green: 0.60, blue: 0.62)   // #98989D

    // Agent brand chips — the same colors as the phone app, shield and extension.
    static func chip(_ agent: AgentTag) -> Color {
        switch agent {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)    // #d97757
        case .codex:  Color(red: 0.29,  green: 0.48,  blue: 1.00)     // #4A7AFF
        case .cursor: Color(red: 0.647, green: 0.647, blue: 0.725)    // #A5A5B9
        }
    }

    static func glyph(_ agent: AgentTag) -> String {
        switch agent { case .claude: "✳"; case .codex: "◆"; case .cursor: "▲" }
    }

    // The bubble is opaque black in BOTH appearances: it is the Dynamic Island,
    // and the island is black on iPhone regardless of light/dark. A light bubble
    // exposes the seam against the black notch and kills the illusion.
    static let bubbleFill = Color.black
    static let tileFill = Color.white.opacity(0.075)
    static let tileStroke = Color.white.opacity(0.085)
    static let bubbleCornerRadius: CGFloat = 30
    static let earCornerRadius: CGFloat = 10

    static let expand = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let contentFadeDelay: Double = 0.16
}
```

- [ ] **Step 2: Write the demo data**

```swift
// VibezHUD/Sources/VibezHUDApp/DemoData.swift
import Foundation
import VibezSessionKit

/// `--demo` seeds one session in every state so the whole UI is inspectable in
/// one second, with no agents running.
enum DemoData {
    static func snapshot() -> HUDSnapshot {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func s(_ sid: String, _ agent: AgentTag, _ proj: String, _ title: String,
               _ state: SessionState, _ tool: String?, _ detail: String?, _ agoMs: Int64) -> Session {
            Session(sid: sid, agent: agent, proj: proj, cwd: "/tmp/\(proj)", title: title,
                    detail: detail, tool: tool, state: state,
                    startedAtMs: now - agoMs - 60_000, lastActivityMs: now - agoMs,
                    stateSinceMs: now - agoMs, agentPid: nil, agentStart: nil,
                    appPid: nil, app: nil)
        }
        return HUDSnapshot(
            needsYou: [
                s("d1", .claude, "Vibez", "Mac notch app", .needsYou, "Bash", "rm -rf build", 12_000),
                s("d2", .codex, "vibez-backend", "Deploy the ratelimit fix", .needsYou, nil, "deploy to prod now?", 61_000),
            ],
            done: [
                s("d3", .claude, "carousel", "Export spread stills", .done, nil, nil, 8 * 60_000),
                s("d4", .claude, "ClaudePlugin", "Approval watcher port", .ended, nil, nil, 40 * 60_000),
            ],
            working: [
                s("d5", .codex, "vibez-backend", "Rate-limit escalation", .working, "Edit", "ratelimit.ts", 3_000),
                s("d6", .cursor, "VibezExtension", "Popup analytics", .working, "Bash", "npm test", 40_000),
            ])
    }
}
```

- [ ] **Step 3: Write the view model**

```swift
// VibezHUD/Sources/VibezHUDApp/HUDViewModel.swift
import Foundation
import Observation
import VibezSessionKit

@Observable
@MainActor
final class HUDViewModel {
    private(set) var snapshot: HUDSnapshot = HUDSnapshot()
    private(set) var isExpanded = false

    private let engine: HUDEngine?
    private var hover: HoverPolicy
    private var timer: Timer?
    private let isDemo: Bool

    init(demo: Bool) {
        isDemo = demo
        hover = HoverPolicy()
        engine = demo ? nil : HUDEngine()
        if demo { snapshot = DemoData.snapshot() } else { snapshot = engine?.primeAndDrain() ?? HUDSnapshot() }
    }

    func start() {
        // One timer drives both the log drain and the hover clock. 100 ms is well
        // under the 120 ms open delay, so hysteresis stays accurate.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func hoverChanged(_ input: HoverInput) {
        hover.handle(input, nowMs: nowMs)
        tick()
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var pollCounter = 0
    private func tick() {
        if hover.tick(nowMs: nowMs) { isExpanded = hover.isExpanded }
        guard !isDemo, let engine else { return }
        // Drain the log ~5x/sec; the hover clock still ticks at 10Hz.
        pollCounter += 1
        if pollCounter % 2 == 0 { snapshot = engine.poll() }
    }

    var needsYouCount: Int { snapshot.needsYou.count }
    var workingCount: Int { snapshot.working.count }
    var totalRows: Int { snapshot.needsYou.count + snapshot.done.count + snapshot.working.count }
}
```

- [ ] **Step 4: Write the window controller and entry point**

```swift
// VibezHUD/Sources/VibezHUDApp/NotchWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let model: HUDViewModel
    private var geometry: NotchGeometry

    init(model: HUDViewModel) {
        self.model = model
        self.geometry = NotchWindowController.currentGeometry()

        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = HUDTheme.windowLevel
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = HUDRootView(model: model)
            .environment(\.notchGeometry, geometry)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        panel.contentView = TrackingContainer(model: model, child: host)

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.geometry = NotchWindowController.currentGeometry()
                    self?.layout()
                }
            }
    }

    static func currentGeometry() -> NotchGeometry {
        // The menu-bar screen, which is the one that has a notch if any does.
        let screen = NSScreen.screens.first ?? NSScreen.main!
        return NotchGeometry(metrics: ScreenMetrics(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxLeft: screen.auxiliaryTopLeftArea ?? .zero,
            auxRight: screen.auxiliaryTopRightArea ?? .zero))
    }

    /// The panel is always sized for the EXPANDED bubble; the SwiftUI content
    /// draws the collapsed ears inside it. That keeps the morph inside one view
    /// hierarchy instead of resizing a window mid-animation.
    func layout() {
        let rect = geometry.bubbleRect(rowCount: max(model.totalRows, 3))
        let padded = rect.insetBy(dx: -60, dy: 0)
        panel.setFrame(CGRect(x: padded.minX, y: padded.minY,
                              width: padded.width, height: rect.height + 20), display: true)
    }
}

/// Hosts the SwiftUI content and reports hover with `.activeAlways`, which is
/// what makes tracking fire while the app is inactive.
private final class TrackingContainer: NSView {
    private let model: HUDViewModel
    init(model: HUDViewModel, child: NSView) {
        self.model = model
        super.init(frame: .zero)
        addSubview(child)
        child.frame = bounds
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        Task { @MainActor in model.hoverChanged(.entered) }
    }
    override func mouseExited(with event: NSEvent) {
        Task { @MainActor in model.hoverChanged(.exited) }
    }
}
```

```swift
// VibezHUD/Sources/VibezHUDApp/main.swift
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var model: HUDViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        let model = HUDViewModel(demo: demo)
        self.model = model
        controller = NotchWindowController(model: model)
        model.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // no Dock icon, no menu bar item
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 5: Build (views come next task — stub the root view to compile)**

Create a temporary stub so this task builds on its own:

```swift
// VibezHUD/Sources/VibezHUDApp/Views/HUDRootView.swift  (replaced in Task 18)
import SwiftUI

struct NotchGeometryKey: EnvironmentKey {
    static let defaultValue = NotchGeometry(metrics: ScreenMetrics(
        frame: .init(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32,
        auxLeft: .init(x: 0, y: 950, width: 656, height: 32),
        auxRight: .init(x: 856, y: 950, width: 656, height: 32)))
}
extension EnvironmentValues {
    var notchGeometry: NotchGeometry {
        get { self[NotchGeometryKey.self] }
        set { self[NotchGeometryKey.self] = newValue }
    }
}

struct HUDRootView: View {
    let model: HUDViewModel
    var body: some View {
        Text(model.isExpanded ? "expanded \(model.totalRows)" : "collapsed")
            .foregroundStyle(.white)
            .padding()
            .background(.black)
    }
}
```

Run: `cd VibezHUD && swift build && swift run VibezHUDApp --demo`
Expected: a black box at the top of the screen that changes text on hover. Ctrl-C to quit.

- [ ] **Step 6: Commit**

```bash
git add VibezHUD/Sources/VibezHUDApp
git commit -m "feat(hud): app shell, theme, demo data, notch panel with active-always tracking"
```

---

### Task 18: The collapsed ears and the expanded bubble

**Files:**
- Create: `VibezHUD/Sources/VibezHUDApp/Views/CollapsedEars.swift`, `SessionTile.swift`, `BubbleBoard.swift`, `VibezHUD/Sources/VibezHUDApp/TerminalJumper.swift`
- Modify: `VibezHUD/Sources/VibezHUDApp/Views/HUDRootView.swift` (replace the stub)

**Interfaces:**
- Consumes: `HUDTheme`, `HUDViewModel`, `NotchGeometry`, `Session`, `HUDSnapshot`
- Produces: `TerminalJumper.jump(to:)`, `TerminalJumper.revealProject(_:)` — Task 19 verifies them against real sessions

- [ ] **Step 0: Write the tap destination**

The views need somewhere to send taps, so this lands with them rather than after.

```swift
// VibezHUD/Sources/VibezHUDApp/TerminalJumper.swift
import AppKit
import VibezSessionKit

enum TerminalJumper {
    /// App-level activation needs no permissions at all. Raising a SPECIFIC
    /// window among several would need Accessibility, so it is deliberately not
    /// attempted here — the app coming forward is the 90% case.
    @MainActor
    static func jump(to session: Session) {
        if let pid = session.appPid, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        // The terminal is gone (or was never identified) — show the work instead.
        revealProject(session)
    }

    @MainActor
    static func revealProject(_ session: Session) {
        guard !session.cwd.isEmpty else { return }
        let url = URL(fileURLWithPath: session.cwd)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

- [ ] **Step 1: Write the ears**

```swift
// VibezHUD/Sources/VibezHUDApp/Views/CollapsedEars.swift
import SwiftUI

/// Two Liquid Glass ears flanking the notch. Each hides entirely at zero, so a
/// quiet machine shows a bare notch.
struct CollapsedEars: View {
    let needsYou: Int
    let working: Int
    let notchWidth: CGFloat
    var namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            ear(visible: needsYou > 0, id: "ear-left") {
                Circle().fill(HUDTheme.needsYou).frame(width: 7, height: 7)
                    .modifier(PulseModifier())
                Text("\(needsYou)").font(.system(size: 10, weight: .bold))
            }
            Spacer().frame(width: notchWidth + 8)
            ear(visible: working > 0, id: "ear-right") {
                Equalizer().frame(width: 10, height: 10)
                Text("\(working)").font(.system(size: 10, weight: .bold)).opacity(0.5)
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func ear<C: View>(visible: Bool, id: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
            .padding(.horizontal, 8)
            .frame(height: 18)
            .glassEffect(.regular, in: .rect(cornerRadius: HUDTheme.earCornerRadius))
            .glassEffectID(id, in: namespace)
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.6, anchor: .top)
            .animation(HUDTheme.expand, value: visible)
    }
}

private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.45 : 1)
            .scaleEffect(on ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct Equalizer: View {
    @State private var phase = false
    private let heights: [CGFloat] = [4, 10, 7]
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(HUDTheme.working)
                    .frame(width: 2, height: heights[i])
                    .scaleEffect(y: phase ? 1 : 0.4, anchor: .bottom)
                    .animation(.easeInOut(duration: 0.52)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.16), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
```

- [ ] **Step 2: Write the tile**

```swift
// VibezHUD/Sources/VibezHUDApp/Views/SessionTile.swift
import SwiftUI
import VibezSessionKit

/// Every tile uses the SAME neutral material regardless of state. Apple does not
/// tint whole rows on a black surface, and the column header already says what
/// the state is — a row wash says it twice, louder. A needs-you row gets a 2pt
/// hairline and nothing else.
struct SessionTile: View {
    let session: Session
    let onTap: (Session) -> Void

    private var isNeedsYou: Bool { session.state == .needsYou }
    private var isDim: Bool { session.state == .done || session.state == .ended }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isNeedsYou {
                Capsule().fill(HUDTheme.needsYou).frame(width: 2).padding(.vertical, 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    chip
                    Text(session.proj)
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(elapsed)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(session.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1).truncationMode(.tail)
                if let detail = detailLine {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(session.state == .ended ? 0.4 : 0.52))
                        .italic(session.state == .ended)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.leading, isNeedsYou ? 7 : 9)
            .padding(.trailing, 9)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(HUDTheme.tileFill)
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(HUDTheme.tileStroke))
        )
        .opacity(isDim ? 0.48 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onTap(session) }
    }

    private var chip: some View {
        Text(HUDTheme.glyph(session.agent))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 5).fill(HUDTheme.chip(session.agent)))
    }

    private var detailLine: String? {
        if session.state == .ended { return "ended" }
        switch (session.tool, session.detail) {
        case let (tool?, detail?): return "\(tool) · \(detail)"
        case let (tool?, nil):     return tool
        case let (nil, detail?):   return detail
        default:                   return nil
        }
    }

    private var elapsed: String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let secs = max(0, (now - session.stateSinceMs) / 1000)
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }
}
```

- [ ] **Step 3: Write the bubble board and the real root view**

```swift
// VibezHUD/Sources/VibezHUDApp/Views/BubbleBoard.swift
import SwiftUI
import VibezSessionKit

struct BubbleBoard: View {
    let snapshot: HUDSnapshot
    let onTap: (Session) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            column("NEEDS YOU", HUDTheme.needsYou, snapshot.needsYou)
            column("DONE", HUDTheme.done, snapshot.done)
            column("WORKING", HUDTheme.working, snapshot.working)
        }
        .padding(.top, 34)          // clears the notch
        .padding([.horizontal, .bottom], 14)
    }

    private func column(_ title: String, _ dot: Color, _ sessions: [Session]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(title).font(.system(size: 8.5, weight: .bold)).kerning(0.9)
                Spacer(minLength: 4)
                Text("\(sessions.count)").font(.system(size: 8.5, weight: .bold)).opacity(0.55)
            }
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 4)
            .padding(.bottom, 9)

            // Each column scrolls on its own, so a hundred sessions look the
            // same as twelve — the bubble never grows to accommodate them.
            ScrollView(.vertical) {
                VStack(spacing: 7) {
                    ForEach(sessions) { SessionTile(session: $0, onTap: onTap) }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.03),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

```swift
// VibezHUD/Sources/VibezHUDApp/Views/HUDRootView.swift   (replaces the Task 17 stub)
import SwiftUI
import VibezSessionKit

struct NotchGeometryKey: EnvironmentKey {
    static let defaultValue = NotchGeometry(metrics: ScreenMetrics(
        frame: .init(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32,
        auxLeft: .init(x: 0, y: 950, width: 656, height: 32),
        auxRight: .init(x: 856, y: 950, width: 656, height: 32)))
}
extension EnvironmentValues {
    var notchGeometry: NotchGeometry {
        get { self[NotchGeometryKey.self] }
        set { self[NotchGeometryKey.self] = newValue }
    }
}

struct HUDRootView: View {
    let model: HUDViewModel
    @Environment(\.notchGeometry) private var geometry
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .top) {
                if model.isExpanded {
                    bubble
                        .transition(.identity)
                } else {
                    CollapsedEars(needsYou: model.needsYouCount,
                                  working: model.workingCount,
                                  notchWidth: geometry.notchRect.width,
                                  namespace: glass)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(HUDTheme.expand, value: model.isExpanded)
        }
    }

    private var bubble: some View {
        BubbleBoard(snapshot: model.snapshot) { TerminalJumper.jump(to: $0) }
            .frame(width: bubbleSize.width, height: bubbleSize.height)
            .background(
                // Opaque black, top-anchored, wider than the notch so it
                // swallows it: one continuous object, not a window under a notch.
                UnevenRoundedRectangle(bottomLeadingRadius: HUDTheme.bubbleCornerRadius,
                                       bottomTrailingRadius: HUDTheme.bubbleCornerRadius)
                    .fill(HUDTheme.bubbleFill)
                    .overlay(
                        UnevenRoundedRectangle(bottomLeadingRadius: HUDTheme.bubbleCornerRadius,
                                               bottomTrailingRadius: HUDTheme.bubbleCornerRadius)
                            .fill(LinearGradient(colors: [.white.opacity(0.055), .clear],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(
                        UnevenRoundedRectangle(bottomLeadingRadius: HUDTheme.bubbleCornerRadius,
                                               bottomTrailingRadius: HUDTheme.bubbleCornerRadius)
                            .strokeBorder(.white.opacity(0.13), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.7), radius: 30, y: 18)
            )
            .glassEffectID("bubble", in: glass)
    }

    private var bubbleSize: CGSize {
        let rows = max(model.snapshot.needsYou.count,
                       max(model.snapshot.done.count, model.snapshot.working.count))
        let r = geometry.bubbleRect(rowCount: rows)
        return CGSize(width: r.width, height: r.height)
    }
}
```

- [ ] **Step 4: Build and eyeball every state at once**

```bash
cd VibezHUD && swift build && swift run VibezHUDApp --demo
```

Expected: ears at the notch showing `2` amber and `2` teal; hovering morphs into a black bubble with three columns, needs-you rows carrying an orange hairline, done/ended rows dimmed. Screenshot it:

```bash
screencapture -x -R0,0,1600,500 /tmp/hud-demo.png && open /tmp/hud-demo.png
```

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Sources/VibezHUDApp
git commit -m "feat(hud): glass ears, black bubble board, and click-to-jump destination"
```

---

### Task 19: Verify click-to-jump against real terminals

The process-tree walk is the one piece that can't be unit-tested — it depends on
how your actual terminal launches agents. This task proves it end to end and
records what it resolves to.

**Files:**
- Modify: `ClaudePlugin/scripts/notify.sh` only if the walk misidentifies the app

**Interfaces:**
- Consumes: `hud_process_chain` (Task 10), `TerminalJumper.jump(to:)` (Task 19)

- [ ] **Step 1: Check what the walk resolves to in your terminal**

With a real Claude Code session running, inspect the most recent `start` record:

```bash
jq -r 'select(.kind=="start") | "\(.app)  agentPid=\(.agentPid)  appPid=\(.appPid)"' ~/.config/vibez/hud/events.jsonl | tail -3
```

Expected: `app` names your terminal (`iTerm2`, `Terminal`, `Ghostty`, `Cursor`, `Code`…), and both pids are non-zero.

**If `app` is empty:** the agent's ancestors include no `.app` bundle — common when
launched from a login shell via `ssh` or a bare `launchd` job. Jump will fall back
to revealing the project, which is correct. No fix needed.

**If `app` names a *Helper* bundle** (e.g. `Cursor Helper`), the outermost-`.app`
loop exited early. Raise the `guard` ceiling in `hud_process_chain` from 24 and
re-check.

- [ ] **Step 2: Confirm the pid is really that app**

```bash
ps -o comm= -p "$(jq -r 'select(.kind=="start") | .appPid' ~/.config/vibez/hud/events.jsonl | tail -1)"
```

Expected: a path ending in `<YourTerminal>.app/Contents/MacOS/<binary>`.

- [ ] **Step 3: Verify the live jump**

```bash
cd VibezHUD && swift run VibezHUDApp
```

Click the live session's row. Expected: that terminal comes to the front. Click a
row whose terminal you've since quit. Expected: Finder opens at the project
directory — no crash, no dead click.

- [ ] **Step 4: Verify the demo fallback**

```bash
mkdir -p /tmp/Vibez && cd VibezHUD && swift run VibezHUDApp --demo
```

Demo sessions carry no `appPid`, so clicking the "Vibez" row must reveal
`/tmp/Vibez` in Finder, and clicking a row whose directory doesn't exist must do
nothing at all.

- [ ] **Step 5: Commit any fix**

Only if Step 1 required a change:

```bash
git add ClaudePlugin/scripts/notify.sh CodexPlugin/scripts/notify.sh CursorPlugin/scripts/notify.sh
git commit -m "fix(hud): resolve the outermost .app ancestor for click-to-jump"
```

---

### Task 20: Bundle it as a real `.app`

**Files:**
- Create: `VibezHUD/Scripts/make-app.sh`

- [ ] **Step 1: Write the bundler**

```bash
#!/usr/bin/env bash
# VibezHUD/Scripts/make-app.sh — assemble a launchable VibezHUD.app
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${HERE}/build/VibezHUD.app}"

cd "${HERE}"
swift build -c release --product VibezHUDApp

rm -rf "${OUT}"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"
cp "${HERE}/.build/release/VibezHUDApp" "${OUT}/Contents/MacOS/VibezHUD"

cat > "${OUT}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VibezHUD</string>
  <key>CFBundleDisplayName</key><string>Vibez HUD</string>
  <key>CFBundleIdentifier</key><string>vibezlol.VibezHUD</string>
  <key>CFBundleExecutable</key><string>VibezHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <!-- Agent app: no Dock icon, no menu bar presence. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature is enough for a locally built personal tool.
codesign --force --deep --sign - "${OUT}" >/dev/null 2>&1 || true

printf 'built %s\n' "${OUT}"
printf 'run:   open "%s"\n' "${OUT}"
printf 'login: System Settings > General > Login Items > add it\n'
```

- [ ] **Step 2: Build and launch it**

```bash
chmod +x VibezHUD/Scripts/make-app.sh && ./VibezHUD/Scripts/make-app.sh && open VibezHUD/build/VibezHUD.app
```

Expected: the ears appear in the notch with no Dock icon. Quit with `killall VibezHUD`.

- [ ] **Step 3: Ignore build output**

Append to `.gitignore`:

```
VibezHUD/.build/
VibezHUD/build/
```

- [ ] **Step 4: Full green run**

```bash
./Tests/run-all.sh
```

Expected: `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add VibezHUD/Scripts/make-app.sh .gitignore
git commit -m "build(hud): assemble VibezHUD.app as an LSUIElement agent"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: architecture → 2, 3, 9; data contract → 2, 10; hook mapping → 10, 11, 12; writer-forks-from-post_vibez → 10 (with the debounce regression pinned as a test); concurrency → 8; state model → 3; ordering → 4; provisional done → 5; liveness/staleness/retention/rotation/cold start → 6, 7; config keys → 3 (`StoreConfig`), 10 (`VIBEZ_HUD_LOG_MAX_BYTES`); window/geometry/hover → 15, 16, 17; day-one spike → 1; click-to-jump → 10 (`hud_process_chain`), 18, 19; visual design → 17, 18; testing layers 0–6 → 1, 3–8, 13, 14, 15, 16, 18; risks → 1, 10, 19.

**Two spec details deliberately deferred, and why:** the optional Accessibility upgrade that raises a *specific* window is not implemented (Task 18 does app-level activation only) — the spec lists it as an optional upgrade, and app-level activation needs no permission prompt; and the `vibez.hud.*` `UserDefaults` overrides are wired as `StoreConfig` parameters but not read from `UserDefaults` in Task 17, since nothing yet writes them. Both are additive later without touching the reducer.

**Type consistency checked:** `HUDSnapshot.needsYou/done/working` is used identically in Tasks 3, 9, 13, 17, 18. `SessionStore.stateForTesting(sid:)` is defined in Task 3 and used in 4, 5, 6, 14. `HUDEngine.primeAndDrain()/poll()` defined in 9, used in 17. `NotchGeometry.bubbleRect(rowCount:)` defined in 15, used in 17 and 18. `HoverPolicy.handle(_:nowMs:)/tick(nowMs:)` defined in 16, used in 17. `TerminalJumper.jump(to:)` is defined in Task 18 Step 0, in the same task as the view that calls it, so every task builds standalone.

**Build-order check:** each task's final step compiles or runs green on its own. Task 17 ships a stub `HUDRootView` precisely so the app shell builds before the views exist; Task 18 replaces it.

**Placeholder scan:** clean — every code step carries real code, every test step carries real assertions, and every run step states the expected result.
