//
//  Components.swift
//  Vibez
//
//  Building blocks for the main screen: WARP-style pill toggle, top bar,
//  blocked-app card, recent-trigger row.
//

import SwiftUI
import UIKit
import FamilyControls
import ManagedSettings

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
    let isInteractive: Bool
    var onLockedTap: () -> Void = {}

    private let pillW: CGFloat = 250
    private let pillH: CGFloat = 132
    private let knobSize: CGFloat = 116

    var body: some View {
        Button {
            guard isInteractive else {
                // Notifications aren't set up yet — bounce instead of
                // toggling so the user gets a clear "no, look down there"
                // cue rather than a silent dead button.
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                onLockedTap()
                return
            }
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
                    .fill(enabled ? AnyShapeStyle(theme.pillGradient) : AnyShapeStyle(theme.bgWidget))
//                    .shadow(color: enabled ? theme.accentDeep.opacity(0.55) : .clear,
//                            radius: enabled ? 18 : 0, x: 0, y: 12)
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
                        VStack{
                            if (isInteractive){
                                BlockerKnob(
                                    listening: enabled,
                                    size: 92,
                                    stroke: theme.fg
                                )
                            }
                        }
                    )
                    .padding(.leading, knobX)
            }
            .frame(width: pillW, height: pillH)
        }
        .buttonStyle(.plain)
        .opacity(isInteractive ? 1.0 : 0.9)
        .accessibilityLabel(enabled ? "Disable Vibez" : "Enable Vibez")
    }

    private var knobX: CGFloat {
        enabled ? (pillW - knobSize - 8) : 8
    }
}

// MARK: - Shake effect
//
// A gentle damped sine in the x-axis. Driven by an Int trigger: bump
// the trigger and the view shakes once. Damping tapers the amplitude
// to zero by the end so the view settles cleanly instead of stopping
// mid-swing.

struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 6
    var shakesPerUnit: Int = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        // animatableData interpolates from N to N+1 over the shake.
        // Use the fractional part so both the oscillation phase and the
        // amplitude taper restart cleanly with each new trigger.
        let fraction = animatableData - floor(animatableData)
        let damping = max(0, 1.0 - fraction)
        let dx = amount * damping * sin(fraction * .pi * CGFloat(shakesPerUnit * 2))
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}

extension View {
    func shake(trigger: Int, amount: CGFloat = 6, shakesPerUnit: Int = 3, duration: Double = 0.42) -> some View {
        modifier(ShakeEffect(amount: amount, shakesPerUnit: shakesPerUnit, animatableData: CGFloat(trigger)))
            .animation(.easeOut(duration: duration), value: trigger)
    }
}

// MARK: - Wordmark

struct VibezWordmark: View {
    var body: some View {
        Image("Wordmark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 25)
            .fixedSize()
    }
}

// MARK: - Top bar

enum TopBarLayout {
    static let horizontalPadding: CGFloat = 22
    static let topPadding: CGFloat = 4
    static let bottomPadding: CGFloat = 6
    static let settingsButtonSize: CGFloat = 34
}

struct TopBar: View {
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
        .padding(.horizontal, TopBarLayout.horizontalPadding)
        .padding(.top, TopBarLayout.topPadding)
        .padding(.bottom, TopBarLayout.bottomPadding)
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
                .frame(
                    width: TopBarLayout.settingsButtonSize,
                    height: TopBarLayout.settingsButtonSize
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.bgChip)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}


// MARK: - Blocking apps panel

/// Side length of every tile. Square, so token icons and the AddTile
/// occupy identical visual footprints. Also the AddTile's minimum
/// width — when it shrinks to this, any additional tokens kick the
/// row into horizontal scroll mode.
private let tileSize: CGFloat = 56

/// Fallback transform-scale, used only if the dynamic-type hint
/// doesn't drive `Label(token)` icon size. `scaleEffect` stretches
/// the rasterized icon and softens it; we'd rather not use it.
private let tileIconScaleFallback: CGFloat = 2.3

/// Inter-tile gap bounds. Spacing flexes within [min, max] as more
/// tokens fill the row, with AddTile absorbing the rest.
private let panelMinSpacing: CGFloat = 3
private let panelMaxSpacing: CGFloat = 12

struct BlockingPanel: View {
    let selection: FamilyActivitySelection
    let enabled: Bool
    let theme: Theme
    /// Tapping the trailing "+" tile fires this — wire it to presenting
    /// `FamilyActivityPicker` from the parent.
    let onPickMore: () -> Void

