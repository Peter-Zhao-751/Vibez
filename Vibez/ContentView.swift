//
//  ContentView.swift
//  Vibez
//

import SwiftUI
import FamilyControls
import OSLog

private let handleIncomingLog = Logger(subsystem: "vibezlol.Vibez", category: "handleIncoming")

struct ContentView: View {
    @State private var manager: ScreenTimeManager
    // Singletons in prod so AppDelegate can deliver FCM pushes into the
    // same lastMessage → handleIncoming pipeline (notifyClient) and
    // restore the persisted Vibez ID at launch (registrar). Both are
    // @Observable, so SwiftUI re-renders on their state changes
    // without @State. Injectable for previews.
    private let notifyClient: NotifyClient
    private let registrar: PushTokenRegistrar
    @State private var triggerStore: TriggerStore
    @State private var ignoreStore: IgnoreStore
    @State private var analytics: AnalyticsTracker

    @MainActor
    init(
        manager: ScreenTimeManager? = nil,
        notifyClient: NotifyClient? = nil,
        registrar: PushTokenRegistrar? = nil,
        triggerStore: TriggerStore? = nil,
        ignoreStore: IgnoreStore? = nil,
        analytics: AnalyticsTracker? = nil
    ) {
        // Default-arg expressions evaluate at the caller's isolation, so
        // any defaults that touch @MainActor types (the whole project,
        // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor) have to be built inside
        // this @MainActor body instead.
        _manager = State(initialValue: manager ?? ScreenTimeManager())
        self.notifyClient = notifyClient ?? .shared
        self.registrar = registrar ?? .shared
        _triggerStore = State(initialValue: triggerStore ?? TriggerStore())
        _ignoreStore = State(initialValue: ignoreStore ?? IgnoreStore())
        _analytics = State(initialValue: analytics ?? AnalyticsTracker())
    }

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.agent") private var agentRaw = Agent.claude.rawValue
    @AppStorage("vibez.blockSeconds.needsInput") private var blockSecondsNeedsInput = 900
    @AppStorage("vibez.blockSeconds.done") private var blockSecondsDone = 30
    @AppStorage("vibez.overlayOrder") private var overlayOrderRaw = OverlayOrder.stack.rawValue
    @AppStorage("vibez.allowDismiss") private var allowDismiss = true

    @Environment(\.colorScheme) private var systemColorScheme

    @State private var overlayQueue: [NtfyMessage] = []   // newest first
    @State private var showSettings = false
    @State private var toggleShake = 0
    @State private var setupShake = 0
    @State private var setupCardMounted = true
    @State private var setupCardVisible = true
    @State private var unlockedLayoutExpanded = false
    @State private var setupTransitionGeneration = 0

    private var agent: Agent {
        Agent(rawValue: agentRaw) ?? .claude
    }

    private var appearance: AppearancePref {
        AppearancePref(rawValue: appearanceRaw) ?? .system
    }

    private var effectiveDark: Bool {
        appearance.effectiveDark(systemIsDark: systemColorScheme == .dark)
    }

    private var theme: Theme {
        Theme.make(agent: agent, dark: effectiveDark)
    }

    private var topOverlayMessage: NtfyMessage? { overlayQueue.first }

    private var overlayOrder: OverlayOrder {
        OverlayOrder(rawValue: overlayOrderRaw) ?? .stack
    }

    private var setupNeeded: Bool {
        // We're set up when the user has entered a Vibez ID AND the
        // Firebase backend has accepted it (state == .registered).
        // Anything else — no ID, registering, error — keeps the setup
        // card visible.
        registrar.vibezId.isEmpty || registrar.state != .registered
    }

