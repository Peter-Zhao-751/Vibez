import CoreGraphics
import Foundation

/// Where the pointer was, and when. Plain values so the whole predictor is
/// testable with made-up motion.
public struct PointerSample: Sendable, Equatable {
    public var tMs: Int64
    public var point: CGPoint
    public init(tMs: Int64, point: CGPoint) { self.tMs = tMs; self.point = point }
}

/// Velocity and acceleration of the pointer, from the sample stream the hover
/// poll already produces.
///
/// This exists to answer one question early: is the pointer LEAVING, or is it
/// moving around inside the HUD? Containment cannot tell those apart — by the
/// time the pointer is outside, it has already been outside for a frame, and
/// then the close delay starts. Extrapolating the motion lets the collapse begin
/// while the pointer is still on the island, which is what "leaving feels
/// delayed" was asking for.
public struct PointerKinematics: Sendable, Equatable {
    /// Long enough for a stable second derivative, short enough that a direction
    /// change is not averaged away. At 20ms sampling this is 140ms of history.
    public static let capacity = 8
    /// Samples used for one velocity estimate. Three deltas, lightly averaged:
    /// one delta is jittery, and more than a handful lags a reversal.
    public static let velocityWindow = 4

    public private(set) var samples: [PointerSample] = []

    public init() {}

    public mutating func record(_ point: CGPoint, tMs: Int64) {
        // A repeated timestamp would divide by zero; a still pointer is a real
        // reading, so keep the sample but never let dt be 0.
        if let last = samples.last, tMs <= last.tMs { samples.removeLast() }
        samples.append(PointerSample(tMs: tMs, point: point))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// Drop the history. Used when the pointer teleports (a warp, a space
    /// switch) or when the HUD opens, so stale motion cannot immediately close
    /// what just opened.
    public mutating func reset() { samples.removeAll(keepingCapacity: true) }

    public var latest: CGPoint? { samples.last?.point }

    /// Points per second, averaged over the last few deltas.
    public var velocity: CGVector { Self.velocity(of: samples.suffix(Self.velocityWindow)) }

    /// Points per second squared, from the difference between the newer half of
    /// the window and the older half.
    public var acceleration: CGVector {
        let window = Array(samples.suffix(Self.velocityWindow * 2))
        guard window.count >= 4 else { return .zero }
        let mid = window.count / 2
        let older = Array(window[..<mid]), newer = Array(window[mid...])
        let v0 = Self.velocity(of: older), v1 = Self.velocity(of: newer)
        // Time between the two halves' midpoints.
        let t0 = Double(older[0].tMs + older[older.count - 1].tMs) / 2
        let t1 = Double(newer[0].tMs + newer[newer.count - 1].tMs) / 2
        let dt = (t1 - t0) / 1000
        guard dt > 0.001 else { return .zero }
        return CGVector(dx: (v1.dx - v0.dx) / dt, dy: (v1.dy - v0.dy) / dt)
    }

    public var speed: CGFloat {
        let v = velocity
        return (v.dx * v.dx + v.dy * v.dy).squareRoot()
    }

    /// Where the pointer will be in `afterMs`, if it keeps doing what it is
    /// doing: `p + v·τ + ½a·τ²`.
    ///
    /// Acceleration is clamped in effect by the short window it comes from — a
    /// hand cannot sustain a large second derivative — but the caller still
    /// treats this as a hint, never as a fact. It is only ever used to start a
    /// collapse EARLY, and an early collapse is cancelled by the very next
    /// sample that lands back inside.
    public func projected(afterMs: Double) -> CGPoint? {
        guard let p = samples.last?.point, samples.count >= 2 else { return nil }
        let t = afterMs / 1000
        let v = velocity, a = acceleration
        return CGPoint(x: p.x + v.dx * t + 0.5 * a.dx * t * t,
                       y: p.y + v.dy * t + 0.5 * a.dy * t * t)
    }

    private static func velocity(of window: some Collection<PointerSample>) -> CGVector {
        let s = Array(window)
        guard s.count >= 2 else { return .zero }
        var dx: CGFloat = 0, dy: CGFloat = 0, n = 0
        for i in 1..<s.count {
            let dt = Double(s[i].tMs - s[i - 1].tMs) / 1000
            guard dt > 0 else { continue }
            dx += (s[i].point.x - s[i - 1].point.x) / dt
            dy += (s[i].point.y - s[i - 1].point.y) / dt
            n += 1
        }
        guard n > 0 else { return .zero }
        return CGVector(dx: dx / CGFloat(n), dy: dy / CGFloat(n))
    }
}

/// Turns kinematics into a hover decision. Pure, and deliberately separate from
/// `HoverPolicy`: this decides WHETHER the pointer is leaving, the policy
/// decides what to do about it and when. The policy is untouched.
public enum ExitPredictor {
    public struct Decision: Sendable, Equatable {
        /// Report `.exited` to the hysteresis this sample.
        public var exit: Bool
        /// ...and do not wait out the close delay: the pointer is already gone
        /// and still accelerating away.
        public var immediate: Bool
        /// True when `exit` was decided while the pointer was still INSIDE — the
        /// early call, the one that can be wrong.
        public var predicted: Bool
        public var projected: CGPoint?
        public var reason: String
    }

