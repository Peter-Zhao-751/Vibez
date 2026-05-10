//
//  SettingsView.swift
//  Vibez
//
//  Sheet presented from the top-right gear button. Lets the user pick
//  apps to block, set the block duration, paste their ntfy.sh URL, and
//  override the appearance preference.
//

import SwiftUI
import FamilyControls

struct SettingsView: View {
    @Bindable var manager: ScreenTimeManager
    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.blockDuration") private var blockDurationMinutes = 30
    @AppStorage("vibez.ntfyURL") private var ntfyURL = ""

    @State private var pickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                appsSection
                durationSection
                notificationsSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .familyActivityPicker(
                isPresented: $pickerPresented,
                selection: $draftSelection
            )
            .onChange(of: pickerPresented) { _, presented in
                if !presented {
                    manager.updateSelection(draftSelection)
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearancePref.allCases) { pref in
                    Text(pref.label).tag(pref.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        Section {
            Button {
                draftSelection = manager.selection
                pickerPresented = true
            } label: {
                HStack {
                    Text("Pick apps")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text(manager.hasSelection ? "\(manager.selectedCount) selected" : "None")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if manager.authState != .authorized {
                Label {
                    Text("Screen Time access not granted yet — picker may not work until you approve it on launch.")
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Apps to block")
        } footer: {
            Text("Apple does not let apps preset Instagram or TikTok by name. Pick them yourself in the system picker.")
        }
    }

    @ViewBuilder
    private var durationSection: some View {
        Section {
            HStack {
                Text("Duration")
                Spacer()
                Text("\(blockDurationMinutes) min")
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            Stepper(
                value: $blockDurationMinutes,
                in: 1...720,
                step: 5
            ) {
                Text("Adjust")
            }
            .labelsHidden()
        } header: {
            Text("Block duration")
        } footer: {
            Text("How long apps stay shielded after Claude or Codex pings you. Auto-unlocks after this.")
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            TextField("https://ntfy.sh/your-topic", text: $ntfyURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if !ntfyURL.isEmpty {
                Button("Clear", role: .destructive) {
                    ntfyURL = ""
                }
            }
        } header: {
            Text("Notify link")
        } footer: {
            Text("Run /ntfy-setup in Claude Code on your Mac to get this URL. Used as a hint inside the iOS app — actual subscribing happens in the ntfy app.")
        }
    }
}

#Preview {
    SettingsView(manager: ScreenTimeManager())
}
