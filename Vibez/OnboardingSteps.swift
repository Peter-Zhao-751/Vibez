//
//  OnboardingSteps.swift
//  Vibez
//
//  The individual pages of the onboarding flow. Layout scaffolding
//  (headline / subtitle / centered content / pinned CTA) is shared via
//  OnboardingPage; all gating decisions live in OnboardingState — these
//  views only render state and fire actions.
//

import SwiftUI
import UIKit

// MARK: - Shared page scaffolding

/// Common page chrome. Most content is centered between the header and
/// CTA; permission replicas can opt into true screen-centering so they
/// line up with the real system alert.
struct OnboardingPage<Content: View>: View {
    let theme: Theme
    let headline: String
    let subtitle: String
    var ctaTitle: String? = nil
    var ctaEnabled: Bool = true
    var ctaAction: () -> Void = {}
    var centerContentOnScreen = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Text(headline)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(theme.fg)
                            .multilineTextAlignment(.center)
                        Text(subtitle)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(theme.fgMute)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 76)   // clears the Skip button row
                    .padding(.horizontal, 32)

                    if centerContentOnScreen {
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 16)

                        content()

                        Spacer(minLength: 16)
                    }

                    if let ctaTitle {
                        Button(action: ctaAction) {
                            Text(ctaTitle)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(ctaEnabled ? theme.onAccent : theme.fgFaint)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(ctaEnabled ? theme.accent : theme.bgChip)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!ctaEnabled)
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.bottom, 58)   // clears the progress dots

                if centerContentOnScreen {
                    content()
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
    }
}

// MARK: - Step 1 · Welcome

struct OnboardingWelcomeStep: View {
    let theme: Theme
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Welcome to Vibez",
            subtitle: "When Claude or Codex finishes a task or needs you, Vibez blocks your distracting apps so you don't waste any time on distractions while actually coding.",
            ctaTitle: "Get Started",
            ctaAction: onContinue
        ) {
            ClaudeMascot(listening: true, size: 150)
        }
    }
}

// MARK: - Remediation (denied permissions)

/// "Open Settings" remediation shown when a permission was denied —
/// iOS shows each system prompt only once, so the fix lives in the
/// Settings app. The flow re-checks gates on scenePhase-active and
/// auto-advances when the round-trip fixed it.
struct OnboardingRemediation: View {
    let theme: Theme
    let explanation: String
    let settingsURL: URL?
    var retryLabel: String? = nil
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text(explanation)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(theme.fgMute)
                .multilineTextAlignment(.center)

            Button {
                if let settingsURL {
                    UIApplication.shared.open(settingsURL)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14).fill(theme.accent)
                    )
            }
            .buttonStyle(.plain)

            if let retryLabel, let onRetry {
                Button(retryLabel, action: onRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 36)
    }
}

// MARK: - Step 2 · Notifications

struct OnboardingNotificationsStep: View {
    let theme: Theme
    @Bindable var state: OnboardingState
    let onAdvance: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Allow notifications",
            subtitle: "Vibez pings you the moment Claude finishes or needs your input. iOS is about to show the dialog below for real. Tap Allow, exactly like this.",
            centerContentOnScreen: true
        ) {
            if state.notificationStatus == .denied {
                OnboardingRemediation(
                    theme: theme,
                    explanation: "Notifications are currently off for Vibez. iOS only asks once. Flip them on in Settings, then come back here.",
                    settingsURL: URL(string: UIApplication.openNotificationSettingsURLString)
                )
            } else {
                MockSystemDialog(
                    title: "“Vibez” Would Like to Send You Notifications",
                    message: "Notifications may include alerts, sounds, and icon badges. These can be configured in Settings.",
                    buttons: [
                        .init(label: "Don’t Allow"),
                        .init(label: "Allow", isConfirm: true),
                    ],
                    denyHint: "You’ll want Allow — without it, Vibez can’t ping you when your agent needs you.",
                    onConfirm: requestPermission
                )
            }
        }
    }

    private func requestPermission() {
        Task {
            await NotifyClient.requestAuthorization()
            await state.refreshNotificationStatus()
            if state.notificationsGranted {
                onAdvance()
            }
            // Denied → notificationStatus is now .denied and the view
            // re-renders into the remediation state on its own.
        }
    }
}

// MARK: - Step 3 · Screen Time