    /// Pick the block duration based on what kind of ping landed:
    /// `done` → short timer (default 30s) just nudges you to glance at
    /// the result. Anything else (needs-input, replied, untagged) →
    /// long timer (default 15m) keeps the shield up while Claude waits.
    /// `replied` is unreachable on the trigger path (it carries
    /// `shield: .off`), but listing it explicitly avoids a `default` arm.
    private func durationFor(_ msg: NtfyMessage) -> Int {
        switch msg.event {
        case .done:                 return blockSecondsDone
        case .needsInput, .replied: return blockSecondsNeedsInput
        case .none:                 return blockSecondsNeedsInput
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.bg
                .ignoresSafeArea()

            mainScreen
                .ignoresSafeArea(edges: .bottom)

            recentTriggersSheet
                .ignoresSafeArea(edges: .bottom)
                .zIndex(2)

            if let msg = topOverlayMessage {
                BlockedOverlay(
                    agent: agent,
                    theme: theme,
                    dark: effectiveDark,
                    message: msg,
                    expiresAt: msg.sessionId.flatMap { manager.pendingTriggers[$0]?.expiresAt },
                    stackDepth: overlayQueue.count,
                    allowDismiss: allowDismiss,
                    onDismiss: dismissTopOverlay,
                    onExpire: expireTopOverlay
                )
                .id(msg.id)
                .transition(.opacity)
                .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: effectiveDark)
        .animation(.easeInOut(duration: 0.4), value: agent)
        .onAppear {
            appearance.applyToWindows()
            syncSetupPresentation(animated: false)
        }
        .onChange(of: appearance) { _, newPref in
            newPref.applyToWindows()
        }
        .task {
            // Request notification permission early — the setup card
            // is still visible while iOS shows the system prompt, so
            // the user can do both in parallel.
            await NotifyClient.requestAuthorization()
            if manager.authState == .notDetermined {
                await manager.requestAuthorization()
            }
        }
        .onChange(of: setupNeeded) { _, _ in
            syncSetupPresentation(animated: true)
        }
        .onChange(of: notifyClient.lastMessage) { _, newValue in
            guard let newValue else { return }
            handleIncoming(newValue)
        }
        .onChange(of: manager.pendingTriggers) { _, newPending in
            // A non-top entry's per-session timer expired in the
            // background. Drop those queue entries so popping the top
            // doesn't reveal a stale entry that would immediately fire
            // onExpire. Untagged pings (nil sessionId) aren't reconciled
            // — they have no backing trigger and are removed only by
            // the Dismiss button.
            overlayQueue.removeAll { msg in
                guard let sid = msg.sessionId, !sid.isEmpty, sid != "nosid"
                else { return false }
                return newPending[sid] == nil
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                isPresented: $showSettings,
                manager: manager,
                notifyClient: notifyClient,
                registrar: registrar,
                triggerStore: triggerStore,
                ignoreStore: ignoreStore
            )
        }
    }

    @ViewBuilder
    private var mainScreen: some View {
        VStack(spacing: 0) {
            TopBar(
                isDark: effectiveDark,
                theme: theme,
                onOpenSettings: { showSettings = true }
            )

            GeometryReader { proxy in
                homeContent(
                    availableHeight: proxy.size.height,
                    availableWidth: proxy.size.width
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }

            Color.clear
                .frame(height: RecentTriggersLayout.collapsedReserveHeight)
        }
    }

    private var recentTriggersSheet: some View {
        RecentTriggersSection(
            events: triggerStore.events,
            theme: theme,
            ignoreStore: ignoreStore,
            onIgnoreSession: { event in
                guard let sid = event.sessionId else { return }
                let name = displayName(for: event)
                ignoreStore.ignoreSession(sessionId: sid, name: name)
            },
            onIgnoreName: { event in
                let name = displayName(for: event)
                ignoreStore.ignoreName(name)
            },
            onUnignoreSession: { event in
                guard let sid = event.sessionId,
                      let rule = ignoreStore.sessionRuleMatching(sessionId: sid)
                else { return }
                ignoreStore.remove(ruleId: rule.id)
            },
            onUnignoreName: { event in
                let name = displayName(for: event)
                guard let rule = ignoreStore.nameRuleMatching(name: name)
                else { return }
                ignoreStore.remove(ruleId: rule.id)
            }
        )
    }

    /// Best display name for an ignore rule sourced from a Recent
    /// triggers row. Title wins; falls back to the body label so older
    /// title-less events still produce a usable rule.
    private func displayName(for event: TriggerEvent) -> String {
        if let t = event.title, !t.isEmpty { return t }
        return event.label
    }

    private func recordTrigger(from message: NtfyMessage) {
        let source = TriggerEvent.source(for: message.agent, fallback: agent)
        triggerStore.record(
            TriggerEvent(
                receivedAt: message.receivedAt,
                source: source,
                title: message.title,
                label: message.body,
                blockSeconds: durationFor(message),
                sessionId: message.sessionId,
                needsReply: message.needsReply
            )
        )
    }

    /// Tapping the locked toggle: shake the toggle first, then the
    /// setup card a beat later, so the eye is led from "this didn't
    /// work" to "fix it here." Delay is a hair shorter than the toggle
    /// shake so the two feel like one continuous gesture.
    private func bounceToShowSetup() {
        toggleShake &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            setupShake &+= 1
        }
    }

    /// The setup card owns enough height that removing it and expanding
    /// the unlocked layout in one animation looks like a jump. Fade the
    /// card first while it still occupies space; then, a beat later,
    /// let the mascot grow and move the controls down toward the sheet.
    private func syncSetupPresentation(animated: Bool) {
        setupTransitionGeneration &+= 1
        let generation = setupTransitionGeneration

        if setupNeeded {
            if animated {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    unlockedLayoutExpanded = false
                    setupCardMounted = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    guard generation == setupTransitionGeneration, setupNeeded else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        setupCardVisible = true
                    }
                }
            } else {
                unlockedLayoutExpanded = false
                setupCardMounted = true
                setupCardVisible = true
            }
        } else {
            if animated {
                withAnimation(.easeInOut(duration: 0.44)) {
                    setupCardVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) {
                    guard generation == setupTransitionGeneration, !setupNeeded else { return }
                    withAnimation(.spring(response: 0.58, dampingFraction: 0.86)) {
                        setupCardMounted = false
                        unlockedLayoutExpanded = true
                    }
                }
            } else {
                setupCardVisible = false
                setupCardMounted = false
                unlockedLayoutExpanded = true
            }
        }
    }

    /// Tap Dismiss on the top overlay: resolve its trigger and pop.
    /// The next-most-recent unresolved block (if any) takes its place.
    private func dismissTopOverlay() {
        guard let msg = overlayQueue.first else { return }
        if let sid = msg.sessionId, !sid.isEmpty, sid != "nosid" {
            manager.resolveTrigger(sessionId: sid)
            triggerStore.clearNeedsReply(forSession: sid)
        }
        withAnimation(.easeInOut(duration: 0.32)) {
            _ = overlayQueue.removeFirst()
        }
    }

    /// Countdown on the top overlay reached 0. The trigger has already
    /// auto-pruned in ScreenTimeManager; just clear the recent-trigger
    /// dot and pop.
    private func expireTopOverlay() {
        guard let msg = overlayQueue.first else { return }
        if let sid = msg.sessionId, !sid.isEmpty, sid != "nosid" {
            triggerStore.clearNeedsReply(forSession: sid)
        }
        withAnimation(.easeInOut(duration: 0.32)) {
            _ = overlayQueue.removeFirst()
        }
    }

    /// Push a fresh ping onto the queue. If an entry exists with the
    /// same sessionId, remove it first — the new ping carries the
    /// latest state of that conversation, so the old entry is stale.
    /// Where the new entry lands depends on the user's overlayOrder:
    ///   - `.stack` (LIFO): insert at the front so it surfaces on top.
    ///   - `.queue` (FIFO): append at the back so the oldest pending
    ///     block stays visible until dismissed.
    private func enqueueOverlay(_ message: NtfyMessage) {
        if let sid = message.sessionId, !sid.isEmpty, sid != "nosid" {
            overlayQueue.removeAll { $0.sessionId == sid }
        }
        switch overlayOrder {
        case .stack: overlayQueue.insert(message, at: 0)
        case .queue: overlayQueue.append(message)
        }
    }

    private func handleIncoming(_ message: NtfyMessage) {
        let shieldStr = message.shield.map { $0.rawValue } ?? "nil"
        let armedStr = manager.armed ? "armed" : "disarmed"
        handleIncomingLog.info(
            "enter: shield=\(shieldStr, privacy: .public) \(armedStr, privacy: .public) session=\(message.sessionId ?? "nil", privacy: .public)"
        )

        // Tracker is a passive observer — fires for every incoming
        // message, before any of the gating below. shield:off pings
        // (user replies) and pings that arrive while Vibez is unarmed
        // both still count as activity for today's stats.
        analytics.record(message)

        // shield:off (the user just replied in Claude) is a control
        // signal — never surface it as a notification, and only act on
        // it if we actually have something to resolve. Handled first so
        // it bypasses the toggle gate below: a reply that lands while
        // the user has just flipped the toggle off is harmless to
        // process (resolveTrigger is a no-op when the session isn't
        // pending) and we don't want stale state to linger.
        if message.shield == .off {
            handleIncomingLog.info("branch: shield=off → resolve trigger only")
            if let sid = message.sessionId {
                manager.resolveTrigger(sessionId: sid)
                triggerStore.clearNeedsReply(forSession: sid)
                withAnimation(.easeInOut(duration: 0.32)) {
                    overlayQueue.removeAll { $0.sessionId == sid }
                }
            }
            return
        }

        // Toggle off → Vibez is dormant. Don't notify, don't show the
        // overlay, don't add a trigger — the user has explicitly told us
        // to stay out of the way.
        guard manager.armed else {
            handleIncomingLog.info("branch: disarmed → drop")
            return
        }

        switch message.shield {
        case .on:
            handleIncomingLog.info("branch: shield=on → record trigger + maybe shield/overlay")
            recordTrigger(from: message)

            if let sid = message.sessionId,
               !sid.isEmpty, sid != "nosid" {
                if ignoreStore.contains(sessionId: sid, name: message.title) {
                    handleIncomingLog.info("→ ignored, no overlay/shield")
                    // Ignored conversation — keep the row in Recent
                    // triggers (dimmed) but skip the shield and the
                    // overlay. Refresh the cached name so Settings
                    // shows the latest title.
                    ignoreStore.refreshName(
                        sessionId: sid,
                        name: message.title
                    )
                    return
                }
                manager.addTrigger(sessionId: sid, durationSeconds: durationFor(message))
                // Bump per-app block counts only when the shield
                // actually engages — same guard as addTrigger above.
                analytics.recordShieldActivation(
                    applicationTokens: manager.selection.applicationTokens
                )
            }
            manager.publishShieldContext(from: message)

            notifyClient.scheduleLocalNotification(message)
            withAnimation(.easeInOut(duration: 0.32)) {
                enqueueOverlay(message)
            }

        case .none:
            handleIncomingLog.info("branch: shield=nil → record trigger + overlay")
            // Plain push (test ping, third-party producer, etc.) — show
            // the overlay as we always did.
            recordTrigger(from: message)
            notifyClient.scheduleLocalNotification(message)
            withAnimation(.easeInOut(duration: 0.32)) {
                enqueueOverlay(message)
            }

        case .off:
            // Unreachable — handled above.
            break
        }
    }

    @ViewBuilder
    private func homeContent(availableHeight: CGFloat, availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            if unlockedLayoutExpanded {
                Spacer(minLength: 0)
            }

            VStack(spacing: 1.5) {
                MascotForAgent(
                    agent: agent,
                    listening: manager.armed,
                    size: mascotSize(for: availableHeight),
                    gap: 4
                )
                .offset(y: mascotOffset())

                // Ground line — solid, ~60% of available width, sits
                // just under the mascot's feet so it reads as standing
                // on the ground.
                Rectangle()
                    .fill(theme.fgMute.opacity(0.45))
                    .frame(width: availableWidth * 0.6, height: 1.5)
            }
            .frame(
                height: mascotFrameHeight(for: availableHeight),
                alignment: unlockedLayoutExpanded ? .center : .bottom
            )
            .padding(.horizontal, 10)
            .padding(.top, unlockedLayoutExpanded ? 0 : 8)
            .padding(.bottom, unlockedLayoutExpanded ? 0 : 18)

            if unlockedLayoutExpanded {
                Spacer(minLength: 0)
            }

            BigToggle(
                enabled: Binding(
                    get: { manager.armed && !setupNeeded },
                    set: { manager.setArmed($0) }
                ),
                agent: agent,
                theme: theme,
                isInteractive: !registrar.vibezId.isEmpty,
                onLockedTap: bounceToShowSetup
            )
            // Tight gap to the setup card so the locked toggle visually
            // leads into "fix it here"; more breathing room when the
            // toggle stands alone above the blocking panel below.
            .padding(.bottom, setupCardMounted ? 14 : 32)
            .shake(trigger: toggleShake)

            if setupCardMounted {
                VibezSetupCard(
                    registrar: registrar,
                    theme: theme
                )
                .opacity(setupCardVisible ? 1 : 0)
                .allowsHitTesting(setupCardVisible)
                .accessibilityHidden(!setupCardVisible)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .shake(trigger: setupShake, amount: 5, duration: 0.84)
            }

            AnalyticsPanel(
                analytics: analytics,
                triggerStore: triggerStore,
                theme: theme,
                onSelectMostBlocked: { showSettings = true }
            )
            .padding(.horizontal, 10)
            .padding(.bottom, unlockedLayoutExpanded ? 10 : 12)

            if !unlockedLayoutExpanded {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func mascotOffset() -> CGFloat {
        unlockedLayoutExpanded ? -(TopBarLayout.bottomPadding / 2) : 0
    }

    private func mascotSize(for availableHeight: CGFloat) -> CGFloat {
        if unlockedLayoutExpanded {
            switch agent {
            case .claude:
                return min(140, max(128, availableHeight * 0.22))
            case .codex:
                return min(130, max(120, availableHeight * 0.20))
            case .both:
                return min(128, max(118, availableHeight * 0.20))
            }
        }
        return agent == .both ? 92 : 100
    }

    private func mascotFrameHeight(for availableHeight: CGFloat) -> CGFloat {
        if unlockedLayoutExpanded {
            switch agent {
            case .claude:
                return min(180, max(158, availableHeight * 0.27))
            case .codex:
                return min(188, max(164, availableHeight * 0.29))
            case .both:
                return min(174, max(154, availableHeight * 0.27))
            }
        }
        return 110
    }
}

#Preview("bruh") {
    ContentView()
}

