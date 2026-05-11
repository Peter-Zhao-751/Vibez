//
//  ContentView.swift
//  Vibez
//

import SwiftUI

struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @State private var notifyClient = NotifyClient()
    @State private var triggerStore = TriggerStore()

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
                    onDismiss: { withAnimation { overlayMessage = nil } }
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
                notifyClient: notifyClient
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
                theme: theme
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Spacer(minLength: 0)
        }
    }

    private func recordTrigger(from message: NtfyMessage) {
        let conversationName = TriggerEvent.cleanedTitle(from: message.title)
        let description = message.body
        let source = TriggerEvent.detectSource(
            title: message.title,
            body: message.body,
            fallback: agent
        )
        triggerStore.record(
            TriggerEvent(
                receivedAt: message.receivedAt,
                source: source,
                title: conversationName,
                label: description,
                blockSeconds: blockSeconds,
                sessionId: message.sessionId,
                needsReply: message.needsReply
            )
        )
    }

    private func handleIncoming(_ message: NtfyMessage) {
        switch message.kind {
        case .unblock:
            // Match against pendingTriggers — the user just replied in
            // this conversation, so release the auto-block for it.
            if let sid = message.sessionId {
                manager.resolveTrigger(sessionId: sid)
                triggerStore.clearNeedsReply(forSession: sid)
            }
            // Dismiss the overlay if it was for this same session.
            if let current = overlayMessage,
               current.sessionId == message.sessionId {
                withAnimation { overlayMessage = nil }
            }

        case .block:
            if let sid = message.sessionId {
                manager.addTrigger(sessionId: sid)
            }
            recordTrigger(from: message)
            withAnimation(.easeOut(duration: 0.45)) {
                overlayMessage = message
            }

        case .unknown:
            // Plain ntfy ping (test push, third-party producer, etc.)
            // — show the overlay as we always did.
            recordTrigger(from: message)
            withAnimation(.easeOut(duration: 0.45)) {
                overlayMessage = message
            }
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
                theme: theme
            )
            StatusPill(listening: manager.isBlocking, theme: theme)
                .padding(.top, 10)

        }
    }
}

#Preview("bruh") {
    ContentView()
}