    /// - Parameters:
    ///   - zone: the active hover zone (island + forgiveness), i.e. exactly what
    ///     containment routing uses, so the two can never disagree about where
    ///     the boundary is.
    public static func decide(pointer: CGPoint,
                              kinematics: PointerKinematics,
                              zone: CGRect,
                              isExpanded: Bool,
                              tuning: HoverTuning) -> Decision {
        let inside = zone.contains(pointer)
        let projected = kinematics.projected(afterMs: tuning.projectionMs)
        let v = kinematics.velocity
        let speed = kinematics.speed

        guard isExpanded else {
            return Decision(exit: !inside, immediate: false, predicted: false,
                            projected: projected, reason: inside ? "inside" : "outside")
        }

        if inside {
            // The early call. Require BOTH that the extrapolated point lands well
            // clear of the boundary and that the velocity actually points that
            // way — a stale projection from a pointer that has already reversed
            // must not fire.
            guard let p = projected else {
                return Decision(exit: false, immediate: false, predicted: false,
                                projected: nil, reason: "inside/no-projection")
            }
            let escape = distanceOutside(p, zone)
            if escape >= tuning.exitMarginPt, pointsOutward(v, from: p, zone: zone) {
                return Decision(exit: true, immediate: false, predicted: true,
                                projected: p,
                                reason: String(format: "predict escape=%.0fpt speed=%.0f", escape, speed))
            }
            return Decision(exit: false, immediate: false, predicted: false,
                            projected: p,
                            reason: String(format: "inside escape=%.0fpt", escape))
        }

        // Genuinely outside. Fast and still heading away means there is nothing
        // left to reconsider, so skip the grace period entirely.
        let stillLeaving = projected.map { distanceOutside($0, zone) >= distanceOutside(pointer, zone) } ?? true
        if speed >= tuning.fastExitSpeed, stillLeaving {
            return Decision(exit: true, immediate: true, predicted: false, projected: projected,
                            reason: String(format: "fast-exit speed=%.0f", speed))
        }
        return Decision(exit: true, immediate: false, predicted: false, projected: projected,
                        reason: String(format: "outside speed=%.0f", speed))
    }

    /// How far `p` is from the rect, 0 when inside.
    public static func distanceOutside(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Is the velocity pointing away from the zone, at the projected point?
    ///
    /// The outward direction is taken at the projection, where it is
    /// unambiguous: the vector from the nearest point ON the rect to the
    /// projected point IS the outward normal there.
    public static func pointsOutward(_ v: CGVector, from p: CGPoint, zone: CGRect) -> Bool {
        let nearest = CGPoint(x: min(max(p.x, zone.minX), zone.maxX),
                              y: min(max(p.y, zone.minY), zone.maxY))
        let outward = CGVector(dx: p.x - nearest.x, dy: p.y - nearest.y)
        return v.dx * outward.dx + v.dy * outward.dy > 0
    }
}
