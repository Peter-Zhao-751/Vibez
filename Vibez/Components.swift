//
//  Components.swift
//  Vibez
//
//  Building blocks for the main screen: WARP-style pill toggle, top bar,
//  blocked-app card, recent-trigger row.
//

import SwiftUI
import UIKit

// MARK: - BlockerKnob (waveform inside the pill toggle)
//
// ON  → silent: a single flat baseline.
// OFF → noisy: three vertical bars rising and falling at different
//       periods, like an audio meter being "chaotic" because nothing's
//       blocking the doom-scroll yet.

struct BlockerKnob: View {
    let listening: Bool
    let size: CGFloat
    let stroke: Color

    var body: some View {
        if listening {
            silentBaseline
        } else {
            chaoticBars
        }
    }

    private var silentBaseline: some View {
        Canvas { ctx, sz in
            var path = Path()
            path.move(to: CGPoint(x: sz.width * 0.22, y: sz.height * 0.5))
            path.addLine(to: CGPoint(x: sz.width * 0.78, y: sz.height * 0.5))
            ctx.stroke(
                path,
                with: .color(stroke),
                style: StrokeStyle(lineWidth: sz.width * 0.04, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }

    private var chaoticBars: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, sz in
                let t = context.date.timeIntervalSinceReferenceDate
                let lineWidth = sz.width * 0.05
                // Three bars, each at a different x and oscillating with
                // a different period so they look uncorrelated.
                let bars: [(cx: CGFloat, period: Double, phase: Double, amp: CGFloat)] = [
                    (cx: 0.30, period: 1.4, phase: 0.0, amp: 0.20),
                    (cx: 0.50, period: 1.6, phase: 0.7, amp: 0.28),
                    (cx: 0.70, period: 1.2, phase: 1.4, amp: 0.18),
                ]
                for bar in bars {
                    let p = (t / bar.period + bar.phase) * 2 * .pi
                    // |sin| keeps the amplitude in [0, 1]; scaling by
                    // 0.5 + 0.5*|sin| makes the minimum a non-zero
                    // resting amplitude so the bar never collapses.
                    let amp = bar.amp * sz.height * (0.5 + 0.5 * abs(sin(p)))
                    let x = bar.cx * sz.width
                    let mid = sz.height * 0.5
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: mid - amp))
                    path.addLine(to: CGPoint(x: x, y: mid + amp))
                    ctx.stroke(
                        path,
                        with: .color(stroke),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Big WARP-style toggle

struct BigToggle: View {
    @Binding var enabled: Bool
    let agent: Agent
    let theme: Theme

    private let pillW: CGFloat = 250
    private let pillH: CGFloat = 132
    private let knobSize: CGFloat = 116

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                enabled.toggle()
            }
            if (!enabled){
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }else{
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        } label: {
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(enabled ? AnyShapeStyle(theme.pillGradient) : AnyShapeStyle(theme.pillOff))
                    .overlay(
                        // Inner shadow when off, soft top highlight when on.
                        Capsule()
                            .stroke(.white.opacity(enabled ? 0.18 : 0), lineWidth: 1)
                            .blendMode(.overlay)
                    )
                    .shadow(color: enabled ? theme.accentDeep.opacity(0.55) : .clear,
                            radius: enabled ? 18 : 0, x: 0, y: 12)
                    .frame(width: pillW, height: pillH)

                // OFF / ON labels
                ZStack {
                    Text("OFF")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(enabled ? .clear : theme.fgFaint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 30)
                    Text("ON")
                        .font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(enabled ? .white.opacity(0.9) : .clear)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 30)
                }
                .frame(width: pillW, height: pillH)

                // Knob (sliding circle with waveform inside)
                Circle()
                    .fill(theme.knobBg)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 6)
                    .overlay(
                        Circle().stroke(.black.opacity(0.04), lineWidth: 1)
                    )
                    .overlay(
                        BlockerKnob(
                            listening: enabled,
                            size: 92,
                            stroke: theme.fg
                        )
                    )
                    .padding(.leading, knobX)
            }
            .frame(width: pillW, height: pillH)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(enabled ? "Disable Vibez" : "Enable Vibez")
    }

    private var knobX: CGFloat {
        enabled ? (pillW - knobSize - 8) : 8
    }
}

// MARK: - Wordmark

struct VibezWordmark: View {
    var body: some View {
        Image("Wordmark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 50)
            .fixedSize()
    }
}

// MARK: - Top bar

struct TopBar: View {
    let isDark: Bool
    let theme: Theme
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VibezWordmark()
            Spacer()
            ChipIconButton(
                systemName: "gearshape",
                theme: theme,
                accessibilityLabel: "Open settings",
                action: onOpenSettings
            )
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

struct ChipIconButton: View {
    let systemName: String
    let theme: Theme
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.fg)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.bgChip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let listening: Bool
    let theme: Theme

