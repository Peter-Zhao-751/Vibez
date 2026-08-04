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