#if DEBUG

// MARK: - Preview support
//
// Each preview wires up a fully-seeded environment so the home screen
// renders as if Vibez had been running for a while. Three knobs:
//   • seedAppStorageDefaults() pre-fills the agent + appearance
//     @AppStorage values.
//   • PushTokenRegistrar.previewRegistrar() bypasses the FCM round-trip
//     and pins a Vibez ID + a `.registered` state, the second half of
//     setupNeeded.
//   • ScreenTimeManager.previewManager(...) sets armed and any pending
//     triggers; the rest of the store (selection, auth) is left to the
//     real init (no-op on the simulator).

private func seedAppStorageDefaults(
    agent: Agent = .claude,
    appearance: AppearancePref = .dark
) {
    let d = UserDefaults.standard
    d.set(agent.rawValue, forKey: "vibez.agent")
    d.set(appearance.rawValue, forKey: "vibez.appearance")
}

private func previewTrigger(
    minutesAgo: Int,
    source: TriggerEvent.Source,
    title: String,
    label: String,
    blockSeconds: Int = 900,
    needsReply: Bool = false,
    repliedAfterSeconds: Int? = nil
) -> TriggerEvent {
    let receivedAt = Date().addingTimeInterval(-Double(minutesAgo) * 60)
    return TriggerEvent(
        receivedAt: receivedAt,
        source: source,
        title: title,
        label: label,
        blockSeconds: blockSeconds,
        sessionId: "preview-\(UUID().uuidString.prefix(8))",
        needsReply: needsReply,
        repliedAt: repliedAfterSeconds.map { receivedAt.addingTimeInterval(Double($0)) }
    )
}