    private var apps: [ApplicationToken] { Array(selection.applicationTokens) }
    private var cats: [ActivityCategoryToken] { Array(selection.categoryTokens) }
    private var webs: [WebDomainToken] { Array(selection.webDomainTokens) }

    private var totalCount: Int {
        apps.count + cats.count + webs.count
    }

    private var countLabel: String {
        switch totalCount {
        case 0: return "nothing yet"
        case 1: return "1 item"
        default: return "\(totalCount) items"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Blocking")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.fg)
                Spacer()
                Text(countLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.fgMute)
            }
            tilesRow
        }
        // Single source of "is this active" styling — desaturate +
        // dim the entire panel content when the toggle is off, so the
        // panel reads as inert without per-tile accent colors.
        .grayscale(enabled ? 0 : 1.0)
        .opacity(enabled ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.3), value: enabled)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.bgPanel)
        )
    }

    private var tilesRow: some View {
        GeometryReader { geo in
            let plan = layoutPlan(width: geo.size.width)
            if plan.scrollable {
                scrollableRow
            } else {
                fixedRow(spacing: plan.spacing, addWidth: plan.addWidth)
            }
        }
        .frame(height: tileSize)
    }

    /// Order: apps → categories → web domains so the most-recognizable
    /// tiles surface first.
    @ViewBuilder
    private var tokenTiles: some View {
        ForEach(apps, id: \.self) { token in
            TokenTile { Label(token).labelStyle(.iconOnly) }
        }
        ForEach(cats, id: \.self) { token in
            TokenTile { Label(token).labelStyle(.iconOnly) }
        }
        ForEach(webs, id: \.self) { token in
            TokenTile { Label(token).labelStyle(.iconOnly) }
        }
    }

    @ViewBuilder
    private func fixedRow(spacing: CGFloat, addWidth: CGFloat) -> some View {
        HStack(spacing: spacing) {
            tokenTiles
            AddTile(width: addWidth, theme: theme, onTap: onPickMore)
        }
    }

    @ViewBuilder
    private var scrollableRow: some View {
        HorizontalFadeScroll {
            HStack(spacing: panelMinSpacing) {
                tokenTiles
                AddTile(width: tileSize, theme: theme, onTap: onPickMore)
            }
        }
    }

    private struct LayoutPlan {
        var spacing: CGFloat
        var addWidth: CGFloat
        var scrollable: Bool
    }

    /// Solves for spacing and AddTile width given N tokens and the row's
    /// available width. Wants max spacing when sparse, shrinking toward
    /// min as the row fills; AddTile picks up the slack. Falls back to
    /// horizontal scroll once min spacing still can't hold the row.
    private func layoutPlan(width A: CGFloat) -> LayoutPlan {
        let N = totalCount
        guard N > 0 else {
            return LayoutPlan(spacing: 0, addWidth: A, scrollable: false)
        }
        // Row layout: N tokens + 1 AddTile = N+1 tiles, N gaps.
        //   A = N * tileSize + N * spacing + addWidth
        // Pin AddTile at its minimum (tileSize) and solve for spacing.
        let pivotSpacing = (A - tileSize) / CGFloat(N) - tileSize

        if pivotSpacing >= panelMaxSpacing {
            // Plenty of room: spacing at max, AddTile soaks up the rest.
            let s = panelMaxSpacing
            return LayoutPlan(
                spacing: s,
                addWidth: A - CGFloat(N) * (tileSize + s),
                scrollable: false
            )
        } else if pivotSpacing >= panelMinSpacing {
            // Tighter: spacing flexes in [min, max], AddTile at its min.
            return LayoutPlan(
                spacing: pivotSpacing,
                addWidth: tileSize,
                scrollable: false
            )
        } else {
            // Can't fit at min spacing — horizontal scroll takes over.
            return LayoutPlan(
                spacing: panelMinSpacing,
                addWidth: tileSize,
                scrollable: true
            )
        }
    }
}

