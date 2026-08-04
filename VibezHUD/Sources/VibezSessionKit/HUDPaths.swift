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
