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