private struct TokenTile<Icon: View>: View {
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        icon()
            // Confirmed ignored by Apple for token labels but cheap
            // to leave in — if a future iOS starts respecting them,
            // we'd get a sharper render for free.
            .imageScale(.large)
            .dynamicTypeSize(.accessibility5)
            // Last-resort transform scale. Trade-off: bigger icon but
            // softer (bitmap stretch from Apple's small native render).
            .scaleEffect(tileIconScaleFallback, anchor: .center)
            .frame(width: tileSize, height: tileSize)
    }
}

private struct AddTile: View {
    let width: CGFloat
    let theme: Theme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.fg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            theme.fgMute.opacity(0.4),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                        )
                )
                // Default hit shape follows the "+" Image's opaque
                // pixels — pin it to the full tile rect so the whole
                // dashed area is tappable.
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(width: width, height: tileSize)
    }
}

/// Horizontal scroll wrapper with edge-fade masks that match the
/// vertical pattern used in RecentTriggersSection — fades animate in
/// only when the user can actually scroll further in that direction.
private struct HorizontalFadeScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    private struct ScrollEdges: Equatable {
        var atStart: Bool
        var atEnd: Bool
    }

    @State private var atStart = true
    @State private var atEnd = false

    private var showStartFade: Bool { !atStart }
    private var showEndFade: Bool { !atEnd }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: ScrollEdges.self) { geo in
            let maxOffset = max(0, geo.contentSize.width - geo.containerSize.width)
            return ScrollEdges(
                atStart: geo.contentOffset.x <= 1,
                atEnd: geo.contentOffset.x >= maxOffset - 1
            )
        } action: { _, newValue in
            withAnimation(.easeInOut(duration: 0.35)) {
                atStart = newValue.atStart
                atEnd = newValue.atEnd
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(showStartFade ? 0 : 1), location: 0.0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .black.opacity(showEndFade ? 0 : 1), location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

// MARK: - Analytics panel

/// Today-only usage summary. Reads counts straight from the
/// `AnalyticsTracker` (resets at local midnight) and shows total shield-up
/// time today, including any currently-running interval.
struct AnalyticsPanel: View {
    let analytics: AnalyticsTracker
    let theme: Theme
    let onSelectMostBlocked: () -> Void

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            return "\(m)m"
        }
        let h = Int(seconds / 3600)
        let m = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        return m == 0 ? "\(h)h" : "\(h)h\(m)m"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Today")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.fg)
                Spacer()
            }
            HStack(spacing: 6) {
                AnalyticsColumn(
                    value: "\(analytics.conversationsToday)",
                    label: "chats",
                    theme: theme
                )
                AnalyticsColumn(
                    value: "\(analytics.responsesToday)",
                    label: "replies",
                    theme: theme
                )
                // TimelineView nudges this column every 30s so an
                // in-flight focus interval visibly ticks up rather than
                // freezing until the next push lands. focusSecondsToday
                // recomputes the running delta from Date() each render.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    AnalyticsColumn(
                        value: analytics.focusSecondsToday > 0
                            ? formatDuration(analytics.focusSecondsToday)
                            : "—",
                        label: "focus",
                        theme: theme
                    )
                }
                MostBlockedColumn(
                    tokens: analytics.topBlockedApps(limit: 3),
                    theme: theme,
                    onTap: onSelectMostBlocked
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.bgWidget)
        )
    }
}

private struct AnalyticsColumn: View {
    let value: String
    let label: String
    let theme: Theme

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(theme.fg)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.fgMute)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.fgMute.opacity(0.22), lineWidth: 1)
        )
    }
}

