//
//  Components.swift
//  Vibez
//
//  Building blocks for the main screen: slim WARP-style pill toggle
//  (which morphs into the focus-mode banner), top bar, blocked-app
//  card, recent-trigger row.
//

import SwiftUI
import UIKit
import FamilyControls
import ManagedSettings

// MARK: - Big WARP-style toggle
//
// Slim pill with a plain white knob and an accent glow while on.
// Locked (setup needed: unpaired, or pairing failed) → dim, taps
// bounce. In focus mode the switch
// morphs into the focus banner — "tap to release". One persistent
// capsule animates its size inside a constant-height layout box, so
// the vertical center never shifts and the pill melts into the banner
// instead of crossfading.

struct BigToggle: View {
    @Binding var enabled: Bool
    let theme: Theme
    let isInteractive: Bool
    let focusMode: Bool
    /// Whether the track casts its accent-colored glow/shadow. Off → a
    /// flat pill (gated by the Settings "Gradient effects" toggle). The
    /// gradient fill itself stays; only the colored drop-shadow goes.
    let showGlow: Bool
    var onLockedTap: () -> Void = {}
    var onReleaseFocus: () -> Void = {}

    /// Accent visibility. Driven imperatively (see `syncAccentOpacity`) so the
    /// off path can fade the residual out on its own delayed timeline — which a
    /// value-derived implicit animation can't express cleanly against the
    /// slide animation that's also in scope.
    @State private var accentOpacity: Double

    init(enabled: Binding<Bool>, theme: Theme, isInteractive: Bool,
         focusMode: Bool,
         showGlow: Bool = true,
         onLockedTap: @escaping () -> Void = {},
         onReleaseFocus: @escaping () -> Void = {}) {
        _enabled = enabled
        self.theme = theme
        self.isInteractive = isInteractive
        self.focusMode = focusMode
        self.showGlow = showGlow
        self.onLockedTap = onLockedTap
        self.onReleaseFocus = onReleaseFocus
        _accentOpacity = State(initialValue: (enabled.wrappedValue || focusMode) ? 1 : 0)
    }

    private static let pillW: CGFloat = 168
    /// Resting pill height — also the constant outer layout box, which
    /// ContentView centers on the screen.
    static let pillH: CGFloat = 66
    private static let bannerH: CGFloat = 42
    private static let knobSize: CGFloat = 50
    private static let knobPad: CGFloat = 8

    static let slideDuration: Double = 0.5
    /// Knob slide — the reference's `cubic-bezier(.7,.1,.2,1)` over .5s.
    static let slideAnimation = Animation.timingCurve(0.7, 0.1, 0.2, 1, duration: slideDuration)
    /// Off fade-out of the fill — runs immediately (no delay) so it reads as a
    /// prompt fade, not a wait-then-vanish.
    static let offFadeAnimation = Animation.easeInOut(duration: 0.2)

    private static let knobTravel = pillW - knobSize - 2 * knobPad

    /// Knob center X within the pillW track for an eased slide `progress`
    /// (0 = off → 1 = on). Linear; the knob and the accent fill both read it,
    /// so they travel in parallel (same rate — no racing) and reach their
    /// finals together.
    static func knobCenterX(at progress: CGFloat) -> CGFloat {
        knobPad + knobTravel * progress + knobSize / 2
    }

    /// Leading (front) edge X of the knob for slide `progress`.
    static func knobFrontX(at progress: CGFloat) -> CGFloat {
        knobCenterX(at: progress) + knobSize / 2
    }

    /// X the accent cap's apex tracks during the slide: the knob's front pulled
    /// back by `knobPad`, so the orange keeps the same margin off the circle
    /// that the circle keeps off the pill edge — the front trails the circle by
    /// a steady gap instead of touching it.
    static func accentApexX(at progress: CGFloat) -> CGFloat {
        knobFrontX(at: progress) - knobPad
    }