private func previewTriggerStore(events: [TriggerEvent]) -> TriggerStore {
    let store = TriggerStore()
    store.clear()
    // Insert oldest first so the resulting `events` array has newest at
    // index 0, which is the natural order downstream code expects.
    for event in events.sorted(by: { $0.receivedAt < $1.receivedAt }) {
        store.record(event)
    }
    return store
}

/// Pre-bakes a DailyStats JSON into UserDefaults so the analytics panel
/// shows non-zero counters without having to replay messages. Per-app
/// block counts are left empty — ApplicationToken can't be synthesized
/// from outside Family Controls, so the "most blocked" tile renders the
/// em-dash placeholder.
private func previewAnalytics(
    pings: Int,
    chats: Int,
    replies: Int,
    replyLengths: [Int] = []
) -> AnalyticsTracker {
    let stats = DailyStats(
        date: Calendar.current.startOfDay(for: Date()),
        conversationIds: Set((0..<chats).map { "preview-chat-\($0)" }),
        responseCount: replies,
        responseLengths: replyLengths,
        pingCount: pings,
        appBlockCounts: [:]
    )
    if let data = try? JSONEncoder().encode(stats) {
        UserDefaults.standard.set(data, forKey: "vibez.analytics.v1")
    }
    return AnalyticsTracker()
}

