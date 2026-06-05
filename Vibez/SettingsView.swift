//
//  SettingsView.swift
//  Vibez
//
//  Sheet presented from the top-right gear button. Lets the user pick
//  apps to block, set the block duration, change the Vibez ID this
//  phone is paired to, and override the appearance preference.
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
    @Bindable var registrar: PushTokenRegistrar
    @Bindable var triggerStore: TriggerStore
    @Bindable var ignoreStore: IgnoreStore

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.blockSeconds.needsInput") private var blockSecondsNeedsInput = 900
    @AppStorage("vibez.blockSeconds.done") private var blockSecondsDone = 30
    @AppStorage("vibez.overlayOrder") private var overlayOrderRaw = OverlayOrder.stack.rawValue
    @AppStorage("vibez.allowDismiss") private var allowDismiss = true
    @AppStorage("vibez.notifyBanners") private var notifyBanners = true
    @AppStorage("vibez.showFocusHint") private var showFocusHint = true
    @AppStorage("vibez.onboardingCompleted") private var onboardingCompleted = false

    @State private var pickerPresented = false
    @State private var draftSelection = FamilyActivitySelection()
    @State private var showAddIgnoreSheet = false
    @State private var vibezIdDraft: String = ""
    @State private var vibezIdError: String? = nil
    @State private var tutorial: OnboardingState?
    @State private var copiedFeedback = false
    @FocusState private var vibezIdFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme

    /// Opens the system FamilyActivityPicker seeded with the current
    /// selection. The draft is re-created with `includeEntireCategory`
    /// so a category pick comes back expanded into its member apps
    /// (see `expandingCategories`). Reached from anywhere in the
    /// "Apps to block" component.
    private func presentPicker() {
        draftSelection = manager.selection.expandingCategories
        pickerPresented = true
    }

    private func dismissSheet() {
        vibezIdFocused = false
        // Push any block-duration edits to the server so it schedules
        // timeout unblocks with the latest values. reregister() re-reads
        // the durations from UserDefaults. Design spec §1.
        Task { await registrar.reregister() }
        isPresented = false
        dismiss()
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                appsSection
                durationSection
                overlaySection
                notificationsSection
                vibezIdSection
                ignoredConversationsSection
                tutorialSection
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
                title: "Select apps to block",
                isPresented: $pickerPresented,
                selection: $draftSelection
            )
            .onChange(of: pickerPresented) { _, presented in
                if !presented {
                    // Persist only real edits. A cancelled/unchanged picker
                    // still hands back the draft — which presentPicker()
                    // re-created with includeEntireCategory — and saving
                    // that flag flip without the picker having expanded the
                    // pre-seeded categories would hide their icons
                    // (displayCategoryTokens) while the shield still
                    // blocks them.
                    let unchanged = draftSelection.applicationTokens == manager.selection.applicationTokens
                        && draftSelection.categoryTokens == manager.selection.categoryTokens
                        && draftSelection.webDomainTokens == manager.selection.webDomainTokens
                    if !unchanged {
                        manager.updateSelection(draftSelection)
                    }
                }
            }
            .sheet(isPresented: $showAddIgnoreSheet) {
                AddIgnoreSheet(
                    triggerStore: triggerStore,
                    ignoreStore: ignoreStore
                )
            }
            .fullScreenCover(item: $tutorial) { s in
                OnboardingFlow(
                    state: s,
                    manager: manager,
                    registrar: registrar,
                    onDismiss: { tutorial = nil },
                    // Manual replay — never auto-arms, but finishing it
                    // counts as a completed walkthrough.
                    onFinish: {
                        onboardingCompleted = true
                        tutorial = nil
                    }
                )
            }
        }
        // Must sit on the sheet's content root (the NavigationStack), NOT
        // on the inner Form. The sheet's hosting controller reads this
        // preference at the root of its content tree once on present and
        // again on every change; placed on an inner view it applied at
        // present time but went stale when the Appearance picker flipped
        // it — the rest of the app recolored, this sheet didn't.
        .preferredColorScheme(appearanceScheme)
    }

    /// The color scheme the Appearance preference resolves to (nil =
    /// follow system). Single source feeding the sheet's
    /// `.preferredColorScheme`, mirroring ContentView's `appearance`.
    private var appearanceScheme: ColorScheme? {
        (AppearancePref(rawValue: appearanceRaw) ?? .system).colorScheme
    }

    // MARK: Sections

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearancePref.allCases) { pref in
                    Text(pref.label).tag(pref.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Show focus-mode hint", isOn: $showFocusHint)
        } header: {
            Text("Appearance")
        } footer: {
            Text("The “tap to enter focus mode” caption under the mascot on the home screen.")
        }
    }

    /// The trailing "N selected" label + chevron. Flows as the final item
    /// after the app icons.
    @ViewBuilder
    private func appsCountLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        Section {
            if manager.hasSelection {
                // Whole component is one tap target. No "Pick apps" label —
                // the app icons flow top-left and wrap, while the "N selected"
                // count sits at the top-right with the icons flowing around it
                // (see AppsFlowLayout). Rectangle content shape so the empty
                // space and the gaps between icons all open the picker.
                Button {
                    presentPicker()
                } label: {
                    Group {
                        AppsFlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(Array(manager.selection.applicationTokens), id: \.self) { token in
                                SettingsBlockedTokenIcon { Label(token) }
                            }
                            // Expanded selections show member apps, not the
                            // category icon — see displayCategoryTokens.
                            ForEach(manager.selection.displayCategoryTokens, id: \.self) { token in
                                SettingsBlockedTokenIcon { Label(token) }
                            }
                            ForEach(Array(manager.selection.webDomainTokens), id: \.self) { token in
                                SettingsBlockedTokenIcon { Label(token) }
                            }
                            // MUST be last — AppsFlowLayout pins the final
                            // subview to the top-right.
                            appsCountLabel("\(manager.selectedCount) selected")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityLabel("Apps to block, \(manager.selectedCount) selected")
                .accessibilityHint("Opens the app picker")
            } else if manager.authState == .authorized {
                Button {
                    presentPicker()
                } label: {
                    HStack(spacing: 10) {
                        Label {
                            Text("Pick apps to block")
                                .foregroundStyle(Color.primary)
                        } icon: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Apps to block, none selected")
                .accessibilityHint("Opens the app picker")
            }

            if manager.authState != .authorized {
                screenTimeAccessWarningButton
            }
        } header: {
            Text("Apps to block")
        } footer: {
            Text("Apple does not let apps preset Instagram or TikTok by name. Pick them yourself in the system picker.")
        }
    }

    private var screenTimeAccessWarningButton: some View {
        Button(action: openAppSettings) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                Text("Screen Time access not granted — tap to open Settings and enable it.")
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screen Time access not granted")
        .accessibilityHint("Opens Settings")
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

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            Toggle("Show notifications", isOn: $notifyBanners)
        } header: {
            Text("Notifications")
        } footer: {
            Text("When on, Vibez shows a banner with sound each time Claude or Codex pings you. When off, your apps still get blocked — the alert just slips silently into Notification Center, with no banner or sound.")
        }
    }

    @ViewBuilder
    private var tutorialSection: some View {
        Section {
            Button {
                let s = OnboardingState(manager: manager, registrar: registrar)
                Task {
                    // Snapshot AFTER the async status read so the step
                    // list sees the real notification gate.
                    await s.refreshNotificationStatus()
                    s.begin()
                    tutorial = s
                }
            } label: {
                HStack {
                    Label("Tutorial", systemImage: "graduationcap")
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            Text("Replays the setup walkthrough. Steps you've already completed are skipped — fully set up, it's a quick tour of how Vibez works plus the app version.")
        }
    }

    // MARK: Vibez ID

    @ViewBuilder
    private var vibezIdSection: some View {
        Section {
            // One part: the paired ID *is* the field. Tap it to edit in
            // place; its color is the status (green = paired, orange =
            // registering, red = error, gray placeholder = nothing yet).
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    if vibezIdDraft.isEmpty && !vibezIdFocused {
                        Text("moss-pine-fox-jazz")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $vibezIdDraft)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(vibezIdFieldColor)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($vibezIdFocused)
                        .submitLabel(.done)
                        .onSubmit { commitVibezId() }
                        .onChange(of: vibezIdDraft) { _, _ in
                            if vibezIdError != nil { vibezIdError = nil }
                        }
                }

                if vibezIdFocused && vibezIdDraftIsCommittable {
                    Button("Save") { commitVibezId() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                } else if !vibezIdFocused && !registrar.vibezId.isEmpty && vibezIdDraft == registrar.vibezId {
                    Button(action: copyVibezId) {
                        Text(copiedFeedback ? "Copied" : "Copy")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onAppear { vibezIdDraft = registrar.vibezId }
            .onChange(of: vibezIdFocused) { _, focused in
                // Blur without committing reverts to the saved ID — but a
                // failed attempt stays visible (with its red caption) so
                // the user can tap back in and fix it.
                if !focused && vibezIdError == nil {
                    vibezIdDraft = registrar.vibezId
                }
            }
            .onChange(of: registrar.vibezId) { _, newId in
                if !vibezIdFocused { vibezIdDraft = newId }
            }

            if let err = vibezIdError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if case .error(let message) = registrar.state {
                Text("Pairing failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } header: {
            Text("Vibez ID")
        } footer: {
            Text("This phone listens to one Vibez ID. Run /vibez:setup (Claude Code) or the vibez-setup skill (Codex) on a Mac to see or regenerate its ID, then tap the ID above to re-pair.")
        }
    }

    private var vibezIdDraftIsCommittable: Bool {
        let trimmed = vibezIdDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return PushTokenRegistrar.isValidVibezId(trimmed)
            && trimmed != registrar.vibezId
    }

    /// Neutral while editing; otherwise the registrar status — with a
    /// red override while an uncommitted bad attempt is on screen
    /// (the text shown isn't the paired ID, so green would lie).
    private var vibezIdFieldColor: Color {
        if vibezIdFocused { return .primary }
        if vibezIdError != nil { return .red }
        switch registrar.state {
        case .registered:  return .green
        case .registering: return .orange
        case .error:       return .red
        case .idle:        return .secondary
        }
    }

    private func commitVibezId() {
        let trimmed = vibezIdDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            vibezIdFocused = false
            return
        }
        if !PushTokenRegistrar.isValidVibezId(trimmed) {
            vibezIdError = "Format: 4 hyphenated words, each 3-5 letters."
            return
        }
        vibezIdError = nil
        // Set the registrar before dropping focus: the blur handler
        // resets the draft to registrar.vibezId, which must already be
        // the new value.
        registrar.setVibezId(trimmed)
        vibezIdDraft = trimmed
        vibezIdFocused = false
    }

    private func copyVibezId() {
        UIPasteboard.general.string = registrar.vibezId
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copiedFeedback = false
        }
    }
}

// MARK: - Blocked app icons

private struct SettingsBlockedTokenIcon<Icon: View>: View {
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        icon()
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .dynamicTypeSize(.accessibility5)
            .scaleEffect(1.55, anchor: .center)
            .frame(width: 34, height: 34)
    }
}

// MARK: - Apps flow layout

/// Lays out app icons (all subviews EXCEPT the last) flowing top-left and
/// wrapping like text at FULL width, then pins the LAST subview — the
/// "N selected" label — to the BOTTOM-right. The label shares the last
/// icon row when there's room to its right; otherwise it drops to its own
/// row beneath. Rows above are never narrowed. Icons are assumed roughly
/// uniform height (SettingsBlockedTokenIcon pins 34×34).
private struct AppsFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private struct Plan {
        var iconFrames: [CGRect] = []
        var labelFrame: CGRect = .zero
        var size: CGSize = .zero
    }

    private func plan(_ subviews: Subviews, width: CGFloat) -> Plan {
        var out = Plan()
        guard !subviews.isEmpty else { return out }

        let labelIndex = subviews.count - 1
        let labelSize = subviews[labelIndex].sizeThatFits(.unspecified)
        let iconCount = labelIndex
        let iconSizes = (0..<iconCount).map { subviews[$0].sizeThatFits(.unspecified) }
        let iconRowHeight = iconSizes.map(\.height).max() ?? 0
        let maxWidth = width.isFinite
            ? width
            : iconSizes.map(\.width).reduce(0, +) + labelSize.width
                + CGFloat(iconCount + 1) * spacing

        // Flow the icons at full width — rows above the label are never
        // narrowed to make room for it.
        var frames = [CGRect](repeating: .zero, count: iconCount)
        var x: CGFloat = 0
        var y: CGFloat = 0
        for i in 0..<iconCount {
            let size = iconSizes[i]
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += iconRowHeight + lineSpacing
            }
            frames[i] = CGRect(
                x: x, y: y + (iconRowHeight - size.height) / 2,
                width: size.width, height: size.height
            )
            x += size.width + spacing
        }

        // Place the label bottom-right: on the last icon row if it fits to
        // the right of the last icon, else on a fresh row beneath.
        let labelX = max(0, maxWidth - labelSize.width)
        let labelY: CGFloat
        let totalHeight: CGFloat
        if iconCount == 0 {
            labelY = 0
            totalHeight = labelSize.height
        } else if labelSize.width <= maxWidth - x {            // x = end of last row + spacing
            labelY = y + (iconRowHeight - labelSize.height) / 2
            totalHeight = y + iconRowHeight
        } else {
            labelY = y + iconRowHeight + lineSpacing
            totalHeight = labelY + labelSize.height
        }

        out.iconFrames = frames
        out.labelFrame = CGRect(x: labelX, y: labelY, width: labelSize.width, height: labelSize.height)
        out.size = CGSize(width: width.isFinite ? width : maxWidth, height: totalHeight)
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(subviews, width: bounds.width)
        for (i, frame) in p.iconFrames.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
        if let last = subviews.indices.last {
            subviews[last].place(
                at: CGPoint(x: bounds.minX + p.labelFrame.minX, y: bounds.minY + p.labelFrame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(p.labelFrame.size)
            )
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
                  sid.isUsableSessionId,
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

#if DEBUG
#Preview {
    SettingsView(
        isPresented: .constant(true),
        manager: ScreenTimeManager(),
        notifyClient: NotifyClient(),
        registrar: PushTokenRegistrar.previewRegistrar(),
        triggerStore: TriggerStore(),
        ignoreStore: IgnoreStore()
    )
}
#endif
