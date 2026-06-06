//
//  Mascots.swift
//  Vibez
//
//  The pixel critter (Claude) mascot, translated from the reference
//  design's inline SVG. Breathes when listening, sleeps when not, and
//  randomly cycles eye expressions. The Codex cloud-bot vector stays
//  deleted — the Codex logo is a PNG asset (codex.imageset) used on
//  the blocking surfaces (BlockedOverlay + shield card); everything
//  else in the app stays Claude-themed.
//

import SwiftUI

// MARK: - Zzz (sleeping z's that float up and fade)
//
// Three monospaced z characters, each on a 2.6 s cycle, staggered by
// 0.35 s so they trail. During the cycle the z fades in (0–30 %),
// fades out (30–100 %), drifts up 14 pt, and scales from 0.6 to 1.1.

struct Zzz: View {
    let color: Color
    /// Anchor in mascot-viewBox coordinates (matches the SVG x/y).
    let originX: CGFloat
    let originY: CGFloat
    /// One viewBox unit in points (size / viewBoxWidth).
    let unit: CGFloat

    private let period: Double = 2.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                puff(at: t, delay: 0.0,  fontUnit: 10, dx: 0,  dy: 0)
                puff(at: t, delay: 0.35, fontUnit: 8,  dx: 8,  dy: -8)
                puff(at: t, delay: 0.70, fontUnit: 6,  dx: 14, dy: -14)
            }
        }
    }

    @ViewBuilder
    private func puff(at t: TimeInterval, delay: Double, fontUnit: CGFloat, dx: CGFloat, dy: CGFloat) -> some View {
        let raw = ((t - delay) / period).truncatingRemainder(dividingBy: 1.0)
        let p = raw < 0 ? raw + 1 : raw
        // Opacity rises 0→1 over the first 30 %, falls 1→0 over the rest.
        let opacity = p < 0.3 ? p / 0.3 : max(0, 1 - (p - 0.3) / 0.7)
        let driftY = -14.0 * p
        let scale = 0.6 + 0.5 * p

        Text("z")
            .font(.system(size: fontUnit * unit, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .bottomLeading)
            .offset(
                x: (originX + dx) * unit,
                y: (originY + dy) * unit + CGFloat(driftY) * unit
            )
    }
}

// MARK: - Expression cycler

private enum Expression { case open, blink, squint }

private struct ExpressionCycler: ViewModifier {
    let listening: Bool
    @Binding var expression: Expression
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task(id: listening) {
                if !listening {
                    expression = .open
                    return
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64.random(in: 1_500_000_000...5_000_000_000))
                    if Task.isCancelled { break }
                    let next: Expression = Double.random(in: 0...1) < 0.65 ? .blink : .squint
                    expression = next
                    let hold: UInt64 = next == .blink ? 140_000_000 : 600_000_000
                    try? await Task.sleep(nanoseconds: hold)
                    if Task.isCancelled { break }
                    expression = .open
                }
            }
    }
}

// MARK: - Body bob (breathe / sleep-bob)

private struct BodyBob: ViewModifier {
    let listening: Bool
    /// `animate == false` freezes the breathe/sleep-bob loop entirely —
    /// the reference home screen renders the hero with `animate={false}`
    /// (only the eye-expression cycler keeps running).
    var animate: Bool = true
    @State private var phase: Double = 0

    func body(content: Content) -> some View {
        let scale: Double = !animate ? 1.0 : listening
            ? 1.0 + 0.04 * sin(phase)
            : 1.0 - 0.02 * sin(phase)
        let yOffset: Double = !animate ? 0 : listening
            ? -1 * sin(phase)
            : 2 * sin(phase)
        return content
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: yOffset)
            .onAppear { if animate { startLoop() } }
            .onChange(of: listening) { _, _ in if animate { startLoop() } }
    }

    private func startLoop() {
        let period: Double = listening ? 2.4 : 3.6
        withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
            phase = .pi
        }
    }
}

// MARK: - Claude — pixel critter

struct ClaudeMascot: View {
    let listening: Bool
    let size: CGFloat
    var focused: Bool = false
    var animate: Bool = true
    @State private var expression: Expression = .open

    private let bodyColor = Theme.claudeOrange
    private let bodyShade = Theme.claudeDeep
    private let dark = Color(hex: 0x1a0e08)

    var body: some View {
        let h = size * 0.9 // viewBox 100×90
        let unit = size / 100
        ZStack(alignment: .topLeading) {
            ClaudeBodyShape()
                .fill(bodyColor)
                .frame(width: size, height: h)
            // Bottom shadow band
//            Rectangle()
//                .fill(bodyShade.opacity(0.35))
//                .frame(width: size * 0.84, height: size * 0.06)
//                .offset(x: size * 0.08, y: size * 0.58)
            // Eyes
            ClaudeEyes(expression: focused ? .squint : (listening ? expression : .blink), color: dark)
                .frame(width: size, height: h)
            // Sleeping z's
            if !listening {
                Zzz(color: bodyShade, originX: 84, originY: 20, unit: unit)
                    .frame(width: size, height: h, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: h, alignment: .topLeading)
        .modifier(ExpressionCycler(listening: listening && !focused, expression: $expression))
        .modifier(BodyBob(listening: listening, animate: animate))
    }
}

private struct ClaudeEyes: View {
    let expression: Expression
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 100
            ZStack(alignment: .topLeading) {
                eye(at: 22 * s, scale: s)
                eye(at: 66 * s, scale: s)
            }
        }
    }

    @ViewBuilder
    private func eye(at xLeft: CGFloat, scale s: CGFloat) -> some View {
        switch expression {
        case .open:
            Rectangle()
                .fill(color)
                .frame(width: 12 * s, height: 14 * s)
                .offset(x: xLeft, y: 28 * s)
        case .blink:
            Rectangle()
                .fill(color)
                .frame(width: 12 * s, height: 3 * s)
                .offset(x: xLeft, y: 34 * s)
        case .squint:
            // Chevron: outer eyes squint inward.
            // Left eye points right (>), right eye points left (<).
            let isLeftEye = xLeft < 50 * s
            ChevronShape(pointsRight: isLeftEye)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round, lineJoin: .round))
                .frame(width: 10 * s, height: 14 * s)
                .offset(x: xLeft + s, y: 28 * s)
        }
    }
}

private struct ChevronShape: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsRight {
            // ">": top-left → middle-right → bottom-left
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height / 2))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
        } else {
            // "<": top-right → middle-left → bottom-right
            p.move(to: CGPoint(x: rect.width, y: 0))
            p.addLine(to: CGPoint(x: 0, y: rect.height / 2))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        }
        return p
    }
}

#if DEBUG
#Preview("Mascot · focused") {
    HStack(spacing: 28) {
        VStack { ClaudeMascot(listening: true, size: 110); Text("listening").font(.caption2) }
        VStack { ClaudeMascot(listening: true, size: 110, focused: true); Text("focused").font(.caption2) }
        VStack { ClaudeMascot(listening: false, size: 110); Text("sleeping").font(.caption2) }
    }
    .padding()
    .preferredColorScheme(.dark)
}
#endif