private let previewClaudeTitles: [(String, String)] = [
    ("Refactor blocking panel", "Wrapped the panel in a lazy stack and trimmed the unused gradient. Tests pass."),
    ("Investigate WebSocket disconnects", "Reconnect logic is dropping the second frame on iOS 17 — want me to add a retry guard?"),
    ("Ship the Q4 changelog", "Want me to bundle the design-system entries under a single section, or keep them split out?"),
    ("Wire up SSE handler", "Need confirmation before I rip out the polling fallback."),
    ("Trace the analytics rollover", "Stats persisted across midnight on the simulator — added a regression test."),
    ("Audit Vibez entitlements", "Distribution request needs the family-controls justification — should I draft the copy?"),
    ("Migrate trigger store to v2", "Old persisted events decode fine. Ready to remove the v1 fallback?"),
    ("Plan plugin distribution", "Permission required to run `npm install` in the plugin package."),
    ("Profile blocked overlay", "Time-to-first-frame dropped from 180ms to 42ms after the GeometryReader rip-out."),
    ("Fix App Group write race", "Two writers were racing on `shieldState`. Want a serial queue or a lock?"),
    ("Document hook env-var quirks", "Wrote up the `${VAR}` vs `${VAR:-fallback}` gotcha in CLAUDE.md."),
    ("Bump iOS deploy target", "Ready to set it to 17.0 and drop the availability checks?"),
]