    /// Max lead of the accent cap's apex over its tracked point (reached only
    /// at progress 1), so the fill hits the pill's right edge exactly as the
    /// knob lands on the right (`accentApexX(1) + accentLead == pillW`). The
    /// mask scales it by progress, so for nearly the whole travel the orange's
    /// front keeps its margin off the circle and only pulls past it at the very
    /// end to close the edge gap — otherwise the fill would either trail the
    /// circle by too much or stop short of the pill edge at rest-on.
    static let accentLead = pillW - (knobTravel + knobSize)

    /// Whether the accent should be shown at all (drives its opacity).
    private var accentLit: Bool { enabled || focusMode }

    var body: some View {
        Button {
            if focusMode {
                onReleaseFocus()
            } else if !isInteractive {
                // Not paired yet — bounce instead of toggling so the
                // user gets a clear "no, look down there" cue rather
                // than a silent dead button.
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                onLockedTap()
            } else {
                enabled.toggle()
                if (!enabled){
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }else{
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
        } label: {
            ZStack(alignment: .leading) {
                if focusMode {
                    focusLabel
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                } else {
                    knob
                        .padding(.leading, knobX)
                        .transition(.opacity)
                }
            }
            // The capsule's box: pill is exactly pillW×pillH; the banner
            // hugs its label (minWidth keeps it at least pill-wide) at
            // bannerH tall.
            // Both dimensions animate through the morph. Leading-aligned
            // so the knob hugs the pill's edge instead of centering.
            .frame(minWidth: Self.pillW, alignment: .leading)
            .frame(height: focusMode ? Self.bannerH : Self.pillH)
            .background(track)
            // Constant outer layout box — the morphing capsule centers
            // inside it, so its y-mid never moves.
            .frame(height: Self.pillH)
        }
        .buttonStyle(.plain)
        .opacity(isInteractive ? 1.0 : 0.9)
        .accessibilityLabel(focusMode
            ? "Release focus mode"
            : (enabled ? "Disable Vibez" : "Enable Vibez"))
        .onChange(of: enabled) { _, _ in syncAccentOpacity() }
        .onChange(of: focusMode) { _, _ in syncAccentOpacity() }
    }

    /// Lit → show the accent at once (the seed pops in with the slide). Unlit
    /// → fade the whole fill out promptly via `offFadeAnimation`.
    private func syncAccentOpacity() {
        if accentLit {
            accentOpacity = 1
        } else {
            withAnimation(Self.offFadeAnimation) { accentOpacity = 0 }
        }
    }

    /// Track — a neutral capsule under the accent capsule; the accent is
    /// revealed by `AccentRevealMask` (geometry) gated by an opacity fade.
    /// Turning on, the fill seeds at the knob, stays pinned to it (no racing),
    /// and pulls to full as the knob lands on the right. Turning off, the fill
    /// fades out promptly (0.2s) as the knob slides back. Fully orange at
    /// rest-on, empty at rest-off.
    private var track: some View {
        ZStack {
            Capsule()
                .fill(theme.pillOff.shadow(
                    .inner(color: .black.opacity(0.18), radius: 3, y: 2)))

            Capsule()
                .fill(theme.pillGradient.shadow(
                    .inner(color: .white.opacity(0.18), radius: 0.5, y: 1)))
                .mask {
                    // Geometry only: fill pinned to the knob (seed → full).
                    // Same path both ways — off's disappearance is the opacity
                    // fade below, not the geometry. Animatable on `progress`.
                    AccentRevealMask(progress: (enabled || focusMode) ? 1 : 0)
                }
                // Opacity (not geometry) takes the fill to empty: ON shows it
                // at once (seed pops with the slide); OFF fades the whole fill
                // out promptly. Driven by syncAccentOpacity() on enabled /
                // focusMode change.
                .opacity(accentOpacity)
        }
        .shadow(
            color: showGlow ? theme.accent.opacity(focusMode ? 0.33 : (enabled ? 0.4 : 0.12)) : .clear,
            radius: focusMode ? 12 : (enabled ? 14 : 7)
        )
        .shadow(
            color: showGlow && (enabled || focusMode) ? theme.accentDeep.opacity(0.667) : .clear,
            radius: 12,
            y: focusMode ? 10 : 12
        )
        .animation(Self.slideAnimation, value: enabled)
    }

    /// Knob — plain white, slides edge to edge on the shared slide curve.
    private var knob: some View {
        Circle()
            .fill(.white)
            .frame(width: Self.knobSize, height: Self.knobSize)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
            .overlay(Circle().strokeBorder(.black.opacity(0.04), lineWidth: 1))
            .animation(Self.slideAnimation, value: enabled)
    }

    private var focusLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 14, weight: .bold))
            Text("Focus mode")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(1.1)
            Text("tap to release")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .opacity(0.85)
                .padding(.leading, 4)
        }
        .foregroundStyle(theme.onAccent)
        .lineLimit(1)
        .fixedSize()
    }

    private var knobX: CGFloat {
        enabled ? (Self.pillW - Self.knobSize - Self.knobPad) : Self.knobPad
    }
}