    var body: some View {
        Text(listening ? "● LISTENING" : "○ STANDBY")
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .tracking(2.4)
            .foregroundStyle(listening ? theme.accent : theme.fgFaint)
    }
}

// MARK: - Blocking apps panel

struct BlockedAppCard: View {
    let app: BlockedApp
    let enabled: Bool
    let theme: Theme

    var body: some View {
        VStack(spacing: 4) {
            Text(app.glyph)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(theme.fgMute.opacity(enabled ? 0.55 : 1))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.bgChip)
                )
            Text(app.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? theme.accent : theme.fgMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(enabled ? theme.accent.opacity(0.08) : theme.bgChip)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(enabled ? theme.accent.opacity(0.2) : theme.hairline, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.3), value: enabled)
    }
}

struct BlockedApp: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let glyph: String

    static let demoSet: [BlockedApp] = [
        .init(name: "Instagram", glyph: "IG"),
        .init(name: "TikTok", glyph: "TT"),
        .init(name: "X", glyph: "X"),
        .init(name: "YouTube", glyph: "YT"),
    ]
}

struct BlockingPanel: View {
    let apps: [BlockedApp]
    let enabled: Bool
    let theme: Theme

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Blocking")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.fg)
                Spacer()
                Text("\(apps.count) apps")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fgMute)
            }
            HStack(spacing: 8) {
                ForEach(apps) { app in
                    BlockedAppCard(app: app, enabled: enabled, theme: theme)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Recent triggers

struct TriggerEvent: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case claude, codex }

    var id: UUID
    var receivedAt: Date
    var source: Source
    /// Conversation name (e.g. "Plan plugin distribution"). May be nil
    /// for older persisted events from before this field existed.
    var title: String?
    /// Body / description of the ping (e.g. "Permission required to
    /// run npm install").
    var label: String
    var blockSeconds: Int
    /// Claude Code session id, used to match an unblock against the
    /// matching block event. Optional for back-compat with older
    /// persisted events that didn't store it.
    var sessionId: String?
    /// True while this trigger is still parked on a user reply.
    /// Cleared by TriggerStore.clearNeedsReply when the matching
    /// _vibez:unblock arrives. Defaults to false so old persisted
    /// events render without a dot.
    var needsReply: Bool

    init(
        id: UUID = UUID(),
        receivedAt: Date = Date(),
        source: Source,
        title: String? = nil,
        label: String,
        blockSeconds: Int,
        sessionId: String? = nil,
        needsReply: Bool = false
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.source = source
        self.title = title
        self.label = label
        self.blockSeconds = blockSeconds
        self.sessionId = sessionId
        self.needsReply = needsReply
    }

    private enum CodingKeys: String, CodingKey {
        case id, receivedAt, source, title, label, blockSeconds, sessionId, needsReply
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        source = try c.decode(Source.self, forKey: .source)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        label = try c.decode(String.self, forKey: .label)
        blockSeconds = try c.decode(Int.self, forKey: .blockSeconds)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        needsReply = try c.decodeIfPresent(Bool.self, forKey: .needsReply) ?? false
    }

    /// Strip the " — done" / " — needs you" / " — replied" suffix
    /// that the plugin appends, so the conversation name renders alone.
    static func cleanedTitle(from rawTitle: String) -> String {
        guard let range = rawTitle.range(of: " — ", options: .backwards) else {
            return rawTitle
        }
        return String(rawTitle[..<range.lowerBound])
    }

    func relativeTime(from now: Date) -> String {
        let delta = max(0, Int(now.timeIntervalSince(receivedAt)))
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(delta / 60)m ago" }
        if delta < 86_400 { return "\(delta / 3600)h ago" }
        return "\(delta / 86_400)d ago"
    }

    var formattedDuration: String {
        let s = blockSeconds
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600
        let rem = (s % 3600) / 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }

    /// Sniff "Claude" / "Codex" out of the ntfy message; fall back to the
    /// user's currently selected agent so a generic ping still picks a side.
    static func detectSource(title: String, body: String, fallback: Agent) -> Source {
        let blob = (title + " " + body).lowercased()
        if blob.contains("codex") { return .codex }
        if blob.contains("claude") { return .claude }
        return fallback == .codex ? .codex : .claude
    }
}

