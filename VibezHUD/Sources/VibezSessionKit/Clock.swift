import Foundation

public protocol Clock: Sendable { var nowMs: Int64 { get } }

public struct SystemClock: Clock {
    public init() {}
    public var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