private let previewCodexTitles: [(String, String)] = [
    ("Rescue plan: stale shield", "Manager carried `shieldApplied=true` across an unblock. Reset hook proposed."),
    ("Rebuild ShieldCard renderer", "Want me to swap ImageRenderer for a UIGraphicsImageRenderer pass?"),
    ("Diagnose ntfy reconnect storm", "Backoff was 3s flat — bumped to exponential with jitter."),
    ("Codex hook permission probe", "Need approval to write `~/.claude/hooks/`."),
    ("Sweep dead code in Components", "Found 4 unused helpers. Safe to delete?"),
    ("Audit MainActor isolation", "Three call sites missed `@MainActor`. Patch ready for review."),
    ("Verify SettingsView regression", "Toggle survived a force-quit on the simulator. Want me to add a snapshot test?"),
    ("Plan VibezShield asset sync", "Codex avatar copy step is fragile. Suggesting a build phase."),
]

@MainActor
private func previewContent(
    vibezId: String = "moss-pine-fox-jazz",
    registrarState: PushTokenRegistrar.State = .registered,
    agent: Agent = .claude,
    appearance: AppearancePref = .dark,
    armed: Bool = true,
    pendingTriggers: [PendingTrigger] = [],
    events: [TriggerEvent] = [],
    analytics: AnalyticsTracker? = nil
) -> some View {
    let analytics = analytics ?? AnalyticsTracker()
    seedAppStorageDefaults(agent: agent, appearance: appearance)
    return ContentView(
        manager: ScreenTimeManager.previewManager(
            armed: armed,
            pendingTriggers: pendingTriggers
        ),
        notifyClient: NotifyClient.previewClient(),
        registrar: PushTokenRegistrar.previewRegistrar(
            vibezId: vibezId,
            state: registrarState
        ),
        triggerStore: previewTriggerStore(events: events),
        ignoreStore: IgnoreStore(),
        analytics: analytics
    )
    .preferredColorScheme(appearance == .light ? .light : .dark)
}

#Preview("Paired · ready · dark") {
    // Right after the user pastes a working Vibez ID. Setup card has
    // animated out, toggle is interactive but still OFF. Nothing else has
    // happened yet — no triggers, no analytics. This is the "everything
    // is wired up and ready" empty state.
    previewContent(
        armed: false,
        analytics: previewAnalytics(pings: 0, chats: 0, replies: 0)
    )
}

#Preview("Armed · listening · dark") {
    // Toggle flipped ON, mascot is in its listening pose, but no pings
    // have landed yet. Same blank Recent triggers sheet as the idle
    // state, but the analytics panel still shows zeros — Vibez is
    // armed, just waiting.
    previewContent(
        armed: true,
        analytics: previewAnalytics(pings: 0, chats: 0, replies: 0)
    )
}

