import Foundation

public struct StoreConfig: Sendable {
    public var stopGraceMs: Int64
    public var retentionMs: Int64
    public var staleMs: Int64

    public init(stopGraceMs: Int64 = 3_000,
                retentionMs: Int64 = 5 * 60 * 1_000,
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
    /// sid -> evictedAtMs. A remote doc can outlive local retention by up to
    /// staleMs (server keeps needs-input/replied alive for staleMs; local
    /// retention is only 5 min) — without this, evicting a sid re-opens the
    /// "local wins" dedupe and a stale remote row resurrects as a phantom.
    private var tombstones: [String: Int64] = [:]
    private let config: StoreConfig
    private let clock: any Clock
    private let liveness: any LivenessProbe

    public init(config: StoreConfig = StoreConfig(),
                clock: any Clock = SystemClock(),
                liveness: any LivenessProbe = POSIXLivenessProbe()) {
        self.config = config; self.clock = clock; self.liveness = liveness
    }

    public func apply(_ e: HUDEvent) {
        // A resumed session re-enters `entries` regardless; clearing the
        // tombstone here is hygiene, not correctness.
        tombstones.removeValue(forKey: e.sid)
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
        case .start:
            // A fresh start on a FINISHED session is a resume — reset to
            // idle so the row doesn't show "ended"/"done" until the first
            // prompt. Live states (working/needsYou) are untouched: a
            // start record there is a replay/rotation artifact.
            if entry.session.state == .ended || entry.session.state == .done {
                setState(&entry, .idle, at: e.ts)
            }
        case .prompt, .tool: setState(&entry, .working, at: e.ts)
        case .needsInput:    setState(&entry, .needsYou, at: e.ts)
        case .end:           setState(&entry, .ended, at: e.ts)
        case .done:
            // Already-committed done: a repeated Stop refreshes recency
            // only. Re-arming the grace would revert the display for 3s.
            if entry.session.state != .done { entry.pendingDoneAtMs = e.ts }
        }
        entries[e.sid] = entry
    }

    public func snapshot(remote: [Session] = []) -> HUDSnapshot {
        let now = clock.nowMs
        commitPendingDones(now: now)
        var needsYou: [Session] = [], done: [Session] = [], working: [Session] = []

        // Prune expired tombstones first — they must not leak forever.
        for (sid, evictedAtMs) in tombstones where now - evictedAtMs > config.staleMs {
            tombstones.removeValue(forKey: sid)
        }

        var evicted: [String] = []
        for (sid, entry) in entries {
            guard var s = resolve(entry, now: now) else {
                // resolve() returns nil ONLY for retention-pruned done/ended
                // rows — evict, or a long-lived HUD accumulates one Entry
                // per sid forever. Tombstone it: the server's event log can
                // still hold a needs-input/replied doc for this sid for up
                // to staleMs after local retention has already dropped it.
                evicted.append(sid)
                continue
            }
            s.detail = s.detail?.isEmpty == true ? nil : s.detail
            switch s.state {
            case .needsYou: needsYou.append(s)
            case .working:  working.append(s)
            case .done, .ended: done.append(s)
            case .idle: continue
            }
        }
        for sid in evicted {
            entries.removeValue(forKey: sid)
            tombstones[sid] = now
        }

        // Remote rows — server-derived sessions from OTHER machines,
        // pre-resolved by RemoteReducer. Local wins: a sid the local log
        // already knows (or JUST evicted — see tombstones above) is dropped
        // (the local reducer is strictly richer, and every local push
        // echoes back through the server log).
        for var s in remote where entries[s.sid] == nil && tombstones[s.sid] == nil {
            s.detail = s.detail?.isEmpty == true ? nil : s.detail
            switch s.state {
            case .needsYou: needsYou.append(s)
            case .working:  working.append(s)
            case .done, .ended: done.append(s)
            case .idle: continue
            }
        }

        // Every sort is a TOTAL order: `entries` is a dictionary, so the input
        // arrives in an arbitrary order, and Swift's sort is not stable. Without
        // the `sid` tiebreaker two rows sharing a millisecond could swap places
        // on every poll — a panel that visibly shuffles while nothing happened.
        //
        // Longest wait first — the most urgent thing sits at the top.
        needsYou.sort(by: Self.byWaitThenSid)
        // Most recent activity first for the other two.
        working.sort(by: Self.byRecencyThenSid)
        done.sort(by: Self.byRecencyThenSid)
        return HUDSnapshot(needsYou: needsYou, done: done, working: working)
    }

    private static func byWaitThenSid(_ a: Session, _ b: Session) -> Bool {
        a.stateSinceMs == b.stateSinceMs ? a.sid < b.sid : a.stateSinceMs < b.stateSinceMs
    }

    private static func byRecencyThenSid(_ a: Session, _ b: Session) -> Bool {
        a.lastActivityMs == b.lastActivityMs ? a.sid < b.sid : a.lastActivityMs > b.lastActivityMs
    }

    /// Test seam — the raw resolved state for one session, ignoring column grouping.
    public func stateForTesting(sid: String) -> SessionState? {
        commitPendingDones(now: clock.nowMs)
        guard let entry = entries[sid] else { return nil }
        return resolve(entry, now: clock.nowMs, ignoringRetention: true)?.state
    }

    /// Commit provisional dones whose grace window has elapsed, INTO the
    /// stored entry. Persisting the commit is what makes done sticky: a
    /// later duplicate `done` finds state == .done and leaves it alone,
    /// instead of re-opening the grace window and flashing the row back
    /// to its pre-done state.
    private func commitPendingDones(now: Int64) {
        for (sid, var entry) in entries {
            guard let pending = entry.pendingDoneAtMs,
                  now - pending >= config.stopGraceMs else { continue }
            entry.session.state = .done
            entry.session.stateSinceMs = pending
            entry.pendingDoneAtMs = nil
            entries[sid] = entry
        }
    }

    // MARK: - resolution

    private func resolve(_ entry: Entry, now: Int64, ignoringRetention: Bool = false) -> Session? {
        var s = entry.session

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
