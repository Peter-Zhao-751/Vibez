//
//  ContentView.swift
//  Vibez
//

import SwiftUI

struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.agent") private var agentRaw = Agent.claude.rawValue

    @Environment(\.colorScheme) private var systemColorScheme

    @State private var showBlockedOverlay = false
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

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
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
                    dark: effectiveDark,
                    onDismiss: { withAnimation { showBlockedOverlay = false } }
                )
                .zIndex(5)
            }
        }
        .preferredColorScheme(preferredScheme)
        .animation(.easeInOut(duration: 0.4), value: effectiveDark)
        .animation(.easeInOut(duration: 0.4), value: agent)
        .task {
            if manager.authState == .notDetermined {
                await manager.requestAuthorization()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(manager: manager)
        }
    }

    @ViewBuilder
    private var mainScreen: some View {
        VStack(spacing: 0) {
            TopBar(
                isDark: effectiveDark,
                theme: theme,
                onToggleAppearance: toggleAppearance,
                onOpenSettings: { showSettings = true }
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
        }
    }

    private func toggleAppearance() {
        // Tapping the chip "commits" the user to an explicit choice — they
        // never accidentally fall back to .system. Settings page lets them
        // return to .system if they want.
        appearanceRaw = (effectiveDark ? AppearancePref.light : AppearancePref.dark).rawValue
    }
}

#Preview("bruh") {
    ContentView()
}
