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

// Discrete duration stops for the slider — non-linear by design so a
// single slider covers seconds, minutes, and hours without burning
// resolution on values nobody picks.
private let durationStops: [Int] = [
    5, 15, 30,                    // seconds
    60, 120, 180, 240, 300,       // 1–5 minutes
    600, 900, 1800, 2700,         // 10, 15, 30, 45 minutes
    3600, 7200, 14400, 28800,     // 1h, 2h, 4h, 8h
]

private func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    let h = seconds / 3600
    let rem = (seconds % 3600) / 60
    return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
}

struct SettingsView: View {
    @Binding var isPresented: Bool
    @Bindable var manager: ScreenTimeManager

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.blockSeconds") private var blockSeconds = 1800
    @AppStorage("vibez.ntfyURL") private var ntfyURL = ""

    @State private var pickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()
    @FocusState private var ntfyFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                appsSection
                durationSection
                notificationsSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        ntfyFieldFocused = false
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { ntfyFieldFocused = false }
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
                Text(formatDuration(blockSeconds))
                    .monospaced()
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: durationIndexBinding,
                in: 0...Double(durationStops.count - 1),
                step: 1
            ) {
                Text("Duration")
            } minimumValueLabel: {
                Text("5s")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("8h")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Block duration")
        } footer: {
            Text("How long apps stay shielded after Claude or Codex pings you. Stops are 5s, 15s, 30s, 1m, 2m, 3m, 4m, 5m, 10m, 15m, 30m, 45m, 1h, 2h, 4h, 8h.")
        }
    }

    private var durationIndexBinding: Binding<Double> {
        Binding(
            get: {
                let idx = durationStops.firstIndex(of: blockSeconds)
                    ?? closestStopIndex(to: blockSeconds)
                return Double(idx)
            },
            set: { newValue in
                blockSeconds = durationStops[Int(newValue.rounded())]
            }
        )
    }

    private func closestStopIndex(to seconds: Int) -> Int {
        var best = 0
        var bestDelta = Int.max
        for (i, s) in durationStops.enumerated() {
            let d = abs(s - seconds)
            if d < bestDelta { bestDelta = d; best = i }
        }
        return best
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            TextField("https://ntfy.sh/your-topic", text: $ntfyURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($ntfyFieldFocused)
                .submitLabel(.done)
                .onSubmit { ntfyFieldFocused = false }
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
    SettingsView(isPresented: .constant(true), manager: ScreenTimeManager())
}
