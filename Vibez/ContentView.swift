//
//  ContentView.swift
//  Vibez
//

import SwiftUI

struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @State private var notifyClient = NotifyClient()
    @State private var triggerStore = TriggerStore()
    @State private var ignoreStore = IgnoreStore()

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.agent") private var agentRaw = Agent.claude.rawValue
    @AppStorage("vibez.ntfyURL") private var ntfyURL = ""
    @AppStorage("vibez.blockSeconds") private var blockSeconds = 1800

    @Environment(\.colorScheme) private var systemColorScheme

    @State private var overlayMessage: NtfyMessage?
    @State private var showSettings = false

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

    var body: some View {
        ZStack {
            theme.bg
                .ignoresSafeArea()

            mainScreen

            if let msg = overlayMessage {
                BlockedOverlay(
                    agent: agent,
                    theme: theme,
                    dark: effectiveDark,
                    message: msg,
                    onDismiss: { dismissOverlay(for: msg) }
                )
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
        .sheet(isPresented: $showSettings) {
            SettingsView(
                isPresented: $showSettings,
                manager: manager,
                notifyClient: notifyClient,
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

            hero
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)

            BlockingPanel(
                apps: BlockedApp.demoSet,
                enabled: manager.isBlocking,
                theme: theme
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            RecentTriggersSection(
                events: triggerStore.events,
                theme: theme,
                ignoreStore: ignoreStore,
                onIgnore: { event in
                    guard let sid = event.sessionId else { return }
                    let name = event.title?.isEmpty == false ? event.title! : event.label
                    ignoreStore.ignore(sessionId: sid, name: name)
                },
                onUnignore: { event in
                    guard let sid = event.sessionId else { return }
                    ignoreStore.unignore(sessionId: sid)
                }
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Spacer(minLength: 0)
        }
    }

    private func recordTrigger(from message: NtfyMessage) {
        let source = TriggerEvent.detectSource(
            title: message.title,
            body: message.body,
            fallback: agent
        )
        triggerStore.record(
            TriggerEvent(
                receivedAt: message.receivedAt,
                source: source,
                title: message.title,
                label: message.body,
                blockSeconds: blockSeconds,
                sessionId: message.sessionId,
                needsReply: message.needsReply
            )
        )
    }

    /// Tapping Dismiss resolves the trigger for THIS message's session
    /// only — other sessions stay pending and the shield stays up until
    /// each of them is replied-to, dismissed, or times out.
    private func dismissOverlay(for message: NtfyMessage) {
        if let sid = message.sessionId, !sid.isEmpty, sid != "nosid" {
            manager.resolveTrigger(sessionId: sid)
            triggerStore.clearNeedsReply(forSession: sid)
        }
        withAnimation { overlayMessage = nil }
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
            }
            if let current = overlayMessage,
               current.sessionId == message.sessionId {
                withAnimation { overlayMessage = nil }
            }
            return
        }

        // Toggle off → Vibez is dormant. Don't notify, don't show the
        // overlay, don't add a trigger — the user has explicitly told us
        // to stay out of the way.
        guard manager.isBlocking else { return }

        switch message.shield {
        case .on:
            recordTrigger(from: message)

            if let sid = message.sessionId,
               !sid.isEmpty, sid != "nosid" {
                if ignoreStore.contains(sid) {
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
                manager.addTrigger(sessionId: sid, durationSeconds: blockSeconds)
            }

            notifyClient.scheduleLocalNotification(message)
            withAnimation(.easeOut(duration: 0.45)) {
                overlayMessage = message
            }

        case .none:
            // Plain ntfy ping (test push, third-party producer, etc.)
            // — show the overlay as we always did.
            recordTrigger(from: message)
            notifyClient.scheduleLocalNotification(message)
            withAnimation(.easeOut(duration: 0.45)) {
                overlayMessage = message
            }

        case .off:
            // Unreachable — handled above.
            break
        }
    }

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 0) {



            MascotForAgent(
                agent: agent,
                listening: manager.isBlocking,
                size: agent == .both ? 92 : 100,
                gap: 4
            )
            .frame(height: 110, alignment: .bottom)
            .padding(.bottom, 20)

            BigToggle(
                enabled: Binding(
                    get: { manager.isBlocking },
                    set: { manager.setBlocking($0) }
                ),
                agent: agent,
                theme: theme,
                isInteractive: !ntfyURL.isEmpty
            )
            StatusPill(listening: manager.isBlocking, theme: theme)
                .padding(.top, 10)

            if ntfyURL.isEmpty || notifyClient.state != .connected {
                NotificationSetupCard(
                    ntfyURL: $ntfyURL,
                    notifyClient: notifyClient,
                    theme: theme
                )
                .padding(.top, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: ntfyURL.isEmpty || notifyClient.state != .connected)
    }
}

#Preview("bruh") {
    ContentView()
}