/// Mask for the accent capsule: a solid body with a **rounded leading cap**,
/// pinned to the knob. The cap uses the pill's own corner radius (`pillH/2`),
/// so the orange's front curves exactly like the knob and the pill's rounded
/// ends instead of cutting a flat vertical line — and at rest-on the cap lands
/// flush on the track's own right cap. The lead over the knob center grows
/// 0 → accentLead, so the fill sits at the knob (seed ≈ 0.2, nothing races
/// ahead) and only pulls past it near the end to reach full. The geometry
/// never empties (progress 0 = the seed at the knob); the host's opacity fade
/// takes it to empty on the way off. `Animatable` on `progress` so it shares
/// the knob's slide curve.
private struct AccentRevealMask: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// Apex (rightmost point) of the rounded cap. (A plain func, not inline in
    /// `body` — a top-level if/else there would be parsed as ViewBuilder
    /// content.)
    private static func solidEdge(progress: CGFloat, width: CGFloat) -> CGFloat {
        if progress >= 1 { return width }          // full
        // Apex trails the circle's front by a steady `knobPad` margin; the
        // lead grows 0 → accentLead, so the orange's front keeps that margin
        // off the circle (nothing races ahead) and only pulls the last few px
        // past it near the end to reach the pill edge. At progress 0 this is
        // the seed behind the knob front — the OPACITY (not the geometry) takes
        // it to empty, so off can retract here and then fade rather than
        // popping off-screen.
        return BigToggle.accentApexX(at: progress)
             + BigToggle.accentLead * progress
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let solid = Self.solidEdge(progress: progress, width: w)
            // Flat on the left (meets the track's own left cap), rounded on the
            // right with the pill's radius. Both trailing radii sum to the full
            // height, so the right edge is a true semicircle — a convex cap
            // matching the knob's curve — whose apex lands on `solid`.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: BigToggle.pillH / 2,
                topTrailingRadius: BigToggle.pillH / 2
            )
            .frame(width: solid, height: geo.size.height)
            .frame(width: w, height: geo.size.height, alignment: .leading)
        }
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
            .frame(height: 26)
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
            // Plain, borderless gear — no chip background.
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(theme.fg)
                    .frame(
                        width: TopBarLayout.settingsButtonSize,
                        height: TopBarLayout.settingsButtonSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open settings")
        }
        .padding(.horizontal, TopBarLayout.horizontalPadding)
        .padding(.top, TopBarLayout.topPadding)
        .padding(.bottom, TopBarLayout.bottomPadding)
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
    // Expanded selections render their member apps instead of the
    // category icon — see displayCategoryTokens.
    private var cats: [ActivityCategoryToken] { selection.displayCategoryTokens }
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
    /// `curl` test ping) fall back to Claude.
    static func source(for agent: VibezAgent?) -> Source {
        switch agent {
        case .claude: return .claude
        case .codex:  return .codex
        case nil:     return .claude
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
        return sid.isUsableSessionId
    }

    var body: some View {
        let row = HStack(alignment: .top, spacing: 10) {
            TriggerSourceBadge(source: event.source)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if event.needsReply {
                        Circle()
                            .fill(Color(hex: 0xf5c518))
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

private struct TriggerSourceBadge: View {
    let source: TriggerEvent.Source

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(source == .codex ? Color.white : Theme.claudeOrange)

            if source == .codex {
                StaticCodexBadgeLogo(size: 24)
            } else {
                StaticClaudeBadgeMascot(size: 18)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source == .codex ? "Codex" : "Claude Code")
    }
}

private struct StaticCodexBadgeLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            CodexBadgeCloudShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: 0xaab8ee),
                            Color(hex: 0x4968ff),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            GeometryReader { proxy in
                let unit = proxy.size.width / 24

                Path { path in
                    path.move(to: CGPoint(x: 7.4 * unit, y: 8.2 * unit))
                    path.addLine(to: CGPoint(x: 9.6 * unit, y: 12 * unit))
                    path.addLine(to: CGPoint(x: 7.4 * unit, y: 15.8 * unit))
                }
                .stroke(
                    .white,
                    style: StrokeStyle(
                        lineWidth: 1.7 * unit,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

                Capsule()
                    .fill(.white)
                    .frame(width: 5.8 * unit, height: 1.7 * unit)
                    .offset(x: 12.2 * unit, y: 14.9 * unit)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct CodexBadgeCloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 24
        var path = Path()

        path.addRoundedRect(
            in: CGRect(x: 4.1 * unit, y: 4.2 * unit, width: 15.8 * unit, height: 15.6 * unit),
            cornerSize: CGSize(width: 5.2 * unit, height: 5.2 * unit)
        )
        path.addEllipse(in: CGRect(x: 7.1 * unit, y: 0.7 * unit, width: 10.5 * unit, height: 10.5 * unit))
        path.addEllipse(in: CGRect(x: 13.3 * unit, y: 2.2 * unit, width: 9.8 * unit, height: 9.8 * unit))
        path.addEllipse(in: CGRect(x: 15.4 * unit, y: 7.2 * unit, width: 8.3 * unit, height: 9.1 * unit))
        path.addEllipse(in: CGRect(x: 12.7 * unit, y: 13.2 * unit, width: 9.2 * unit, height: 9.2 * unit))
        path.addEllipse(in: CGRect(x: 6.8 * unit, y: 14.0 * unit, width: 9.4 * unit, height: 9.4 * unit))
        path.addEllipse(in: CGRect(x: 1.0 * unit, y: 11.2 * unit, width: 9.5 * unit, height: 9.5 * unit))
        path.addEllipse(in: CGRect(x: 0.3 * unit, y: 5.4 * unit, width: 9.8 * unit, height: 9.8 * unit))
        path.addEllipse(in: CGRect(x: 3.0 * unit, y: 2.6 * unit, width: 9.2 * unit, height: 9.2 * unit))

        return path
    }
}

private struct StaticClaudeBadgeMascot: View {
    let size: CGFloat

    var body: some View {
        let height = size * 0.9
        let unit = size / 100

        ZStack(alignment: .topLeading) {
            ClaudeBodyShape()
                .fill(.white)
                .frame(width: size, height: height)

            Rectangle()
                .fill(Theme.claudeOrange)
                .frame(width: 12 * unit, height: 14 * unit)
                .offset(x: 22 * unit, y: 28 * unit)

            Rectangle()
                .fill(Theme.claudeOrange)
                .frame(width: 12 * unit, height: 14 * unit)
                .offset(x: 66 * unit, y: 28 * unit)
        }
        .frame(width: size, height: height, alignment: .topLeading)
    }
}

enum RecentTriggersLayout {
    static let collapsedReserveHeight: CGFloat = 220

    fileprivate static let collapsedHeight: CGFloat = 208
    fileprivate static let collapsedCornerRadius: CGFloat = 44
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
                                color: .black.opacity(0.28),
                                radius: isExpanded ? 12 : 24,
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

// MARK: - Focus mode

/// Soft pulsing accent glow placed behind the mascot while focused.
/// Purely decorative — never eats taps.
struct FocusHalo: View {
    let color: Color
    var size: CGFloat = 220
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.45), color.opacity(0.0)],
                    center: .center,
                    startRadius: 2,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .scaleEffect(pulse ? 1.08 : 0.92)
            .opacity(pulse ? 0.9 : 0.55)
            .blur(radius: 8)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .allowsHitTesting(false)
    }
}
