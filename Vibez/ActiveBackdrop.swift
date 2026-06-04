//
//  ActiveBackdrop.swift
//  Vibez
//
//  Animated home-screen backdrop — soft accent orbs drifting like
//  floating bubbles while Vibez is armed; fades out when idle. Ported
//  1:1 from the reference design's ActiveBackdrop + vibez-float-a/b/c/d
//  keyframes, with one iOS-only addition: the bubbles parallax-shift
//  with the phone's physical tilt (CoreMotion). Bigger bubbles move
//  more, so the field reads as having depth.
//

import SwiftUI
import CoreMotion

// MARK: - Tilt source

/// Publishes the phone's tilt relative to how the user is currently
/// holding it, normalized to [-1, 1] per axis. The reference attitude is
/// captured on the first sample, then the baseline slowly creeps toward
/// the live attitude (a high-pass) so a sustained new hold becomes the
/// new neutral instead of pinning the bubbles at full deflection.
@Observable
final class MotionTilt {
    /// Tilt that saturates the parallax — ~29° off neutral.
    private static let maxAngle = 0.5
    /// Per-sample smoothing toward the raw reading (30 Hz → ~0.2 s lag).
    private static let smoothing = 0.15
    /// Per-sample baseline creep toward the current hold (30 Hz → ~7 s).
    private static let recentering = 0.005

    private let manager = CMMotionManager()
    private var reference: CMAttitude?
    private var baselineRoll = 0.0
    private var baselinePitch = 0.0

    /// Normalized left/right tilt (roll) in [-1, 1].
    private(set) var x = 0.0
    /// Normalized toward/away tilt (pitch) in [-1, 1].
    private(set) var y = 0.0

    func start() {
        // No-ops in the simulator (no motion hardware) — the bubbles
        // still drift, they just don't parallax.
        guard manager.isDeviceMotionAvailable,
              !manager.isDeviceMotionActive
        else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, _ in
            guard let motion else { return }
            // Delivered on the main queue (`to: .main`), so hopping to
            // the MainActor is an assertion, not a dispatch.
            MainActor.assumeIsolated {
                self?.ingest(motion)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
        baselineRoll = 0
        baselinePitch = 0
        x = 0
        y = 0
    }

    private func ingest(_ motion: CMDeviceMotion) {
        guard let reference else {
            reference = motion.attitude.copy() as? CMAttitude
            return
        }
        // CMAttitude.multiply mutates in place — work on a copy.
        guard let relative = motion.attitude.copy() as? CMAttitude else { return }
        relative.multiply(byInverseOf: reference)

        baselineRoll += (relative.roll - baselineRoll) * Self.recentering
        baselinePitch += (relative.pitch - baselinePitch) * Self.recentering

        let targetX = max(-1, min(1, (relative.roll - baselineRoll) / Self.maxAngle))
        let targetY = max(-1, min(1, (relative.pitch - baselinePitch) / Self.maxAngle))
        x += (targetX - x) * Self.smoothing
        y += (targetY - y) * Self.smoothing
    }
}

// MARK: - Float tracks (CSS @keyframes as data)

/// One drift loop — a `vibez-float-*` keyframe block. `dx`/`dy` are
/// percentages of the bubble's own size, exactly like CSS translate %.
private struct FloatTrack {
    let stops: [Double]
    let dx: [Double]
    let dy: [Double]
    let scale: [Double]

    /// Sample at `progress` ∈ [0, 1). CSS `ease-in-out` (cubic-bezier
    /// 0.42, 0, 0.58, 1 — which is exactly `UnitCurve.easeInOut`)
    /// applies per keyframe segment, not across the whole loop.
    func sample(at progress: Double) -> (dx: Double, dy: Double, scale: Double) {
        var i = 0
        while i + 2 < stops.count && progress >= stops[i + 1] { i += 1 }
        let span = stops[i + 1] - stops[i]
        let local = span > 0 ? min(1, max(0, (progress - stops[i]) / span)) : 0
        let t = UnitCurve.easeInOut.value(at: local)
        return (
            dx[i] + (dx[i + 1] - dx[i]) * t,
            dy[i] + (dy[i + 1] - dy[i]) * t,
            scale[i] + (scale[i + 1] - scale[i]) * t
        )
    }