/// Sibling of AnalyticsColumn for the "most blocked" tile. Renders up
/// to three system-drawn app icons in a tight horizontal row above the
/// label; falls back to an em-dash when nothing's been blocked yet.
private struct MostBlockedColumn: View {
    let tokens: [ApplicationToken]
    let theme: Theme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    if tokens.isEmpty {
                        Text("—")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.fg)
                    } else {
                        HStack(spacing: 3) {
                            ForEach(Array(tokens.prefix(3)), id: \.self) { token in
                                Label(token)
                                    .labelStyle(.iconOnly)
                                    // Same trick we use elsewhere — Apple
                                    // ignores `.frame` on token labels, so
                                    // scaleEffect is the only path to a
                                    // visible size at this tile scale.
                                    .scaleEffect(0.9, anchor: .center)
                                    .frame(width: 22, height: 22)
                            }
                        }
                    }
                }
                .frame(height: 32)

                Text("most blocked")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.fgMute)
                    .tracking(0.5)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.fgMute.opacity(0.22), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Most blocked apps. Tap to add more apps to block.")
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
    /// Wall-clock time when the user replied to this trigger (matched
    /// via `_vibez:shield:off`). Set by `TriggerStore.clearNeedsReply`.
    /// Nil if the user never replied (still pending, timed out, or
    /// dismissed) — also nil for older persisted events.
    var repliedAt: Date?

    init(
        id: UUID = UUID(),
        receivedAt: Date = Date(),
        source: Source,
        title: String? = nil,
        label: String,
        blockSeconds: Int,
        sessionId: String? = nil,
        needsReply: Bool = false,
        repliedAt: Date? = nil
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.source = source
        self.title = title
        self.label = label
        self.blockSeconds = blockSeconds
        self.sessionId = sessionId
        self.needsReply = needsReply
        self.repliedAt = repliedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, receivedAt, source, title, label, blockSeconds, sessionId, needsReply, repliedAt
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
        repliedAt = try c.decodeIfPresent(Date.self, forKey: .repliedAt)
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

    /// Map a ntfy message's producing agent to a trigger Source. The Vibez
    /// plugin always sets "_vibez:agent"; untagged pushes (e.g. a raw
    /// `curl` test ping) fall back to the user's currently selected agent.
    static func source(for agent: VibezAgent?, fallback: Agent) -> Source {
        switch agent {
        case .claude: return .claude
        case .codex:  return .codex
        case nil:     return fallback == .codex ? .codex : .claude
        }
    }
}

struct TriggerRow: View {
    let event: TriggerEvent
    let theme: Theme
    let now: Date
    let ignoredBySession: Bool
    let ignoredByName: Bool
    let onIgnoreSession: () -> Void
    let onIgnoreName: () -> Void
    let onUnignoreSession: () -> Void
    let onUnignoreName: () -> Void

    private var isIgnored: Bool { ignoredBySession || ignoredByName }

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
                    Text(.init(topLine))
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
                    Text(.init(description))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.fgMute)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Text("\(event.relativeTime(from: now))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.fgFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.bgWidget)
        )
        .opacity(isIgnored ? 0.55 : 1.0)

        if canIgnore {
            row.contextMenu {
                if ignoredBySession {
                    Button(action: onUnignoreSession) {
                        Label("Stop ignoring this conversation", systemImage: "bell")
                    }
                } else {
                    Button(action: onIgnoreSession) {
                        Label("Ignore this conversation", systemImage: "bell.slash")
                    }
                }
                if ignoredByName {
                    Button(action: onUnignoreName) {
                        Label("Stop ignoring by name", systemImage: "tag")
                    }
                } else {
                    Button(action: onIgnoreName) {
                        Label("Ignore by name", systemImage: "tag.slash")
                    }
                }
            }
        } else {
            row
        }
    }
}

enum RecentTriggersLayout {
    static let collapsedReserveHeight: CGFloat = 198

