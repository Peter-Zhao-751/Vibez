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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up notifications")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(theme.fg)

            Text("Run /vibez:setup in Claude Code or Codex on your Mac, then enter the 4-word Vibez ID it gave you here.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.fgMute)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if draft.isEmpty && !focused {
                        Text("moss-pine-fox-jazz")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(theme.fgFaint)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft)
                        .font(.system(size: 13, design: .monospaced))
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
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.bgWidget)
                )

                Button(action: commit) {
                    Text(saveBtnLabel)
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(saveable ? theme.onAccent : theme.fgMute)
                        .frame(minWidth: 44)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(saveable
                                      ? theme.saveActiveBg
                                      : AnyShapeStyle(theme.bgWidget))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!saveable)
            }

            statusRow

            if let fieldError {
                Text(fieldError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            // Seed the draft with the currently-saved ID so the user
            // can see what they entered last (and edit it if needed).
            if draft.isEmpty && !registrar.vibezId.isEmpty {
                draft = registrar.vibezId
            }
        }
    }

    private var saveBtnLabel: String {
        switch registrar.state {
        case .registering: return "..."
        default:           return "Save"
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
            return "paired"
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
        theme: Theme.make(agent: .claude, dark: true)
    )
    .padding()
    .background(Color.black)
}
#endif
