//
//  Mascots.swift
//  Vibez
//
//  Pixel critter (Claude) and cloud-bot (Codex), translated from the
//  reference design's inline SVG. Both breathe when listening, sleep
//  when not, and randomly cycle eye expressions.
//

import SwiftUI

// MARK: - Public API

struct MascotForAgent: View {
    let agent: Agent
    let listening: Bool
    let size: CGFloat
    var gap: CGFloat = 6

    var body: some View {
        switch agent {
        case .claude:
            ClaudeMascot(listening: listening, size: size)
        case .codex:
            CodexMascot(listening: listening, size: size)
        case .both:
            HStack(alignment: .bottom, spacing: gap) {
                ClaudeMascot(listening: listening, size: size * 0.78)
                CodexMascot(listening: listening, size: size * 0.78)
            }
        }
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
    @State private var phase: Double = 0

    func body(content: Content) -> some View {
        let scale: Double = listening
            ? 1.0 + 0.04 * sin(phase)
            : 1.0 - 0.02 * sin(phase)
        let yOffset: Double = listening
            ? -1 * sin(phase)
            : 2 * sin(phase)
        return content
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: yOffset)
            .onAppear { startLoop() }
            .onChange(of: listening) { _, _ in startLoop() }
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
    @State private var expression: Expression = .open

    private let bodyColor = Theme.claudeOrange
    private let bodyShade = Theme.claudeDeep
    private let dark = Color(hex: 0x1a0e08)

    var body: some View {
        let h = size * 0.9 // viewBox 100×90
        ZStack(alignment: .topLeading) {
            ClaudeBodyShape()
                .fill(bodyColor)
                .frame(width: size, height: h)
            // Bottom shadow band
            Rectangle()
                .fill(bodyShade.opacity(0.35))
                .frame(width: size * 0.72, height: size * 0.06)
                .offset(x: size * 0.14, y: size * 0.58)
            // Eyes
            ClaudeEyes(expression: listening ? expression : .blink, color: dark)
                .frame(width: size, height: h)
        }
        .frame(width: size, height: h, alignment: .topLeading)
        .modifier(ExpressionCycler(listening: listening, expression: $expression))
        .modifier(BodyBob(listening: listening))
    }
}

private struct ClaudeBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 100
        var p = Path()
        // main body
        p.addRect(CGRect(x: 14 * s, y: 6 * s, width: 72 * s, height: 58 * s))
        // side wings
        p.addRect(CGRect(x: 6 * s,  y: 22 * s, width: 8 * s,  height: 22 * s))
        p.addRect(CGRect(x: 86 * s, y: 22 * s, width: 8 * s,  height: 22 * s))
        // 4 legs
        for x in [14.0, 30.0, 58.0, 74.0] {
            p.addRect(CGRect(x: x * s, y: 64 * s, width: 12 * s, height: 22 * s))
        }
        return p
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

// MARK: - Codex — cloud bot

struct CodexMascot: View {
    let listening: Bool
    let size: CGFloat
    @State private var expression: Expression = .open
    @State private var cursorOn: Bool = true

    private let blue = Theme.codexBlue
    private let blueLight = Color(hex: 0xaab8ee)
    private let blueDeep = Theme.codexDeep
    private let screenBg = Color(hex: 0x272a4a)
    private let screenStroke = Color(hex: 0x1c1f3d)
    private let eyeColor = Color(hex: 0x9af0d8)

