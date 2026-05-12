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
    let isInteractive: Bool

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
        .disabled(!isInteractive)
        .opacity(isInteractive ? 1.0 : 0.7)
        .accessibilityLabel(enabled ? "Disable Vibez" : "Enable Vibez")
    }

    private var knobX: CGFloat {
        enabled ? (pillW - knobSize - 8) : 8
    }
}

// MARK: - Notification setup (home screen prompt when ntfy URL is empty)

struct NotificationSetupCard: View {
    @Binding var ntfyURL: String
    @Bindable var notifyClient: NotifyClient
    let theme: Theme

    @State private var draft: String = ""
    @State private var verifying: Bool = false
    @State private var verifyError: String? = nil
    @State private var verifyTask: Task<Void, Never>? = nil
    @FocusState private var focused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSavedURL: String {
        ntfyURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save is enabled only when there's a new value to test AND we're
    /// not already verifying. The "trimmed != saved" gate doubles as
    /// the "you already tried this URL and it didn't work, change it
    /// before pressing Save again" gate — verifyError stays on screen
    /// to tell them why.
    private var saveable: Bool {
        !trimmedDraft.isEmpty
            && !verifying
            && trimmedDraft != trimmedSavedURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up notifications")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(theme.fg)

            Text("Run /vibez:setup in Claude Code on your Mac, then paste your URL here.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.fgMute)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if draft.isEmpty && !focused {
                        Text("https://ntfy.sh/…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(theme.fgFaint)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.fg)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { commit() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.bgChip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.hairline, lineWidth: 1)
                )

                Button(action: commit) {
                    Group {
                        if verifying {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(theme.onAccent)
                        } else {
                            Text("Save")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .tracking(1.6)
                                .foregroundStyle(saveable ? theme.onAccent : theme.fgFaint)
                        }
                    }
                    .frame(minWidth: 44)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill((saveable || verifying)
                                  ? AnyShapeStyle(theme.pillGradient)
                                  : AnyShapeStyle(theme.bgChip))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke((saveable || verifying) ? Color.clear : theme.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!saveable)
            }
            .onChange(of: focused) { _, newFocused in
                if !newFocused { commit() }
            }
            .onChange(of: draft) { _, _ in
                // User edited the draft — the previous error no longer
                // applies. Clear it so the failure indicator doesn't
                // shout at them while they're typing the fix.
                if verifyError != nil { verifyError = nil }
            }

            statusLine
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.hairline, lineWidth: 1)
        )
        .onDisappear {
            verifyTask?.cancel()
            verifyTask = nil
        }
    }

    /// Inline state under the input. Verify state wins; otherwise we
    /// surface the live notifyClient state so the user knows what's
    /// happening if a previously-saved URL has dropped.
    @ViewBuilder
    private var statusLine: some View {
        if verifying {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Verifying connection…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fgMute)
            }
        } else if let err = verifyError {
            Text(err)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.fgMute)
        } else if !trimmedSavedURL.isEmpty {
            switch notifyClient.state {
            case .connecting:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Connecting…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.fgMute)
                }
            case .error:
                Text("Connection lost — retrying…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fgMute)
            case .idle, .connected:
                EmptyView()
            }
        }
    }

    /// Kicks off a verify against the draft URL. Only writes `ntfyURL`
    /// (which is what unlocks the BigToggle) after the probe actually
    /// receives a frame from the server — so a junk URL never unlocks
    /// the toggle, and the card stays put with an error.
    private func commit() {
        let trimmed = trimmedDraft
        guard !trimmed.isEmpty else { return }
        guard !verifying else { return }
        guard trimmed != trimmedSavedURL else { return }

        verifyTask?.cancel()
        verifying = true
        verifyError = nil
        focused = false

        verifyTask = Task { @MainActor in
            let ok = await notifyClient.validate(urlString: trimmed)
            // The view may have been torn down (parent removed it
            // because state == .connected against the previous URL, or
            // user navigated away). Bail rather than mutate stale state.
            if Task.isCancelled { return }
            verifying = false
            if ok {
                // Only NOW does ntfyURL get the new value — the binding
                // is what flips the big toggle from locked to usable.
                ntfyURL = trimmed
            } else {
                verifyError = "Couldn't connect. Check the URL and try again."
            }
        }
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
            .foregroundStyle(listening ? AnyShapeStyle(theme.pillGradient) : AnyShapeStyle(theme.fgFaint))
            .shadow(color: listening ? theme.accentDeep.opacity(0.55) : .clear,
                    radius: listening ? 12 : 0, x: 0, y: 4)
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

    /// Determine which agent produced a ntfy message. Prefers the explicit
    /// "_vibez:agent" tag (set by recent plugin versions); falls back to
    /// sniffing "Claude" / "Codex" out of the title+body for older plugins
    /// or untagged third-party producers; finally falls back to the user's
    /// currently selected agent so a generic ping still picks a side.
    static func detectSource(title: String, body: String, agent: VibezAgent?, fallback: Agent) -> Source {
        if let agent {
            switch agent {
            case .claude: return .claude
            case .codex:  return .codex
            }
        }
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

    @State private var atTop = true
    @State private var atEnd = false

    // Fades follow the actual scroll geometry (atTop/atEnd come from
    // onScrollGeometryChange) rather than a row-count proxy — row heights
    // are variable since rows render a description line, so "more than 5
    // events" no longer maps to "content overflows."
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
                                    ignoredBySession: ignoredBySession(event),
                                    ignoredByName: ignoredByName(event),
                                    onIgnoreSession: { onIgnoreSession(event) },
                                    onIgnoreName: { onIgnoreName(event) },
                                    onUnignoreSession: { onUnignoreSession(event) },
                                    onUnignoreName: { onUnignoreName(event) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 260)
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
                        // Fixed-location stops with animated opacity at the
                        // edges — interpolating opacity is smoother than
                        // sliding stop positions, so the fade reads as a
                        // fade rather than a wipe.
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(showTopFade ? 0 : 1), location: 0.0),
                                .init(color: .black, location: 0.28),
                                .init(color: .black, location: 0.72),
                                .init(color: .black.opacity(showBottomFade ? 0 : 1), location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
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
