import Foundation

public protocol LivenessProbe: Sendable {
    /// `startedAt` is the `ps -o lstart=` string recorded when the session began.
    /// Comparing it defends against macOS PID recycling.
    func isAlive(pid: Int32, startedAt: String?) -> Bool
}

public struct POSIXLivenessProbe: LivenessProbe {
    /// A process's start time is IMMUTABLE for the life of that pid, so `ps` is
    /// run at most once per pid and the answer is memoized. Without this, every
    /// `SessionStore.snapshot()` forked a `ps` per live session — and the panel
    /// snapshots at 5 Hz on the main actor. Six sessions meant ~30 fork/exec a
    /// second and ~30 ms of blocking per 100 ms tick: the hover clock drifted
    /// and a login-item app burned CPU for as long as it ran.
    private final class StartTimeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var byPid: [Int32: String] = [:]
        private var runs = 0

        func startTime(of pid: Int32) -> String? {
            lock.lock()
            if let hit = byPid[pid] { lock.unlock(); return hit }
            lock.unlock()
            // `ps` runs OUTSIDE the lock — it is the slow part, and a duplicate
            // run under contention is harmless: the answer is the same either way.
            let fresh = POSIXLivenessProbe.readStartTime(of: pid)
            lock.lock()
            runs += 1
            if let fresh { byPid[pid] = fresh }   // a failed read is never cached
            lock.unlock()
            return fresh
        }

        func forget(_ pid: Int32) {
            lock.lock(); byPid.removeValue(forKey: pid); lock.unlock()
        }

        var runCount: Int { lock.lock(); defer { lock.unlock() }; return runs }

        func cached(_ pid: Int32) -> String? {
            lock.lock(); defer { lock.unlock() }; return byPid[pid]
        }
    }

    private let cache = StartTimeCache()

    public init() {}

    public func isAlive(pid: Int32, startedAt: String?) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): 0 = alive and ours, EPERM = alive but another user's.
        // This stays live on every call — it is a cheap syscall (no fork) and it
        // is the thing that actually detects death.
        if kill(pid, 0) != 0 && errno != EPERM {
            // Evict on death so a RECYCLED pid re-probes: the memo is only sound
            // while the pid keeps identifying the same process, and the
            // start-time comparison is what catches the reuse.
            //
            // The residual hole is NEW — re-running `ps` every call, as this
            // used to, had none. If a pid dies AND is recycled entirely between
            // two polls (200 ms), no call ever observes the death, the stale
            // memo matches the recorded start time, and the row resurrects for
            // good: SessionStore.resolve() never falls back to the staleness
            // path while agentPid is non-nil. Accepted deliberately — macOS
            // hands out pids sequentially through a five-digit space, so that
            // needs on the order of 500k forks a second.
            cache.forget(pid)
            return false
        }
        guard let want = startedAt, !want.isEmpty else { return true }
        guard let got = cache.startTime(of: pid) else { return false }
        return got == want
    }

    /// Test seam: how many times this probe has actually shelled out to `ps`.
    /// Memoization means this must stay flat across repeated polls of a live pid.
    var psRunCount: Int { cache.runCount }

    /// Test seam: the memoized start time for `pid`, or nil once it was evicted.
    func cachedStartTime(of pid: Int32) -> String? { cache.cached(pid) }

    static func readStartTime(of pid: Int32) -> String? {
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
