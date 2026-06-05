//
//  ContentView.swift
//  Vibez
//

import SwiftUI
import FamilyControls
import UIKit
import OSLog

private let handleIncomingLog = Logger(subsystem: "vibezlol.Vibez", category: "handleIncoming")

struct ContentView: View {
    @State private var manager: ScreenTimeManager
    // @State-wrapped on purpose. With a plain `private let`, SwiftUI
    // doesn't reliably hook the @Observable into this view's render
    // dependency graph, so .onChange(of: notifyClient.lastMessage)
    // silently stops firing and handleIncoming never runs. @State on
    // an @Observable singleton is the canonical pattern.
    @State private var notifyClient: NotifyClient
    @State private var registrar: PushTokenRegistrar
    @State private var triggerStore: TriggerStore
    @State private var ignoreStore: IgnoreStore
    @State private var analytics: AnalyticsTracker
    @State private var onboarding: OnboardingState

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
        // .shared for the singletons so AppDelegate / NotifyClient and
        // this view operate on the same state. Previews pass explicit
        // instances and remain isolated from prod.
        let reg = registrar ?? .shared
        let mgr = manager ?? .shared
        _manager = State(initialValue: mgr)
        _onboarding = State(initialValue: OnboardingState(manager: mgr, registrar: reg))
        _notifyClient = State(initialValue: notifyClient ?? .shared)
        _registrar = State(initialValue: reg)
        _triggerStore = State(initialValue: triggerStore ?? TriggerStore())
        _ignoreStore = State(initialValue: ignoreStore ?? .shared)
        _analytics = State(initialValue: analytics ?? .shared)
        // Seed the setup-presentation layout from the live pairing state
        // so frame 1 already shows the right arrangement. Hardcoded
        // "setup card up, layout compact" defaults forced a paired cold
        // start through a one-frame reflow in .onAppear — the mascot
        // snapped to center invisibly, but the hint rode its private
        // caption animation through the move and visibly slid in from
        // above, out of sync with the mascot.
        let needsSetup = Self.setupNeeded(for: reg)
        _setupCardMounted = State(initialValue: needsSetup)
        _setupCardVisible = State(initialValue: needsSetup)
        _unlockedLayoutExpanded = State(initialValue: !needsSetup)
    }

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.agent") private var agentRaw = Agent.claude.rawValue
    @AppStorage("vibez.blockSeconds.needsInput") private var blockSecondsNeedsInput = 900
    @AppStorage("vibez.blockSeconds.done") private var blockSecondsDone = 30
    @AppStorage("vibez.overlayOrder") private var overlayOrderRaw = OverlayOrder.stack.rawValue
    @AppStorage("vibez.allowDismiss") private var allowDismiss = true
    /// Whether agent pings surface as an OS banner + sound. When off,
    /// blocks still engage; the push just arrives silently (passive) in
    /// Notification Center. Mirrored to the App Group by ScreenTimeManager
    /// so VibezPushService honors it on the background path too.
    @AppStorage("vibez.notifyBanners") private var notifyBanners = true
    /// Whether the "tap to enter focus mode" hint shows under the mascot.
    /// Off → the hint is removed (not just faded) and the hero keeps half
    /// the hint's height as padding so the mascot doesn't drop all the way
    /// onto the toggle's gap. Default on. Mirrored in SettingsView.
    @AppStorage("vibez.showFocusHint") private var showFocusHint = true
    /// Set when the user finishes the walkthrough (or a launch check
    /// finds setup already complete). A completed install never shows
    /// onboarding off a single failing cold-launch read — Family
    /// Controls can spuriously report .notDetermined right after
    /// process start, which used to flash the flow at fully-set-up
    /// users. Genuine revocations still re-present after the
    /// settle-recheck confirms them.
    @AppStorage("vibez.onboardingCompleted") private var onboardingCompleted = false

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var overlayQueue: [NtfyMessage] = []   // order depends on overlayOrder — see enqueueOverlay
    @State private var showSettings = false
    /// Drives the system app picker presented straight from the mascot
    /// tap when no apps are selected yet (instead of bouncing to
    /// Settings). See `toggleFocusMode` / `pickAppsThenFocus`.
    @State private var pickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()
    /// True while the picker was opened by a focus-mode tap, so once the
    /// user actually selects apps we engage focus mode for them rather
    /// than making them tap the mascot a second time.
    @State private var focusAfterPick = false
    @State private var toggleShake = 0
    @State private var setupShake = 0
    @State private var onboardingPresented = false
    // Seeded in init from the pairing state — see the note there.
    @State private var setupCardMounted: Bool
    @State private var setupCardVisible: Bool
    @State private var unlockedLayoutExpanded: Bool
    @State private var setupTransitionGeneration = 0
    /// Tracks which incoming push id we've already routed through
    /// handleIncoming. Needed because SwiftUI's .onChange doesn't fire
    /// for changes that landed while the view wasn't actively observing
    /// (e.g. push processed by AppDelegate while the app was suspended).
    /// Pair with .onAppear so a push seen during background-wake gets
    /// reprocessed once the view comes back.
    @State private var lastProcessedMessageId: String?

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
        Theme.make(agent: agent)
    }

    private var topOverlayMessage: NtfyMessage? { overlayQueue.first }

    private var overlayOrder: OverlayOrder {
        OverlayOrder(rawValue: overlayOrderRaw) ?? .stack
    }

    private var setupNeeded: Bool {
        Self.setupNeeded(for: registrar)
    }

    /// Show the setup card only when there's nothing to work with or
    /// something actually failed: no Vibez ID yet, or the backend
    /// rejected the registration. Transient in-flight states (waiting
    /// for the FCM token, registering) keep the home unlocked — the
    /// card would otherwise flash on every cold launch while the
    /// stored ID re-registers. Static so init can seed the layout
    /// state from the same rule before the first render.
    private static func setupNeeded(for registrar: PushTokenRegistrar) -> Bool {
        if registrar.vibezId.isEmpty { return true }
        if case .error = registrar.state { return true }
        return false
    }

    private static var isRunningInPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
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

            topGlow

            ActiveBackdrop(accent: theme.accent, active: manager.armed)
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
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            syncSetupPresentation(animated: false)
            // Catch pushes that landed via AppDelegate while the view
            // wasn't actively observing — .onChange below won't fire
            // for those because the value was set before subscription.
            // Also drain any NSE-written push file from the App Group
            // so background-engaged blocks get an in-app overlay on
            // first launch / cold start (not just on subsequent
            // scenePhase transitions). Reload pendingTriggers *first*
            // so handleIncoming (and subsequent user actions like
            // Dismiss) see the NSE-added trigger instead of a stale
            // empty in-memory dict.
            manager.reloadFromAppGroup()
            notifyClient.drainPendingPushFromAppGroup()
            processIfNew(notifyClient.lastMessage)
            // Notifications off → sweep Notification Center clear. The NSE
            // keeps it down to a single passive straggler while we're
            // suspended; this drops that last one now that we're running.
            // Banners on → still mop up stale shield:off control entries
            // ("Replied" pings, timeout unblocks): the newest one always
            // outlives the NSE's sweep because it files in after the NSE
            // ran, so only a later sweep — this one — can drop it.
            if !notifyBanners {
                notifyClient.clearAllDeliveredNotifications()
            } else {
                notifyClient.clearStaleDeliveredNotifications()
            }
        }
        .task {
            // Onboarding owns the system permission prompts now — each
            // is requested from its practice-tap step. This launch
            // check only decides whether the flow needs to present.
            // .task runs once per view lifetime, so this is a cold-
            // launch gate — backgrounding doesn't re-present a skipped
            // flow. Previews construct seeded singletons but the sim's
            // notification status is still notDetermined; don't let the
            // cover bury every existing home-screen preview.
            guard !Self.isRunningInPreviews else { return }
            await onboarding.refreshNotificationStatus()
            guard onboarding.needsOnboarding else {
                // Everything granted + paired — mark complete so future
                // launches take the settled path (also self-heals
                // installs that finished setup before the flag existed).
                onboardingCompleted = true
                return
            }
            // A failing gate at cold launch isn't always real: Family
            // Controls can report .notDetermined for a beat even when
            // granted. If this install already completed the tutorial,
            // or Screen Time is the ONLY failing gate (the one
            // unreliable read), let the status settle before trusting
            // the failure. First runs fail multiple reliable gates and
            // skip the wait entirely.
            let fcOnlyFailure = onboarding.paired && onboarding.notificationsGranted
            if onboardingCompleted || fcOnlyFailure {
                await onboarding.settleAndRecheck()
            }
            if onboarding.needsOnboarding {
                onboarding.begin()
                onboardingPresented = true
            } else {
                onboardingCompleted = true
            }
        }
        .onChange(of: setupNeeded) { _, _ in
            syncSetupPresentation(animated: true)
        }
        .onChange(of: notifyClient.lastMessage) { _, newValue in
            processIfNew(newValue)
        }
        // Catch the case where a push arrived while the scene was
        // suspended: didReceiveRemoteNotification updated lastMessage
        // in the background, but SwiftUI's .onChange isn't guaranteed
        // to fire for value changes that happened while the view was
        // not actively observing. .onAppear above only fires on first
        // appearance — not on resume — so without this, opening the
        // app via the icon (not the banner tap) leaves the trigger /
        // shield in stale state.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Drain anything the NSE wrote to the App Group while
                // we were suspended before processing — this sets
                // lastMessage to the most recent NSE-handled push so
                // handleIncoming can enqueue its overlay. Reload
                // pendingTriggers first so user-driven actions (Dismiss)
                // see the NSE-added trigger instead of an empty cache.
                manager.reloadFromAppGroup()
                notifyClient.drainPendingPushFromAppGroup()
                processIfNew(notifyClient.lastMessage)
                // Notifications off → drop the lone passive straggler the
                // NSE leaves behind (it runs before that entry posts).
                // Banners on → mop up stale shield:off control entries the
                // NSE's sweep can't reach (each files in after it ran).
                if !notifyBanners {
                    notifyClient.clearAllDeliveredNotifications()
                } else {
                    notifyClient.clearStaleDeliveredNotifications()
                }
            }
        }
        .onChange(of: manager.pendingTriggers) { _, newPending in
            // A non-top entry's per-session timer expired in the
            // background. Drop those queue entries so popping the top
            // doesn't reveal a stale entry that would immediately fire
            // onExpire. Untagged pings (nil sessionId) aren't reconciled
            // — they have no backing trigger and are removed only by
            // the Dismiss button.
            overlayQueue.removeAll { msg in
                guard let sid = msg.sessionId, sid.isUsableSessionId
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
        .fullScreenCover(isPresented: $onboardingPresented) {
            OnboardingFlow(
                state: onboarding,
                manager: manager,
                registrar: registrar,
                onDismiss: { onboardingPresented = false },
                onFinish: {
                    onboardingCompleted = true
                    onboardingPresented = false
                    // Completed the walkthrough (not skipped): flip the
                    // big toggle on for them, after the cover's dismiss
                    // animation lands so the flip is visible on-screen.
                    // No-ops when already armed (Tutorial-after-revoke
                    // replays through this same path).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard !manager.armed else { return }
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            manager.setArmed(true)
                        }
                    }
                }
            )
        }
        .familyActivityPicker(
            isPresented: $pickerPresented,
            selection: $draftSelection
        )
        .onChange(of: pickerPresented) { _, presented in
            if !presented { handlePickerDismiss() }
        }
    }

    @ViewBuilder
    private var mainScreen: some View {
        VStack(spacing: 0) {
            TopBar(
                theme: theme,
                onOpenSettings: { showSettings = true }
            )

            homeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Color.clear
                .frame(height: RecentTriggersLayout.collapsedReserveHeight)
        }
    }

    /// Static top accent glow — fades in while armed. The reference's
    /// `radial-gradient(ellipse 80% 60% at 50% 0%)` over a 360pt strip
    /// that bleeds 120pt above the viewport.
    private var topGlow: some View {
        Ellipse()
            .fill(
                // EllipticalGradient stretches its falloff to the wide,
                // short frame — matching the reference's anisotropic
                // `ellipse 80% 60%` rather than a circular fade.
                EllipticalGradient(
                    stops: [
                        .init(
                            color: theme.accent.opacity(effectiveDark ? 0.18 : 0.125),
                            location: 0
                        ),
                        .init(color: .clear, location: 0.7),
                    ],
                    center: .top
                )
            )
            .frame(height: 360)
            .padding(.horizontal, -40)
            // Anchor to the physical screen top (not the safe area),
            // then bleed 120pt above it — the reference's `top: -120`.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(y: -120)
            .ignoresSafeArea()
            .opacity(manager.armed ? 1 : 0)
            .animation(.easeInOut(duration: 0.5), value: manager.armed)
            .allowsHitTesting(false)
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
        if let sid = msg.sessionId, sid.isUsableSessionId {
            // Sync from App Group first — the NSE may have engaged
            // the shield for this session in the background, but
            // host's in-memory pendingTriggers is empty until the
            // tick reloads. Without this, resolveTrigger no-ops
            // (removeValue returns nil) and recomputeBlocking →
            // clearShield never fires, so the apps stay blocked
            // even though the user explicitly dismissed.
            manager.reloadFromAppGroup()
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
        if let sid = msg.sessionId, sid.isUsableSessionId {
            triggerStore.clearNeedsReply(forSession: sid)
        }
        withAnimation(.easeInOut(duration: 0.32)) {
            _ = overlayQueue.removeFirst()
        }
    }

    /// Whether an overlay should be surfaced for this message. A
    /// session-tagged message must have a live (present, non-expired)
    /// trigger behind it — that trigger is the clock the overlay's
    /// countdown and its `onExpire` auto-dismiss both read from
    /// (`BlockedOverlay` gates the whole `TimelineView` on
    /// `expiresAt != nil`). Without a live trigger the overlay shows no
    /// timer and can never self-close, so the only escape is the Dismiss
    /// button — exactly the stuck state users hit on the background-replay
    /// path, where `tick()` can prune the expired trigger before
    /// `drainPendingPushFromAppGroup` replays its overlay. Untagged
    /// messages (no session) carry no trigger by design and keep the old
    /// informational-overlay behavior.
    private func shouldEnqueueOverlay(for message: NtfyMessage) -> Bool {
        guard let sid = message.sessionId, sid.isUsableSessionId else {
            return true
        }
        guard let trigger = manager.pendingTriggers[sid] else { return false }
        return !trigger.isExpired(now: Date())
    }

    /// Push a fresh ping onto the queue. If an entry exists with the
    /// same sessionId, remove it first — the new ping carries the
    /// latest state of that conversation, so the old entry is stale.
    /// Where the new entry lands depends on the user's overlayOrder:
    ///   - `.stack` (LIFO): insert at the front so it surfaces on top.
    ///   - `.queue` (FIFO): append at the back so the oldest pending
    ///     block stays visible until dismissed.
    private func enqueueOverlay(_ message: NtfyMessage) {
        if let sid = message.sessionId, sid.isUsableSessionId {
            overlayQueue.removeAll { $0.sessionId == sid }
        }
        switch overlayOrder {
        case .stack: overlayQueue.insert(message, at: 0)
        case .queue: overlayQueue.append(message)
        }
    }

    /// Single entry-point for incoming pushes. Dedupes by message id
    /// so a push that gets observed twice (once via .onChange while
    /// foreground, again via .onAppear after a background wake) only
    /// updates state once.
    private func processIfNew(_ message: NtfyMessage?) {
        guard let message else { return }
        guard message.id != lastProcessedMessageId else { return }
        lastProcessedMessageId = message.id
        handleIncoming(message)
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
               sid.isUsableSessionId {
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
                // Skip addTrigger when the NSE already did it in the
                // background — re-adding would reset the per-session
                // timer to now (giving the user extra free time).
                if !message.wasBackgroundEngaged {
                    manager.addTrigger(sessionId: sid, durationSeconds: durationFor(message))
                }
                // Per-app block counts are no longer bumped here — the
                // VibezShield extension tallies them per actual open, so
                // "most blocked" reflects what you hit, not the whole list.
            }
            // Skip context refresh on drain — NSE wrote it. Otherwise
            // we'd overwrite with the same data.
            if !message.wasBackgroundEngaged {
                manager.publishShieldContext(from: message)
            }

            // Skip local notification on drain — iOS already displayed
            // the NSE-modified banner when the push arrived. Otherwise
            // the user sees a second banner the moment they open Vibez.
            // Also skip when the user has turned banners off — the shield
            // still engaged above; we just don't interrupt them.
            if !message.wasBackgroundEngaged && notifyBanners {
                notifyClient.scheduleLocalNotification(message)
            }
            // Only surface the overlay when a live trigger backs it. On
            // the background-replay path (wasBackgroundEngaged), tick()
            // can prune the NSE-engaged block right before
            // drainPendingPushFromAppGroup replays it; re-enqueuing then
            // strands a timerless overlay that only the Dismiss button can
            // clear (the foreground race). The foreground path called
            // addTrigger just above, so a live trigger is always present
            // there and this stays a no-op guard.
            if shouldEnqueueOverlay(for: message) {
                withAnimation(.easeInOut(duration: 0.32)) {
                    enqueueOverlay(message)
                }
            } else {
                handleIncomingLog.info("→ stale replay, no live trigger — skipping overlay")
            }

        case .none:
            handleIncomingLog.info("branch: shield=nil → record trigger + overlay")
            // Plain push (test ping, third-party producer, etc.) — show
            // the overlay as we always did.
            recordTrigger(from: message)
            if !message.wasBackgroundEngaged && notifyBanners {
                notifyClient.scheduleLocalNotification(message)
            }
            withAnimation(.easeInOut(duration: 0.32)) {
                enqueueOverlay(message)
            }

        case .off:
            // Unreachable — handled above.
            break
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            // mainScreen ignores the bottom safe area, so the reserve
            // spacer below this view ends at the physical screen bottom —
            // our bottom edge plus the reserve is the screen height.
            let screenHeight = frame.maxY + RecentTriggersLayout.collapsedReserveHeight
            // Rest the toggle's center on the screen's vertical center.
            // BigToggle keeps a constant pillH-tall layout box through the
            // focus-banner morph, so the center holds in focus mode too.
            let toggleCenterY = screenHeight / 2 - frame.minY
            let topSpacer = max(
                0,
                toggleCenterY - BigToggle.pillH / 2 - Self.heroToggleGap - heroHeight
            )

            VStack(spacing: 0) {
                if unlockedLayoutExpanded {
                    Spacer()
                        .frame(height: topSpacer)
                }

                hero
                    .padding(.top, unlockedLayoutExpanded ? 0 : 8)

                BigToggle(
                    enabled: Binding(
                        get: { manager.armed && !setupNeeded },
                        set: { manager.setArmed($0) }
                    ),
                    theme: theme,
                    isInteractive: !registrar.vibezId.isEmpty,
                    focusMode: manager.focusMode,
                    onLockedTap: bounceToShowSetup,
                    onReleaseFocus: { toggleFocusMode() }
                )
                .padding(.top, unlockedLayoutExpanded ? Self.heroToggleGap : 14)
                .padding(.bottom, unlockedLayoutExpanded ? 0 : 14)
                .shake(trigger: toggleShake)

                if setupCardMounted {
                    VibezSetupCard(
                        registrar: registrar,
                        theme: theme
                    )
                    .opacity(setupCardVisible ? 1 : 0)
                    .allowsHitTesting(setupCardVisible)
                    .accessibilityHidden(!setupCardVisible)
                    .padding(.top, 18)
                    .shake(trigger: setupShake, amount: 5, duration: 0.84)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    /// VStack spacing between the mascot frame and the hint. Negative:
    /// the mascot frames carry empty space below the feet, so the hint
    /// is pulled up into it to sit close under the mascot.
    private static let captionGap: CGFloat = -6
    /// Fixed hint line height so the hero's height is deterministic.
    private static let captionHeight: CGFloat = 12

    /// Vertical air between the hero and the toggle — lifts the mascot
    /// clear of the screen-centered toggle. The hero is bottom-anchored
    /// against this gap, so shrinking it drops mascot + hint together.
    private static let heroToggleGap: CGFloat = 26

    /// Mascot + focus halo + the "tap to enter focus mode" hint.
    /// Desaturated and dimmed while disarmed; tapping toggles a manual
    /// focus hold. Mascot and hint live in the SAME stack: every move,
    /// size change, and filter applies to both as one rigid unit. The
    /// hint is always rendered (visibility is opacity-only), so the
    /// stack's height never changes and the hint can't pop in late.
    private var hero: some View {
        VStack(spacing: showFocusHint ? Self.captionGap : 0) {
            MascotForAgent(
                agent: agent,
                listening: manager.armed,
                size: mascotSize,
                gap: 4,
                focused: manager.focusMode,
                // The reference hero passes animate={false} — no body
                // bob on the home screen; eyes still cycle.
                animate: false
            )
            // The halo is decoration behind the mascot — .background so
            // its 1.9× footprint never inflates the hero's layout.
            .background {
                if manager.focusMode {
                    FocusHalo(color: theme.accent, size: mascotSize * 1.9)
                }
            }
            // Hint hidden → drop the mascot by half the hint's height vs
            // the shown layout. Shown below-mascot space is
            // captionGap + captionHeight; removing captionHeight/2 of it
            // lowers the mascot by that much.
            .padding(.bottom, showFocusHint ? 0 : Self.captionGap + Self.captionHeight / 2)

            if showFocusHint {
                Text("tap to enter focus mode")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(theme.fgMute)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: Self.captionHeight)
                    // Scoped form on purpose: .animation(_:value:) would
                    // re-time EVERY animatable property of the text — the
                    // parent-assigned position included — whenever
                    // captionVisible flips inside a layout move (pairing
                    // expansion), detaching the hint from the mascot. This
                    // animates the fade and nothing else; geometry rides
                    // the same transaction as the rest of the hero.
                    .animation(.easeInOut(duration: 0.3)) { content in
                        content.opacity(captionVisible ? 1 : 0)
                    }
                    .accessibilityHidden(!captionVisible)
            }
        }
        .saturation(manager.armed ? 1 : 0.12)
        .brightness(manager.armed ? 0 : -0.08)
        .opacity(manager.armed ? 1 : 0.7)
        .animation(.easeInOut(duration: 0.5), value: manager.armed)
        .contentShape(Rectangle())
        .onTapGesture { toggleFocusMode() }
    }

    /// Hint visibility: paired (animated layout state, so show/hide
    /// rides the same transactions that move the mascot), armed (toggle
    /// off → invisible), and not already in focus mode.
    private var captionVisible: Bool {
        unlockedLayoutExpanded && manager.armed && !manager.focusMode
    }

    /// The hero's layout height — the per-agent mascot frame plus the
    /// always-rendered hint row. Deterministic, no measurement needed.
    private var heroHeight: CGFloat {
        let mascotFrame: CGFloat
        switch agent {
        case .claude: mascotFrame = mascotSize * 0.9            // viewBox 100×90
        case .codex:  mascotFrame = mascotSize * 130 / 110      // viewBox 110×130
        case .both:   mascotFrame = mascotSize * 0.78 * 130 / 110
        }
        // Mirror the `hero` layout: with the hint, the full caption row
        // (negative gap + caption height); without it, that same space
        // minus half the caption height — so the mascot sits half a
        // text-height lower when the hint is gone.
        let belowMascot = showFocusHint
            ? Self.captionGap + Self.captionHeight
            : Self.captionGap + Self.captionHeight / 2
        return mascotFrame + belowMascot
    }

    /// Tap the mascot to start/stop a manual focus hold. Only meaningful
    /// while armed. With no apps selected, open the system app picker
    /// directly (an empty shield would block nothing) and engage focus
    /// once the user has picked something — see `pickAppsThenFocus`.
    private func toggleFocusMode() {
        guard manager.armed else { return }
        guard manager.hasSelection else {
            pickAppsThenFocus()
            return
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            manager.setFocusMode(!manager.focusMode)
        }
    }

    /// Present the FamilyActivityPicker seeded with the current
    /// selection (expanded so a category pick returns its member apps).
    /// `focusAfterPick` flags that this was a focus-mode tap, so the
    /// picker's dismiss handler can engage focus once apps land.
    private func pickAppsThenFocus() {
        draftSelection = manager.selection.expandingCategories
        focusAfterPick = true
        pickerPresented = true
    }

    /// Persist the picker result and, if it was opened by a focus tap
    /// and apps are now selected, engage focus mode. Mirrors the
    /// save-only-real-edits logic in SettingsView so a cancelled picker
    /// doesn't flip the includeEntireCategory flag and hide icons.
    private func handlePickerDismiss() {
        let wantsFocus = focusAfterPick
        focusAfterPick = false

        let unchanged = draftSelection.applicationTokens == manager.selection.applicationTokens
            && draftSelection.categoryTokens == manager.selection.categoryTokens
            && draftSelection.webDomainTokens == manager.selection.webDomainTokens
        if !unchanged {
            manager.updateSelection(draftSelection)
        }

        if wantsFocus && manager.armed && manager.hasSelection && !manager.focusMode {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                manager.setFocusMode(true)
            }
        }
    }

    private var mascotSize: CGFloat {
        if unlockedLayoutExpanded {
            switch agent {
            case .claude: return 140
            case .codex:  return 130
            case .both:   return 128
            }
        }
        return agent == .both ? 92 : 100
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
    ("Diagnose push delivery timing", "Backoff was 3s flat — bumped to exponential with jitter."),
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
    focusMode: Bool = false,
    pendingTriggers: [PendingTrigger] = [],
    events: [TriggerEvent] = []
) -> some View {
    seedAppStorageDefaults(agent: agent, appearance: appearance)
    return ContentView(
        manager: ScreenTimeManager.previewManager(
            armed: armed,
            pendingTriggers: pendingTriggers,
            focusMode: focusMode
        ),
        notifyClient: NotifyClient.previewClient(),
        registrar: PushTokenRegistrar.previewRegistrar(
            vibezId: vibezId,
            state: registrarState
        ),
        triggerStore: previewTriggerStore(events: events),
        ignoreStore: IgnoreStore(),
        analytics: AnalyticsTracker()
    )
    .preferredColorScheme(appearance == .light ? .light : .dark)
}

#Preview("Paired · ready · dark") {
    // Right after the user pastes a working Vibez ID. Setup card has
    // animated out, toggle is interactive but still OFF; mascot is
    // dimmed/desaturated and the bubbles are faded. This is the
    // "everything is wired up and ready" empty state.
    previewContent(
        armed: false
    )
}

#Preview("Armed · listening · dark") {
    // Toggle flipped ON: bubbles drifting, top glow on, mascot in its
    // listening pose with the "tap to enter focus mode" hint. No pings
    // have landed yet, so the Recent triggers sheet is blank.
    previewContent(
        armed: true
    )
}

#Preview("Focus mode · dark") {
    // Armed and holding a manual focus block: squinting mascot with the
    // accent halo, and the toggle morphed into the "Focus mode — tap to
    // release" banner. No triggers — the shield is held by the tap alone.
    previewContent(
        armed: true,
        focusMode: true
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
        events: events
    )
}

#Preview("Busy day · Claude · dark") {
    // Everything: armed, a block in progress for one session, 12 recent
    // triggers across the day. This is the "you've been pairing with
    // Claude all afternoon" view.
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
        events: events
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
        events: events
    )
}

#endif