    var body: some View {
        // Reference viewBox is 110×130
        let w = size
        let h = size * 130.0 / 110.0
        ZStack(alignment: .topLeading) {
            // Cloud head (flat bottom)
            CodexHeadShape()
                .fill(LinearGradient(
                    colors: [blueLight, blue],
                    startPoint: UnitPoint(x: 0.4, y: 0.35),
                    endPoint: UnitPoint(x: 0.9, y: 1.0)
                ))
                .frame(width: w, height: h)
            CodexHeadShape()
                .stroke(blueDeep.opacity(0.55), lineWidth: max(1, w / 110 * 1.2))
                .frame(width: w, height: h)
            // Underside shadow where head meets neck
            Rectangle()
                .fill(blueDeep.opacity(0.22))
                .frame(width: w * 94 / 110, height: h * 4 / 130)
                .offset(x: w * 8 / 110, y: h * 66 / 130)

            // Face screen
            RoundedRectangle(cornerRadius: w * 8 / 110, style: .continuous)
                .fill(screenBg)
                .frame(width: w * 58 / 110, height: h * 32 / 130)
                .offset(x: w * 26 / 110, y: h * 34 / 130)
            RoundedRectangle(cornerRadius: w * 8 / 110, style: .continuous)
                .stroke(screenStroke, lineWidth: max(1, w / 110 * 1.4))
                .frame(width: w * 58 / 110, height: h * 32 / 130)
                .offset(x: w * 26 / 110, y: h * 34 / 130)

            // Eyes
            CodexEyes(
                expression: listening ? expression : .open, // arches when sleeping too
                color: eyeColor,
                listening: listening
            )
            .frame(width: w, height: h)

            // Neck
            Rectangle()
                .fill(blue)
                .frame(width: w * 22 / 110, height: h * 6 / 130)
                .offset(x: w * 44 / 110, y: h * 68 / 130)

            // Body
            RoundedRectangle(cornerRadius: w * 9 / 110, style: .continuous)
                .fill(blue)
                .frame(width: w * 50 / 110, height: h * 38 / 130)
                .offset(x: w * 30 / 110, y: h * 74 / 130)
            RoundedRectangle(cornerRadius: w * 9 / 110, style: .continuous)
                .stroke(blueDeep, lineWidth: max(1, w / 110))
                .frame(width: w * 50 / 110, height: h * 38 / 130)
                .offset(x: w * 30 / 110, y: h * 74 / 130)

            // Terminal ">_" text + blinking cursor
            Text(">_")
                .font(.system(size: w * 14 / 110, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .offset(x: w * 38 / 110, y: h * 86 / 130)
            if listening {
                Rectangle()
                    .fill(.white)
                    .frame(width: w * 5 / 110, height: h * 11 / 130)
                    .opacity(cursorOn ? 1 : 0)
                    .offset(x: w * 60 / 110, y: h * 89 / 130)
            }

            // Arms
            Capsule()
                .fill(blue)
                .frame(width: w * 18 / 110, height: h * 9 / 130)
                .overlay(Capsule().stroke(blueDeep, lineWidth: max(1, w / 110)))
                .offset(x: w * 14 / 110, y: h * 84 / 130)
            Capsule()
                .fill(blue)
                .frame(width: w * 18 / 110, height: h * 9 / 130)
                .overlay(Capsule().stroke(blueDeep, lineWidth: max(1, w / 110)))
                .offset(x: w * 78 / 110, y: h * 84 / 130)

            // Feet
            RoundedRectangle(cornerRadius: w * 3 / 110)
                .fill(blue)
                .frame(width: w * 13 / 110, height: h * 9 / 130)
                .offset(x: w * 38 / 110, y: h * 112 / 130)
            RoundedRectangle(cornerRadius: w * 3 / 110)
                .fill(blue)
                .frame(width: w * 13 / 110, height: h * 9 / 130)
                .offset(x: w * 59 / 110, y: h * 112 / 130)

            // Ground shadow
            Ellipse()
                .fill(.black.opacity(0.15))
                .frame(width: w * 48 / 110, height: h * 5 / 130)
                .offset(x: w * 31 / 110, y: h * 122 / 130)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .modifier(ExpressionCycler(listening: listening, expression: $expression))
        .modifier(BodyBob(listening: listening))
        .task(id: listening) {
            if !listening { return }
            while !Task.isCancelled {
                cursorOn.toggle()
                try? await Task.sleep(nanoseconds: 550_000_000)
            }
        }
    }
}

private struct CodexHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 110
        let h = rect.height / 130
        var p = Path()
        // Path: M 8 70 L 8 42 A 18 18 0 0 1 28 24 A 22 22 0 0 1 55 8 A 22 22 0 0 1 82 24 A 18 18 0 0 1 102 42 L 102 70 Z
        p.move(to: CGPoint(x: 8 * w, y: 70 * h))
        p.addLine(to: CGPoint(x: 8 * w, y: 42 * h))
        // Arc: A 18 18 0 0 1 28 24 — to (28,24), large=0, sweep=1
        p.addArc(tangent1End: CGPoint(x: 8 * w, y: 24 * h),
                 tangent2End: CGPoint(x: 28 * w, y: 24 * h),
                 radius: 18 * w)
        // A 22 22 0 0 1 55 8
        p.addArc(tangent1End: CGPoint(x: 28 * w, y: 8 * h),
                 tangent2End: CGPoint(x: 55 * w, y: 8 * h),
                 radius: 22 * w)
        // A 22 22 0 0 1 82 24
        p.addArc(tangent1End: CGPoint(x: 82 * w, y: 8 * h),
                 tangent2End: CGPoint(x: 82 * w, y: 24 * h),
                 radius: 22 * w)
        // A 18 18 0 0 1 102 42
        p.addArc(tangent1End: CGPoint(x: 102 * w, y: 24 * h),
                 tangent2End: CGPoint(x: 102 * w, y: 42 * h),
                 radius: 18 * w)
        p.addLine(to: CGPoint(x: 102 * w, y: 70 * h))
        p.closeSubpath()
        return p
    }
}

private struct CodexEyes: View {
    let expression: Expression
    let color: Color
    let listening: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / 110
            let h = geo.size.height / 130
            // Eye centers at x=40 and x=70 in viewBox units, y=50
            let stroke = StrokeStyle(lineWidth: 3 * min(w, h), lineCap: .round, lineJoin: .round)
            ZStack {
                eye(at: CGPoint(x: 40 * w, y: 50 * h), w: w, h: h, stroke: stroke)
                eye(at: CGPoint(x: 70 * w, y: 50 * h), w: w, h: h, stroke: stroke)
            }
        }
    }

    @ViewBuilder
    private func eye(at center: CGPoint, w: CGFloat, h: CGFloat, stroke: StrokeStyle) -> some View {
        switch expression {
        case .open:
            ArchEyeShape()
                .stroke(color, style: stroke)
                .frame(width: 14 * w, height: 8 * h)
                .position(x: center.x, y: center.y)
        case .blink:
            Path { p in
                p.move(to: CGPoint(x: -7 * w, y: 0))
                p.addLine(to: CGPoint(x: 7 * w, y: 0))
            }
            .stroke(color, style: stroke)
            .frame(width: 14 * w, height: 1)
            .position(x: center.x, y: center.y)
        case .squint:
            // Single squint chevron
            let isLeft = center.x < 55 * w
            ChevronShape(pointsRight: isLeft)
                .stroke(color, style: stroke)
                .frame(width: 9 * w, height: 12 * h)
                .position(x: center.x, y: center.y)
        }
    }
}

private struct ArchEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Approximation of: M (cx-7) 50 Q cx 42 (cx+7) 50
        p.move(to: CGPoint(x: 0, y: rect.height))
        p.addQuadCurve(
            to: CGPoint(x: rect.width, y: rect.height),
            control: CGPoint(x: rect.width / 2, y: 0)
        )
        return p
    }
}
