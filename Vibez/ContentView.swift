//
//  ContentView.swift
//  Vibez
//

import SwiftUI

struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @AppStorage("vibez.dark") private var dark = false
    @AppStorage("vibez.agent") private var agentRaw = Agent.claude.rawValue
    @State private var showBlockedOverlay = false
    @State private var sessionSeconds: Int = 0
    @State private var sessionTimerTask: Task<Void, Never>?

    private var agent: Agent {
        Agent(rawValue: agentRaw) ?? .claude
    }

    private var theme: Theme {
        Theme.make(agent: agent, dark: dark)
    }

    var body: some View {
        ZStack {
            theme.bg
                .ignoresSafeArea()

            mainScreen

            if showBlockedOverlay {
                BlockedOverlay(
                    agent: agent,
                    theme: theme,
                    dark: dark,
                    onDismiss: { withAnimation { showBlockedOverlay = false } }
                )
                .zIndex(5)
            }
        }
        .preferredColorScheme(dark ? .dark : .light)
        .animation(.easeInOut(duration: 0.4), value: dark)
        .animation(.easeInOut(duration: 0.4), value: agent)
        .onAppear { syncTimer(enabled: manager.isBlocking) }
        .onChange(of: manager.isBlocking) { _, newValue in syncTimer(enabled: newValue) }
        .task {
            if manager.authState == .notDetermined {
                await manager.requestAuthorization()
            }
        }
    }

    @ViewBuilder
    private var mainScreen: some View {
        VStack(spacing: 0) {
            TopBar(
                dark: Binding(get: { dark }, set: { dark = $0 }),
                theme: theme
            )

            hero
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 14)

            BlockingPanel(
                apps: BlockedApp.demoSet,
                enabled: manager.isBlocking,
                theme: theme
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            RecentTriggersSection(
                events: TriggerEvent.demoSet,
                theme: theme
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 0) {
            StatusPill(listening: manager.isBlocking, theme: theme)
                .padding(.bottom, 10)

            Text("Doomscroll apps lock the moment \(agent.label) pings you.")
                .font(.system(size: 13))
                .foregroundStyle(theme.fgMute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .lineSpacing(2)
                .padding(.bottom, 14)

            // Big mascot above the toggle
            MascotForAgent(
                agent: agent,
                listening: manager.isBlocking,
                size: agent == .both ? 92 : 100,
                gap: 4
            )
            .frame(height: 110, alignment: .bottom)
            .padding(.bottom, 6)

            BigToggle(
                enabled: Binding(
                    get: { manager.isBlocking },
                    set: { manager.setBlocking($0) }
                ),
                agent: agent,
                theme: theme
            )

            HStack(spacing: 0) {
                Text("session · ")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(manager.isBlocking ? theme.fg : theme.fgFaint)
                Text(formattedSession)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
            }
            .padding(.top, 10)
        }
    }

    private var formattedSession: String {
        let s = sessionSeconds
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%d:%02d:%02d", h, m, sec)
    }

    private func syncTimer(enabled: Bool) {
        sessionTimerTask?.cancel()
        if !enabled {
            sessionSeconds = 0
            return
        }
        sessionTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                sessionSeconds += 1
            }
        }
    }
}

#Preview("Light · Claude") {
    ContentView()
}
