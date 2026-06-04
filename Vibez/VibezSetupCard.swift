//
//  VibezSetupCard.swift
//  Vibez
//
//  Home-screen pairing card. The user runs /vibez:setup on their Mac
//  (Claude Code or Codex), gets a 4-word Vibez ID, types it in here.
//  We then call the registerPushToken Cloud Function with the FCM
//  token + the ID; once the server has the pairing, /notify pushes
//  from the plugin reach this device.
//
//  Replaces the previous NotificationSetupCard (ntfy URL).
//

import SwiftUI

struct VibezSetupCard: View {
    @Bindable var registrar: PushTokenRegistrar
    let theme: Theme

    @State private var draft: String = ""
    @State private var fieldError: String? = nil
    @FocusState private var focused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Save is enabled when the draft is well-formed AND differs from
    /// the currently-saved ID. A pure re-submit goes through the
    /// dedicated retry button instead.
    private var saveable: Bool {
        PushTokenRegistrar.isValidVibezId(trimmedDraft)
            && trimmedDraft != registrar.vibezId
    }

    /// "Run /vibez:setup in Claude Code or Codex, then paste the Vibez
    /// ID it gives you." — the command rendered in monospace fg, like
    /// the reference card.
    private var instructions: AttributedString {
        var lead = AttributedString("Run ")
        lead.foregroundColor = theme.fgMute
        var cmd = AttributedString("/vibez:setup")
        cmd.font = .system(size: 12, design: .monospaced)
        cmd.foregroundColor = theme.fg
        var tail = AttributedString(" in Claude Code or Codex, then paste the Vibez ID it gives you.")
        tail.foregroundColor = theme.fgMute
        return lead + cmd + tail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: 0xf5c518))
                    .frame(width: 8, height: 8)
                Text("Connect Vibez")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.fg)
            }
            .padding(.bottom, 4)

            Text(instructions)
                .font(.system(size: 12))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if draft.isEmpty && !focused {
                        Text("moss-pine-fox-jazz")
                            .font(.system(size: 13.5, design: .monospaced))
                            .foregroundStyle(theme.fgFaint)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft)
                        .font(.system(size: 13.5, design: .monospaced))
                        .foregroundStyle(theme.fg)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { commit() }
                        .onChange(of: draft) { _, _ in
                            // Clear stale validation error as the user
                            // edits — they shouldn't keep seeing the
                            // failure indicator while typing the fix.
                            if fieldError != nil { fieldError = nil }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(theme.bgChip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(theme.hairline, lineWidth: 1)
                )

                Button(action: commit) {
                    Text(pairBtnLabel)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(saveable ? theme.onAccent : theme.fgFaint)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(saveable ? theme.accent : theme.bgChip)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!saveable)
            }

            statusRow
                .padding(.top, 10)

            if let fieldError {
                Text(fieldError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 15, leading: 16, bottom: 16, trailing: 16))
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(theme.hairline, lineWidth: 1)
        )
        .onAppear {
            // Seed the draft with the currently-saved ID so the user
            // can see what they entered last (and edit it if needed).
            if draft.isEmpty && !registrar.vibezId.isEmpty {
                draft = registrar.vibezId
            }
        }
    }

    private var pairBtnLabel: String {
        switch registrar.state {
        case .registering: return "..."
        default:           return "Pair"
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.fgMute)
                .lineLimit(2)
            Spacer(minLength: 0)
            if case .error = registrar.state {
                Button("retry") {
                    Task { await registrar.reregister() }
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.fg)
            }
        }
    }

    private var statusColor: Color {
        switch registrar.state {
        case .idle:        return .secondary
        case .registering: return .orange
        case .registered:  return .green
        case .error:       return .red
        }
    }

    private var statusLabel: String {
        switch registrar.state {
        case .idle:
            if registrar.vibezId.isEmpty {
                return "no Vibez ID yet"
            }
            return "waiting for FCM token…"
        case .registering:
            return "registering…"
        case .registered:
            return registrar.isTestMode ? "test mode (no server)" : "paired"
        case .error(let m):
            return "error: \(m.prefix(80))"
        }
    }

    // MARK: - Commit

    private func commit() {
        let id = trimmedDraft
        guard !id.isEmpty else { return }
        if !PushTokenRegistrar.isValidVibezId(id) {
            fieldError = "Format: 4 hyphenated words, each 3-5 letters (e.g. moss-pine-fox-jazz)."
            return
        }
        fieldError = nil
        focused = false
        registrar.setVibezId(id)
    }
}

#if DEBUG
#Preview("VibezSetupCard · idle") {
    VibezSetupCard(
        registrar: PushTokenRegistrar.shared,
        theme: Theme.make(agent: .claude)
    )
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
#endif