    static let a = FloatTrack(
        stops: [0, 0.2, 0.4, 0.6, 0.8, 1],
        dx: [0, 70, 120, 45, -35, 0],
        dy: [0, 35, -20, 90, 40, 0],
        scale: [1, 1.15, 0.9, 1.1, 0.85, 1]
    )
    static let b = FloatTrack(
        stops: [0, 0.25, 0.5, 0.75, 1],
        dx: [0, -90, -50, 40, 0],
        dy: [0, 50, -70, -30, 0],
        scale: [1.05, 0.86, 1.2, 0.95, 1.05]
    )
    static let c = FloatTrack(
        stops: [0, 0.2, 0.45, 0.7, 1],
        dx: [0, 60, -70, -100, 0],
        dy: [0, 60, 80, -20, 0],
        scale: [0.95, 1.18, 0.82, 1.12, 0.95]
    )
    static let d = FloatTrack(
        stops: [0, 0.3, 0.55, 0.8, 1],
        dx: [0, -80, 50, 90, 0],
        dy: [0, -50, -90, 30, 0],
        scale: [1, 1.22, 0.88, 1.05, 1]
    )
}

// MARK: - Bubble specs (reference BUBBLES table)

private struct BubbleSpec {
    /// Top-left corner as fractions of the container (CSS top/left %).
    let top: Double
    let left: Double
    /// Diameter as a fraction of the container width.
    let size: Double
    let track: FloatTrack
    let duration: Double
    /// Peak gradient opacity (the two-digit hex suffix in the CSS).
    let alpha: Double
    let blur: Double
}

private let bubbleSpecs: [BubbleSpec] = [
    BubbleSpec(top: -0.14, left: -0.10, size: 1.04, track: .a, duration: 18, alpha: 0x4a / 255.0, blur: 14),
    BubbleSpec(top: 0.06, left: 0.58, size: 0.92, track: .b, duration: 22, alpha: 0x42 / 255.0, blur: 16),
    BubbleSpec(top: 0.34, left: 0.14, size: 1.00, track: .c, duration: 26, alpha: 0x36 / 255.0, blur: 18),
    BubbleSpec(top: 0.52, left: 0.60, size: 0.80, track: .d, duration: 20, alpha: 0x3c / 255.0, blur: 16),
    BubbleSpec(top: 0.22, left: 0.36, size: 0.60, track: .a, duration: 24, alpha: 0x34 / 255.0, blur: 12),
    BubbleSpec(top: 0.70, left: 0.24, size: 0.68, track: .b, duration: 28, alpha: 0x30 / 255.0, blur: 18),
]

// MARK: - Backdrop

struct ActiveBackdrop: View {
    let accent: Color
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var tilt = MotionTilt()

    /// Parallax reach (in points) of the biggest bubble at full tilt.
    private static let maxParallax: CGFloat = 30
    /// The largest `size` in `bubbleSpecs` — parallax scales against it.
    private static let maxBubbleSize = 1.04

    private var motionWanted: Bool {
        active && scenePhase == .active && !reduceMotion
    }

    var body: some View {
        GeometryReader { proxy in
            // One clock drives all six bubbles. Pausing while faded out
            // stops rendering only — progress derives from wall time, so
            // on re-arm the drift resumes exactly where CSS would be.
            TimelineView(.animation(paused: !active || reduceMotion)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .topLeading) {
                    ForEach(bubbleSpecs.indices, id: \.self) { i in
                        bubble(bubbleSpecs[i], index: i, in: proxy.size, now: now)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .clipped()
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 1.1), value: active)
        .allowsHitTesting(false)
        .onChange(of: motionWanted, initial: true) { _, wanted in
            if wanted { tilt.start() } else { tilt.stop() }
        }
        .onDisappear { tilt.stop() }
    }

    @ViewBuilder
    private func bubble(
        _ spec: BubbleSpec,
        index: Int,
        in area: CGSize,
        now: TimeInterval
    ) -> some View {
        let size = area.width * spec.size
        // CSS `animation-delay: -i*1.7s` — bubble i starts 1.7·i s into
        // its loop.
        let progress = ((now + Double(index) * 1.7) / spec.duration)
            .truncatingRemainder(dividingBy: 1)
        let f = reduceMotion
            ? (dx: 0.0, dy: 0.0, scale: 1.0)
            : spec.track.sample(at: progress)
        // Background layer: shift against the tilt; bigger bubbles sit
        // "closer" and move more.
        let strength = Self.maxParallax * spec.size / Self.maxBubbleSize
        let px = -CGFloat(tilt.x) * strength
        let py = -CGFloat(tilt.y) * strength

        Circle()
            // CSS: radial-gradient(circle, accent 0%, transparent 70%).
            // The implicit gradient radius is farthest-corner = size·√2/2,
            // so transparent lands at 0.7·0.707 ≈ 0.495 of the diameter.
            .fill(RadialGradient(
                stops: [
                    .init(color: accent.opacity(spec.alpha), location: 0),
                    .init(color: .clear, location: 0.7),
                ],
                center: .center,
                startRadius: 0,
                endRadius: size * 0.707
            ))
            .frame(width: size, height: size)
            .blur(radius: spec.blur)
            .scaleEffect(f.scale)
            .position(
                x: area.width * spec.left + size / 2 + size * f.dx / 100 + px,
                y: area.height * spec.top + size / 2 + size * f.dy / 100 + py
            )
    }
}

#if DEBUG
#Preview("ActiveBackdrop · claude") {
    ZStack {
        Color(hex: 0x0c0d12).ignoresSafeArea()
        ActiveBackdrop(accent: Theme.claudeOrange, active: true)
            .ignoresSafeArea()
    }
}
#endif