#Preview("Recent triggers · dark") {
    // A full Recent triggers list — collapsed sheet shows the top three,
    // with the rest available on expand. Mix of replied/pending and a
    // Codex row so the sheet shows both accent colors.
    let events: [TriggerEvent] = [
        previewTrigger(minutesAgo: 1,   source: .claude,
                       title: previewClaudeTitles[0].0, label: previewClaudeTitles[0].1,
                       needsReply: true),
        previewTrigger(minutesAgo: 6,   source: .claude,
                       title: previewClaudeTitles[1].0, label: previewClaudeTitles[1].1,
                       repliedAfterSeconds: 142),
        previewTrigger(minutesAgo: 22,  source: .codex,
                       title: previewCodexTitles[0].0, label: previewCodexTitles[0].1,
                       repliedAfterSeconds: 38),
        previewTrigger(minutesAgo: 41,  source: .claude,
                       title: previewClaudeTitles[2].0, label: previewClaudeTitles[2].1,
                       repliedAfterSeconds: 95),
        previewTrigger(minutesAgo: 84,  source: .claude,
                       title: previewClaudeTitles[3].0, label: previewClaudeTitles[3].1,
                       blockSeconds: 30),
        previewTrigger(minutesAgo: 132, source: .codex,
                       title: previewCodexTitles[1].0, label: previewCodexTitles[1].1,
                       repliedAfterSeconds: 220),
        previewTrigger(minutesAgo: 175, source: .claude,
                       title: previewClaudeTitles[4].0, label: previewClaudeTitles[4].1,
                       repliedAfterSeconds: 60),
        previewTrigger(minutesAgo: 240, source: .claude,
                       title: previewClaudeTitles[5].0, label: previewClaudeTitles[5].1,
                       repliedAfterSeconds: 410),
        previewTrigger(minutesAgo: 310, source: .codex,
                       title: previewCodexTitles[2].0, label: previewCodexTitles[2].1,
                       repliedAfterSeconds: 18),
        previewTrigger(minutesAgo: 405, source: .claude,
                       title: previewClaudeTitles[6].0, label: previewClaudeTitles[6].1,
                       repliedAfterSeconds: 70),
    ]
    return previewContent(
        armed: true,
        events: events,
        analytics: previewAnalytics(
            pings: 28,
            chats: 9,
            replies: 7,
            replyLengths: [42, 78, 110, 64, 130, 88, 92]
        )
    )
}

#Preview("Busy day · Claude · dark") {
    // Everything: armed, a block in progress for one session, 12 recent
    // triggers across the day, strong analytics. This is the "you've
    // been pairing with Claude all afternoon" view.
    let active = PendingTrigger(
        sessionId: "preview-active-session",
        addedAt: Date().addingTimeInterval(-90),
        durationSeconds: 900
    )
    let events: [TriggerEvent] = (0..<12).map { i in
        let (title, label) = previewClaudeTitles[i % previewClaudeTitles.count]
        return previewTrigger(
            minutesAgo: i == 0 ? 1 : (i * 17),
            source: i % 4 == 3 ? .codex : .claude,
            title: title,
            label: label,
            needsReply: i == 0,
            repliedAfterSeconds: i == 0 ? nil : 30 + (i * 22)
        )
    }
    return previewContent(
        armed: true,
        pendingTriggers: [active],
        events: events,
        analytics: previewAnalytics(
            pings: 64,
            chats: 14,
            replies: 11,
            replyLengths: [40, 62, 110, 88, 56, 130, 74, 92, 48, 102, 80]
        )
    )
}

#Preview("Busy day · Codex · dark") {
    // Same shape as the Claude variant but with the Codex accent and a
    // higher proportion of `.codex` rows.
    let active = PendingTrigger(
        sessionId: "preview-codex-active",
        addedAt: Date().addingTimeInterval(-180),
        durationSeconds: 900
    )
    let events: [TriggerEvent] = (0..<11).map { i in
        let pool = i % 3 == 0 ? previewClaudeTitles : previewCodexTitles
        let (title, label) = pool[i % pool.count]
        return previewTrigger(
            minutesAgo: i == 0 ? 3 : (i * 21),
            source: i % 3 == 0 ? .claude : .codex,
            title: title,
            label: label,
            needsReply: i == 0,
            repliedAfterSeconds: i == 0 ? nil : 45 + (i * 19)
        )
    }
    return previewContent(
        agent: .codex,
        armed: true,
        pendingTriggers: [active],
        events: events,
        analytics: previewAnalytics(
            pings: 51,
            chats: 12,
            replies: 9,
            replyLengths: [56, 88, 120, 72, 64, 96, 80, 110, 48]
        )
    )
}

#endif