struct OnboardingScreenTimeStep: View {
    let theme: Theme
    @Bindable var manager: ScreenTimeManager
    let onAdvance: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Allow Screen Time access",
            subtitle: "This is what lets Vibez actually shield Instagram, TikTok & co. iOS is about to show this dialog for real. Tap Continue, exactly like this.",
            centerContentOnScreen: true
        ) {
            if manager.authState == .denied {
                OnboardingRemediation(
                    theme: theme,
                    explanation: "Screen Time access was declined. Try again, or enable it for Vibez in Settings, then come back here.",
                    settingsURL: URL(string: UIApplication.openSettingsURLString),
                    retryLabel: "Try again",
                    onRetry: requestPermission
                )
            } else {
                MockSystemDialog(
                    title: "“Vibez” Would Like to Access Screen Time",
                    message: "Providing “Vibez” access to Screen Time may allow it to see your activity data, restrict content, and limit the usage of apps and websites.",
                    // Real iOS 26.4 dialog: Continue is the LEFT capsule;
                    // Don't Allow sits right with the prominent blue fill.
                    buttons: [
                        .init(label: "Continue", isConfirm: true),
                        .init(label: "Don’t Allow", prominent: true),
                    ],
                    denyHint: "You’ll want Continue. Screen Time access is the mechanism that blocks your distracting apps.",
                    onConfirm: requestPermission
                )
            }
        }
    }

    private func requestPermission() {
        Task {
            await manager.requestAuthorization()
            if manager.authState == .authorized {
                onAdvance()
            }
        }
    }
}

// MARK: - Step 4 · Plugin install

struct OnboardingPluginStep: View {
    let theme: Theme
    let onAdvance: () -> Void

    @State private var copiedCommand: String?

    private struct CommandRow: Identifiable {
        let text: String
        var copyable = true
        var id: String { text }
    }

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Install the plugin",
            subtitle: "On your Mac, in whichever agent you use. Once the plugin is installed, your 4-word Vibez ID prints automatically the moment a session starts — the setup command just shows it again. Keep it handy for the next step.",
            ctaTitle: "I have my Vibez ID",
            ctaAction: onAdvance
        ) {
            VStack(spacing: 18) {
                commandGroup(
                    label: "Claude Code",
                    accent: Theme.claudeOrange,
                    rows: [
                        CommandRow(text: "/plugin marketplace add Peter-Zhao-751/Vibez"),
                        CommandRow(text: "/plugin install vibez@plugin"),
                        CommandRow(text: "/vibez:setup"),
                    ]
                )
                commandGroup(
                    label: "Codex",
                    accent: theme.fgMute,
                    rows: [
                        CommandRow(text: "codex plugin marketplace add Peter-Zhao-751/Vibez"),
                        CommandRow(text: "codex plugin install vibez@vibez"),
                        CommandRow(text: "start a new session — it prints your Vibez ID", copyable: false),
                    ]
                )
            }
            .padding(.horizontal, 24)
        }
    }

    private func commandGroup(
        label: String,
        accent: Color,
        rows: [CommandRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.fgMute)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                CommandRowView(
                    theme: theme,
                    number: i + 1,
                    text: row.text,
                    copyable: row.copyable,
                    copied: copiedCommand == row.text,
                    onCopy: { markCopied(row.text) }
                )
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.bgPanel))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(theme.hairline, lineWidth: 1)
        )
    }

    private func markCopied(_ text: String) {
        UIPasteboard.general.string = text
        withAnimation { copiedCommand = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedCommand == text { copiedCommand = nil }
        }
    }
}

/// One command row: step number, horizontally-scrollable monospace
/// command, copy affordance. A struct (not a builder func on the step)
/// because the scroll-hint state is per-row.
private struct CommandRowView: View {
    let theme: Theme
    let number: Int
    let text: String
    let copyable: Bool
    let copied: Bool
    let onCopy: () -> Void

    private struct ScrollHint: Equatable {
        var overflows = false
        var atEnd = false
    }

    /// Whether the command is wider than the visible row, and whether
    /// the user has scrolled to its end — drives the trailing "…" hint.
    @State private var hint = ScrollHint()

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.fgFaint)
            // Long commands (the Codex marketplace add) overflow the
            // row width — scroll horizontally instead of shrinking or
            // truncating, so the whole command stays readable at full
            // size. Taps inside the scroller still reach the row's
            // copy gesture (a tap is never claimed by the pan).
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(copyable ? theme.fg : theme.fgMute)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: ScrollHint.self) { geo in
                ScrollHint(
                    overflows: geo.contentSize.width > geo.containerSize.width + 1,
                    // Small tolerance so the hint clears as the tail
                    // lands, not only at the exact final pixel.
                    atEnd: geo.contentOffset.x + geo.containerSize.width
                        >= geo.contentSize.width - 8
                )
            } action: { _, new in
                hint = new
            }
            // Trailing "…" over a fade into the chip color: the clipped
            // command visibly slides under it, signaling there's more to
            // scroll. Disappears once the end is reached.
            .overlay(alignment: .trailing) {
                if hint.overflows && !hint.atEnd {
                    Text("…")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.fgMute)
                        .padding(.leading, 16)
                        .background(
                            LinearGradient(
                                colors: [theme.bgChip.opacity(0), theme.bgChip],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: hint)
            Spacer(minLength: 6)
            if copyable {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copied ? .green : theme.fgMute)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.bgChip))
        .contentShape(Rectangle())
        .onTapGesture {
            guard copyable else { return }
            onCopy()
        }
    }
}