struct TriggerRow: View {
    let event: TriggerEvent
    let theme: Theme
    let now: Date
    let isIgnored: Bool
    let onIgnore: () -> Void
    let onUnignore: () -> Void

    /// Conversation name; falls back to the body when older persisted
    /// events have no title.
    private var topLine: String {
        if let t = event.title, !t.isEmpty { return t }
        return event.label
    }

    /// Description / body text. Empty when there's no separate body
    /// (older events that only had a single label).
    private var descriptionLine: String? {
        guard let title = event.title, !title.isEmpty else { return nil }
        return event.label.isEmpty ? nil : event.label
    }

    private var canIgnore: Bool {
        guard let sid = event.sessionId else { return false }
        return !sid.isEmpty && sid != "nosid"
    }

    var body: some View {
        let row = HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(event.source == .codex ? Theme.codexBlue : Theme.claudeOrange)
                Text(event.source == .codex ? "cx" : "cc")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if event.needsReply {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Waiting for reply")
                    }
                    Text(topLine)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isIgnored {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.fgFaint)
                            .accessibilityLabel("ignored")
                    }
                }
                if let description = descriptionLine {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fgMute)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text("\(event.relativeTime(from: now)) · blocked \(event.formattedDuration)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.fgFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.hairline, lineWidth: 1)
        )
        .opacity(isIgnored ? 0.55 : 1.0)

        if canIgnore {
            row.contextMenu {
                if isIgnored {
                    Button(action: onUnignore) {
                        Label("Stop ignoring", systemImage: "bell")
                    }
                } else {
                    Button(action: onIgnore) {
                        Label("Ignore this conversation", systemImage: "bell.slash")
                    }
                }
            }
        } else {
            row
        }
    }
}

struct RecentTriggersSection: View {
    let events: [TriggerEvent]
    let theme: Theme
    let ignoreStore: IgnoreStore
    let onIgnore: (TriggerEvent) -> Void
    let onUnignore: (TriggerEvent) -> Void

    private struct ScrollEdges: Equatable {
        var atTop: Bool
        var atEnd: Bool
    }

    @State private var atTop = true
    @State private var atEnd = false

    private var showTopFade: Bool { events.count > 5 && !atTop }
    private var showBottomFade: Bool { events.count > 5 && !atEnd }

    private func isIgnored(_ event: TriggerEvent) -> Bool {
        guard let sid = event.sessionId else { return false }
        return ignoreStore.contains(sid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent triggers")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.fg)
                Spacer()
//                Text(events.isEmpty ? "—" : "last \(events.count)")
//                    .font(.system(size: 11, design: .monospaced))
//                    .foregroundStyle(theme.fgMute)
            }
            if events.isEmpty {
                emptyState
            } else {
                // Refresh the "Nm ago" labels every 30s without a manual timer.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(events) { event in
                                TriggerRow(
                                    event: event,
                                    theme: theme,
                                    now: context.date,
                                    isIgnored: isIgnored(event),
                                    onIgnore: { onIgnore(event) },
                                    onUnignore: { onUnignore(event) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 260) // ~5 rows × (46pt row + 6pt spacing); scrolls past 5
                    .scrollDisabled(events.count <= 5)
                    .scrollIndicators(.hidden)
                    .onScrollGeometryChange(for: ScrollEdges.self) { geo in
                        let maxOffset = max(0, geo.contentSize.height - geo.containerSize.height)
                        return ScrollEdges(
                            atTop: geo.contentOffset.y <= 1,
                            atEnd: geo.contentOffset.y >= maxOffset - 1
                        )
                    } action: { _, newValue in
                        withAnimation(.easeInOut(duration: 0.35)) {
                            atTop = newValue.atTop
                            atEnd = newValue.atEnd
                        }
                    }
                    .mask(
                        // Fixed-location stops with animated opacity at the
                        // edges — interpolating opacity is smoother than
                        // sliding stop positions, so the fade reads as a
                        // fade rather than a wipe.
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(showTopFade ? 0 : 1), location: 0.0),
                                .init(color: .black, location: 0.20),
                                .init(color: .black, location: 0.80),
                                .init(color: .black.opacity(showBottomFade ? 0 : 1), location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack {
            Text("No triggers yet — pings from Claude or Codex will land here.")
                .font(.system(size: 12))
                .foregroundStyle(theme.fgMute)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Glow

struct AccentGlow: View {
    let theme: Theme
    let dark: Bool

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [theme.accent.opacity(dark ? 0.20 : 0.14), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 320
                )
            )
            .frame(height: 360)
            .offset(y: -120)
            .allowsHitTesting(false)
    }
}
