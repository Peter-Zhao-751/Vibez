//
//  ContentView.swift
//  Vibez
//

import SwiftUI
import FamilyControls

struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @State private var notifyClient = NotifyClient()
    @State private var triggerStore = TriggerStore()
    @State private var ignoreStore = IgnoreStore()
    /// Picker presented from the blocking panel's "+" tile. Kept
    /// separate from the one inside SettingsView so each surface owns
    /// its own draft state.
    @State private var pickerPresented = false
    @State private var pickerDraft = FamilyActivitySelection()

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.agent") private var agentRaw = Agent.claude.rawValue
    @AppStorage("vibez.ntfyURL") private var ntfyURL = ""
    @AppStorage("vibez.blockSeconds.needsInput") private var blockSecondsNeedsInput = 900
    @AppStorage("vibez.blockSeconds.done") private var blockSecondsDone = 30
    @AppStorage("vibez.overlayOrder") private var overlayOrderRaw = OverlayOrder.stack.rawValue
    @AppStorage("vibez.allowDismiss") private var allowDismiss = true

    @Environment(\.colorScheme) private var systemColorScheme

    @State private var overlayQueue: [NtfyMessage] = []   // newest first
    @State private var showSettings = false
    @State private var toggleShake = 0
    @State private var setupShake = 0

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
        .onAppear { appearance.applyToWindows() }
        .onChange(of: appearance) { _, newPref in
            newPref.applyToWindows()
        }
        .task {
            // Subscribe immediately — don't block on permission prompts,
            // otherwise the WebSocket sits idle while the user is staring
            // at "Allow Notifications?" and incoming messages get dropped.
            notifyClient.updateURL(ntfyURL)
            await NotifyClient.requestAuthorization()
            if manager.authState == .notDetermined {
                await manager.requestAuthorization()
            }
        }
        .onChange(of: ntfyURL) { _, newValue in
            notifyClient.updateURL(newValue)
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
                triggerStore: triggerStore,
                ignoreStore: ignoreStore
            )
        }
        .familyActivityPicker(
            isPresented: $pickerPresented,
            selection: $pickerDraft
        )
        .onChange(of: pickerPresented) { _, presented in
            if !presented {
                manager.updateSelection(pickerDraft)
            }
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

            hero
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)

            BlockingPanel(
                selection: manager.selection,
                enabled: manager.armed,
                theme: theme,
                onPickMore: {
                    pickerDraft = manager.selection
                    pickerPresented = true
                }
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            if !triggerStore.events.isEmpty {
                Spacer(minLength: 0)
            }

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
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
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
        // shield:off (the user just replied in Claude) is a control
        // signal — never surface it as a notification, and only act on
        // it if we actually have something to resolve. Handled first so
        // it bypasses the toggle gate below: a reply that lands while
        // the user has just flipped the toggle off is harmless to
        // process (resolveTrigger is a no-op when the session isn't
        // pending) and we don't want stale state to linger.
        if message.shield == .off {
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
        guard manager.armed else { return }

        switch message.shield {
        case .on:
            recordTrigger(from: message)

            if let sid = message.sessionId,
               !sid.isEmpty, sid != "nosid" {
                if ignoreStore.contains(sessionId: sid, name: message.title) {
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
            }
            manager.publishShieldContext(from: message)

            notifyClient.scheduleLocalNotification(message)
            withAnimation(.easeInOut(duration: 0.32)) {
                enqueueOverlay(message)
            }

        case .none:
            // Plain ntfy ping (test push, third-party producer, etc.)
            // — show the overlay as we always did.
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
    private var hero: some View {
        let setupVisible = ntfyURL.isEmpty || notifyClient.state != .connected
        VStack(spacing: 0) {
            MascotForAgent(
                agent: agent,
                listening: manager.armed,
                size: agent == .both ? 92 : 100,
                gap: 4
            )
            .frame(height: 110, alignment: .bottom)
            .padding(.bottom, 18)

            BigToggle(
                enabled: Binding(
                    get: { manager.armed && !setupVisible},
                    set: { manager.setArmed($0) }
                ),
                agent: agent,
                theme: theme,
                isInteractive: !ntfyURL.isEmpty,
                onLockedTap: bounceToShowSetup
            )
            // Tight gap to the setup card so the locked toggle visually
            // leads into "fix it here"; more breathing room when the
            // toggle stands alone above the blocking panel below.
            .padding(.bottom, setupVisible ? 14 : 22)
            .shake(trigger: toggleShake)

            if setupVisible {
                NotificationSetupCard(
                    ntfyURL: $ntfyURL,
                    notifyClient: notifyClient,
                    theme: theme
                )
                .padding(.bottom, 6)
                .shake(trigger: setupShake, amount: 5, duration: 0.84)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: setupVisible)
    }
}

#Preview("bruh") {
    ContentView()
}