// MARK: - Step 5 · Vibez ID

struct OnboardingVibezIdStep: View {
    let theme: Theme
    @Bindable var registrar: PushTokenRegistrar
    let onAdvance: () -> Void

    @State private var draft = ""
    @State private var fieldError: String?
    @FocusState private var focused: Bool

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Mirrors VibezSetupCard: save only a well-formed, *different* ID;
    /// a pure re-submit goes through the retry button.
    private var saveable: Bool {
        PushTokenRegistrar.isValidVibezId(trimmed)
            && trimmed != registrar.vibezId
    }

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "Enter your Vibez ID",
            subtitle: "The 4 words the plugin printed on your Mac when your session started. It pairs this phone to your agents.",
            ctaTitle: "Continue",
            ctaEnabled: registrar.state == .registered,
            ctaAction: onAdvance
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        if draft.isEmpty && !focused {
                            Text("moss-pine-fox-jazz")
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(theme.fgFaint)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $draft)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(theme.fg)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit { commit() }
                            .onChange(of: draft) { _, _ in
                                if fieldError != nil { fieldError = nil }
                            }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12).fill(theme.bgChip)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(theme.hairline, lineWidth: 1)
                    )

                    Button(action: commit) {
                        Text(registrar.state == .registering ? "…" : "Pair")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(saveable ? theme.onAccent : theme.fgFaint)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(saveable ? theme.accent : theme.bgChip)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!saveable)
                }

                statusRow

                if let fieldError {
                    Text(fieldError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.fgMute)
                .lineLimit(2)
            Spacer(minLength: 0)
            if case .error = registrar.state {
                Button("retry") {
                    Task { await registrar.reregister() }
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.fg)
                .buttonStyle(.plain)
            }
        }
    }

    private var statusColor: Color {
        switch registrar.state {
        case .idle:        .secondary
        case .registering: .orange
        case .registered:  .green
        case .error:       .red
        }
    }

    private var statusLabel: String {
        switch registrar.state {
        case .idle:
            registrar.vibezId.isEmpty ? "no Vibez ID yet" : "waiting for FCM token…"
        case .registering:
            "registering…"
        case .registered:
            registrar.isTestMode ? "test mode (no server)" : "paired ✓"
        case .error(let m):
            "error: \(m.prefix(80))"
        }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        guard PushTokenRegistrar.isValidVibezId(trimmed) else {
            fieldError = "Format: 4 hyphenated words, each 3-5 letters (e.g. moss-pine-fox-jazz)."
            return
        }
        fieldError = nil
        focused = false
        registrar.setVibezId(trimmed)
    }
}

// MARK: - Step 6 · How Vibez works + version

struct OnboardingFinishStep: View {
    let theme: Theme
    let onDone: () -> Void

    var body: some View {
        OnboardingPage(
            theme: theme,
            headline: "How Vibez works",
            subtitle: "You're set. Here's the loop:",
            ctaTitle: "Done",
            ctaAction: onDone
        ) {
            VStack(spacing: 0) {
                ClaudeMascot(listening: true, size: 84, animate: false)
                    .padding(.bottom, 22)

                VStack(alignment: .leading, spacing: 16) {
                    bullet(
                        icon: "bell.badge.fill",
                        text: "Your agent finishes a task or needs input → Vibez gets a push."
                    )
                    bullet(
                        icon: "shield.fill",
                        text: "Your picked apps shield until you reply on the Mac, dismiss, or the timer runs out."
                    )
                    bullet(
                        icon: "hand.tap.fill",
                        text: "Tap the mascot anytime for a manual focus hold."
                    )
                    bullet(
                        icon: "switch.2",
                        text: "The big toggle arms Vibez; Settings picks apps and block durations."
                    )
                }
                .padding(.horizontal, 30)

                Text(Self.versionString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.fgFaint)
                    .padding(.top, 24)
            }
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(theme.accent)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Vibez \(v) (\(b))"
    }
}
