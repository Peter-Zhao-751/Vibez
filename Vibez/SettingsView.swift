//
//  SettingsView.swift
//  Vibez
//
//  Sheet presented from the top-right gear button. Lets the user pick
//  apps to block, set the block duration, paste their ntfy.sh URL, and
//  override the appearance preference.
//

import SwiftUI
import UIKit
import FamilyControls
import ManagedSettings

// Discrete duration stops for the slider — non-linear by design so a
// single slider covers seconds, minutes, and hours without burning
// resolution on values nobody picks.
private let durationStops: [Int] = [
    5, 15, 30,                    // seconds
    60, 120, 180, 240, 300,       // 1–5 minutes
    600, 900, 1800, 2700,         // 10, 15, 30, 45 minutes
    3600,     // 1h
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
    @Bindable var notifyClient: NotifyClient
    @Bindable var triggerStore: TriggerStore
    @Bindable var ignoreStore: IgnoreStore

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.blockSeconds.needsInput") private var blockSecondsNeedsInput = 900
    @AppStorage("vibez.blockSeconds.done") private var blockSecondsDone = 30
    @AppStorage("vibez.overlayOrder") private var overlayOrderRaw = OverlayOrder.stack.rawValue
    @AppStorage("vibez.allowDismiss") private var allowDismiss = true

    @State private var pickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()
    @State private var showAddIgnoreSheet = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme

    private func dismissSheet() {
        isPresented = false
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                appsSection
                durationSection
                overlaySection
                ignoredConversationsSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismissSheet)
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
            .onChange(of: appearanceRaw) { _, newRaw in
                (AppearancePref(rawValue: newRaw) ?? .system).applyToWindows()
            }
            .sheet(isPresented: $showAddIgnoreSheet) {
                AddIgnoreSheet(
                    triggerStore: triggerStore,
                    ignoreStore: ignoreStore
                )
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
            if manager.hasSelection {
                BlockedSelectionIconGrid(selection: manager.selection)
            }

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
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label {
                            Text("Screen Time access not granted — tap to open Settings and enable it.")
                                .font(.caption)
                                .foregroundStyle(Color.primary)
                                .multilineTextAlignment(.leading)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
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
            durationRow(label: "Needs input", value: $blockSecondsNeedsInput)
            durationRow(label: "Done",        value: $blockSecondsDone)
        } header: {
            Text("Block duration")
        } footer: {
            Text("Needs input: how long apps stay blocked while Claude is waiting on you. Done: how long after Claude wraps a turn that doesn't need you.")
        }
    }

    @ViewBuilder
    private func durationRow(label: String, value: Binding<Int>) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(label)
                Spacer()
                Text(formatDuration(value.wrappedValue))
                    .monospaced()
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: durationIndexBinding(for: value),
                in: 0...Double(durationStops.count - 1),
                step: 1
            ) {
                Text(label)
            } minimumValueLabel: {
                Text("5s")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("1h")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func durationIndexBinding(for value: Binding<Int>) -> Binding<Double> {
        Binding(
            get: {
                let idx = durationStops.firstIndex(of: value.wrappedValue)
                    ?? closestStopIndex(to: value.wrappedValue)
                return Double(idx)
            },
            set: { newValue in
                value.wrappedValue = durationStops[Int(newValue.rounded())]
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
    private var overlaySection: some View {
        Section {
            Picker("Show", selection: $overlayOrderRaw) {
                ForEach(OverlayOrder.allCases) { order in
                    Text(order.label).tag(order.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Show dismiss button", isOn: $allowDismiss)
        } header: {
            Text("Block overlay")
        } footer: {
            Text("Order: \"Newest first\" puts the latest ping on top and reveals older blocks as you dismiss; \"Oldest first\" keeps the earliest unresolved block visible until you dismiss it. Dismiss button: when off, the only ways out are replying in Claude/Codex or letting the countdown expire.")
        }
    }

}

// MARK: - Blocked app icons

private struct BlockedSelectionIconGrid: View {
    let selection: FamilyActivitySelection

    private let columns = [
        GridItem(.adaptive(minimum: 34), spacing: 8, alignment: .leading)
    ]

    private var apps: [ApplicationToken] { Array(selection.applicationTokens) }
    private var cats: [ActivityCategoryToken] { Array(selection.categoryTokens) }
    private var webs: [WebDomainToken] { Array(selection.webDomainTokens) }

    private var selectedCount: Int {
        apps.count + cats.count + webs.count
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(apps, id: \.self) { token in
                SettingsBlockedTokenIcon { Label(token) }
            }
            ForEach(cats, id: \.self) { token in
                SettingsBlockedTokenIcon { Label(token) }
            }
            ForEach(webs, id: \.self) { token in
                SettingsBlockedTokenIcon { Label(token) }
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(selectedCount) selected apps")
    }
}

private struct SettingsBlockedTokenIcon<Icon: View>: View {
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        icon()
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .dynamicTypeSize(.accessibility5)
            .scaleEffect(1.55, anchor: .center)
            .frame(width: 34, height: 34)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
            }
    }
}

// MARK: - Ignored conversations

extension SettingsView {

    @ViewBuilder
    fileprivate var ignoredConversationsSection: some View {
        Section {
            if ignoreStore.rules.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)
                    Text("Nothing muted yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(ignoreStore.rules) { rule in
                    HStack(spacing: 10) {
                        Image(systemName: rule.isNameRule ? "tag.slash.fill" : "bell.slash.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.displayName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(rule.isNameRule
                                 ? "Mutes every conversation with this name"
                                 : "Mutes only this session")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            withAnimation {
                                ignoreStore.remove(ruleId: rule.id)
                            }
                        } label: {
                            Label("Unmute", systemImage: "bell")
                        }
                    }
                }
            }

            Button {
                showAddIgnoreSheet = true
            } label: {
                HStack {
                    Label("Add from recent triggers", systemImage: "plus.circle")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Conversations to ignore")
        } footer: {
            Text("Mute one session (\(Image(systemName: "bell.slash.fill"))) or every conversation that shares a name (\(Image(systemName: "tag.slash.fill")))  — handy for a recurring agent that gets a new session id every run. Long-press a Recent trigger to pick which kind.")
        }
    }
}

// MARK: - Add-from-recent sheet

private struct AddIgnoreSheet: View {
    @Bindable var triggerStore: TriggerStore
    @Bindable var ignoreStore: IgnoreStore

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var picked: Candidate?

    fileprivate struct Candidate: Equatable, Identifiable {
        let sid: String
        let name: String
        var id: String { sid }
    }

    /// Recent conversations not yet covered by any rule, de-duped by sid
    /// and in trigger-arrival order (newest first).
    private var candidates: [Candidate] {
        var seenSids = Set<String>()
        var out: [Candidate] = []
        for event in triggerStore.events {
            guard let sid = event.sessionId,
                  !sid.isEmpty, sid != "nosid",
                  let name = event.title, !name.isEmpty,
                  seenSids.insert(sid).inserted,
                  !ignoreStore.contains(sessionId: sid, name: name)
            else { continue }
            out.append(Candidate(sid: sid, name: name))
        }
        return out
    }

    private var filtered: [Candidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "tray")
                            .foregroundStyle(.tertiary)
                            .frame(width: 18)
                        Text("No recent conversations yet — they'll appear here once Claude or Codex pings you.")
                            .foregroundStyle(.secondary)
                    }
                } else if filtered.isEmpty {
                    Text("No matches.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { row in
                        Button {
                            picked = row
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "bell.slash")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 18)
                                Text(row.name)
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search by name"
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Mute a conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                picked.map { "Mute \"\($0.name)\"" } ?? "",
                isPresented: Binding(
                    get: { picked != nil },
                    set: { if !$0 { picked = nil } }
                ),
                titleVisibility: .visible,
                presenting: picked
            ) { row in
                Button("Just this session") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        ignoreStore.ignoreSession(sessionId: row.sid, name: row.name)
                    }
                    picked = nil
                }
                Button("Every conversation with this name") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        ignoreStore.ignoreName(row.name)
                    }
                    picked = nil
                }
                Button("Cancel", role: .cancel) { picked = nil }
            } message: { _ in
                Text("Session rules end with the conversation. Name rules also catch future runs that share this title — handy for cron-launched agents.")
            }
        }
    }
}

#Preview {
    SettingsView(
        isPresented: .constant(true),
        manager: ScreenTimeManager(),
        notifyClient: NotifyClient(),
        triggerStore: TriggerStore(),
        ignoreStore: IgnoreStore()
    )
}
