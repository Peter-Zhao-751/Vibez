//
//  ContentView.swift
//  Vibez
//

import SwiftUI
import FamilyControls

struct ContentView: View {
    @State private var manager = ScreenTimeManager()
    @State private var pickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()

    var body: some View {
        NavigationStack {
            Form {
                authSection

                if manager.authState == .authorized {
                    pickerSection
                    toggleSection
                }

                infoSection
            }
            .navigationTitle("Vibez")
        }
        .task {
            if manager.authState == .notDetermined {
                await manager.requestAuthorization()
            }
        }
        .familyActivityPicker(isPresented: $pickerPresented, selection: $draftSelection)
        .onChange(of: pickerPresented) { _, isShowing in
            if !isShowing {
                manager.updateSelection(draftSelection)
            }
        }
    }

    @ViewBuilder
    private var authSection: some View {
        Section("Status") {
            switch manager.authState {
            case .notDetermined, .requesting:
                HStack {
                    ProgressView()
                    Text("Requesting Screen Time access…")
                }
            case .authorized:
                Label("Screen Time access granted", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Screen Time access denied", systemImage: "xmark.seal.fill")
                        .foregroundStyle(.red)
                    Text("Open Settings → Screen Time, allow the request, then tap Try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await manager.requestAuthorization() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pickerSection: some View {
        Section("Apps to block") {
            Button {
                draftSelection = manager.selection
                pickerPresented = true
            } label: {
                HStack {
                    Text("Pick apps")
                    Spacer()
                    Text(manager.hasSelection ? "\(manager.selectedCount) selected" : "None")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var toggleSection: some View {
        Section {
            Toggle(
                "Block apps",
                isOn: Binding(
                    get: { manager.isBlocking },
                    set: { manager.setBlocking($0) }
                )
            )
            .disabled(!manager.hasSelection)

            if !manager.hasSelection {
                Text("Pick at least one app first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        Section("How it works") {
            Text("When the toggle is on, the apps you picked are shielded by iOS — opening one shows a Screen Time block. Toggle off to unblock.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