    fileprivate static let collapsedHeight: CGFloat = 196
    fileprivate static let collapsedCornerRadius: CGFloat = 48
    fileprivate static let expandedCornerRadius: CGFloat = 24
    fileprivate static let headerDragHeight: CGFloat = 112
    fileprivate static let horizontalInset: CGFloat = 14
    fileprivate static let collapsedPreviewCount = 3
}

struct RecentTriggersSection: View {
    let events: [TriggerEvent]
    let theme: Theme
    let ignoreStore: IgnoreStore
    let onIgnoreSession: (TriggerEvent) -> Void
    let onIgnoreName: (TriggerEvent) -> Void
    let onUnignoreSession: (TriggerEvent) -> Void
    let onUnignoreName: (TriggerEvent) -> Void

    private struct ScrollEdges: Equatable {
        var atTop: Bool
        var atEnd: Bool
    }

    @State private var isExpanded = false
    @State private var atTop = true
    @State private var atEnd = false

    private var showTopFade: Bool { !atTop }
    private var showBottomFade: Bool { !atEnd }

    private func ignoredBySession(_ event: TriggerEvent) -> Bool {
        guard let sid = event.sessionId else { return false }
        return ignoreStore.sessionRuleMatching(sessionId: sid) != nil
    }

    private func ignoredByName(_ event: TriggerEvent) -> Bool {
        let name = event.title?.isEmpty == false ? event.title! : event.label
        return ignoreStore.nameRuleMatching(name: name) != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let bottomInset = max(0, proxy.safeAreaInsets.bottom)
            let fullHeight = proxy.size.height
            let collapsedHeight = min(
                fullHeight,
                RecentTriggersLayout.collapsedHeight + bottomInset
            )
            let height = isExpanded ? fullHeight : collapsedHeight

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                panel(bottomInset: bottomInset)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background {
                        panelShape
                            .fill(theme.bgChip)
                            .shadow(
                                color: .black.opacity(0.22),
                                radius: isExpanded ? 24 : 48,
                                x: 0,
                                y: -8
                            )
                    }
                    .clipShape(panelShape)
                    .contentShape(panelShape)
                    .simultaneousGesture(sheetDragGesture)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(sheetAnimation, value: isExpanded)
    }

    @ViewBuilder
    private func panel(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            sheetHeader
                .padding(.top, isExpanded ? 16 : 20)
                .padding(.horizontal, 22)

            if isExpanded {
                expandedList(bottomInset: bottomInset)
            } else {
                collapsedPreview(bottomInset: bottomInset)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var sheetHeader: some View {
        VStack(spacing: isExpanded ? 6 : 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: isExpanded ? 24 : 30, weight: .bold))
                .foregroundStyle(theme.fg)
                .frame(height: 28)
                .accessibilityHidden(true)

            Text("Recent Triggers")
                .font(.system(size: isExpanded ? 24 : 31, weight: .heavy))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { setExpanded(!isExpanded) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isExpanded ? "Collapse Recent Triggers" : "Expand Recent Triggers")
    }

    @ViewBuilder
    private func collapsedPreview(bottomInset: CGFloat) -> some View {
        if events.isEmpty {
            VStack(spacing: 0) {
                emptyState
            }
            .padding(.horizontal, RecentTriggersLayout.horizontalInset)
            .padding(.top, 14)
            .padding(.bottom, max(12, bottomInset + 8))
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                GeometryReader { proxy in
                    VStack(spacing: 8) {
                        ForEach(events.prefix(RecentTriggersLayout.collapsedPreviewCount)) { event in
                            triggerRow(for: event, now: context.date)
                        }
                    }
                    .padding(.horizontal, RecentTriggersLayout.horizontalInset)
                    .padding(.top, 14)
                    .padding(.bottom, max(12, bottomInset + 8))
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .top
                    )
                    .mask {
                        collapsedPreviewMask(fadesBottom: events.count > 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func expandedList(bottomInset: CGFloat) -> some View {
        if events.isEmpty {
            VStack(spacing: 0) {
                emptyState
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RecentTriggersLayout.horizontalInset)
            .padding(.top, 18)
            .padding(.bottom, max(24, bottomInset + 18))
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(events) { event in
                            triggerRow(for: event, now: context.date)
                        }
                    }
                    .padding(.horizontal, RecentTriggersLayout.horizontalInset)
                    .padding(.top, 18)
                    .padding(.bottom, max(28, bottomInset + 24))
                }
                .scrollBounceBehavior(.basedOnSize)
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
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(showTopFade ? 0 : 1), location: 0.0),
                            .init(color: .black, location: 0.10),
                            .init(color: .black, location: 0.88),
                            .init(color: .black.opacity(showBottomFade ? 0 : 1), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func triggerRow(for event: TriggerEvent, now: Date) -> some View {
        TriggerRow(
            event: event,
            theme: theme,
            now: now,
            ignoredBySession: ignoredBySession(event),
            ignoredByName: ignoredByName(event),
            onIgnoreSession: { onIgnoreSession(event) },
            onIgnoreName: { onIgnoreName(event) },
            onUnignoreSession: { onUnignoreSession(event) },
            onUnignoreName: { onUnignoreName(event) }
        )
    }

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
                .fill(theme.bgWidget)
        )
    }

    private func collapsedPreviewMask(fadesBottom: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: RecentTriggersLayout.collapsedCornerRadius,
            bottomTrailingRadius: RecentTriggersLayout.collapsedCornerRadius,
            topTrailingRadius: 0
        )
        .fill(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: fadesBottom ? 0.58 : 1.0),
                    .init(color: .black.opacity(fadesBottom ? 0 : 1), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isExpanded
                ? RecentTriggersLayout.expandedCornerRadius
                : RecentTriggersLayout.collapsedCornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: isExpanded
                ? RecentTriggersLayout.expandedCornerRadius
                : RecentTriggersLayout.collapsedCornerRadius
        )
    }

    private var sheetDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { value in
                guard canToggleSheet(from: value.startLocation) else { return }
                let translation = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if isExpanded {
                    if translation > 44 || predicted > 110 {
                        setExpanded(false)
                    }
                } else if translation < -44 || predicted < -110 {
                    setExpanded(true)
                }
            }
    }

    private var sheetAnimation: Animation {
        .spring(response: 0.44, dampingFraction: 0.86)
    }

    private func canToggleSheet(from startLocation: CGPoint) -> Bool {
        !isExpanded || startLocation.y <= RecentTriggersLayout.headerDragHeight
    }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        withAnimation(sheetAnimation) {
            isExpanded = expanded
        }
    }
}

// MARK: - Glow

struct AccentGlow: View {
    let theme: Theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [theme.accent.opacity(colorScheme == .dark ? 0.20 : 0.14), .clear],
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

// MARK: - Focus mode

/// Live status pill shown under the mascot while a manual focus hold is
/// active. Ticks the elapsed time once a second and is itself a tap target
/// to release the hold.
struct FocusPill: View {
    let startedAt: Date?
    let theme: Theme
    var onTap: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .bold))
                Text("Focus mode")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .tracking(1)
                Text("·").opacity(0.6)
                Text(elapsed(now: context.date))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                Text("· tap to release")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .opacity(0.85)
            }
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.accent))
        }
        .contentShape(Capsule())
        .onTapGesture { onTap() }
        .accessibilityLabel("Focus mode active. Double tap to release.")
    }

    private func elapsed(now: Date) -> String {
        guard let startedAt else { return "0:00" }
        let total = max(0, Int(now.timeIntervalSince(startedAt)))
        let m = total / 60
        let s = total % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Soft pulsing accent glow placed behind the mascot while focused.
/// Purely decorative — never eats taps.
struct FocusHalo: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.45), color.opacity(0.0)],
                    center: .center,
                    startRadius: 2,
                    endRadius: 110
                )
            )
            .frame(width: 220, height: 220)
            .scaleEffect(pulse ? 1.08 : 0.92)
            .opacity(pulse ? 0.9 : 0.55)
            .blur(radius: 8)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .allowsHitTesting(false)
    }
}
