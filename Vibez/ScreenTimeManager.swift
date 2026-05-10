//
//  ScreenTimeManager.swift
//  Vibez
//
//  Owns Family Controls authorization, persisted app selection, and the
//  ManagedSettings shield.
//
//  Blocking is the OR of two inputs:
//    • `manualBlocking` — what the user toggled in the big switch.
//    • `pendingTriggers` — set of Claude Code session_ids that have an
//      open "Claude needs you" / "Claude finished" ping. Each entry is
//      added when a `_vibez:block:<sid>` ntfy push arrives and removed
//      when the matching `_vibez:unblock:<sid>` push lands (the user
//      replied in that conversation).
//

import Foundation
import FamilyControls
import ManagedSettings

@MainActor
@Observable
final class ScreenTimeManager {
    enum AuthState: Equatable {
        case notDetermined
        case requesting
        case authorized
        case denied
    }

    private(set) var authState: AuthState = .notDetermined
    private(set) var selection = FamilyActivitySelection()
    private(set) var manualBlocking: Bool = false
    private(set) var pendingTriggers: Set<String> = []
    private(set) var isBlocking: Bool = false
    private(set) var lastError: String?

    private let store = ManagedSettingsStore(named: .vibez)
    private let defaults = UserDefaults.standard

    private enum Key {
        static let selection = "vibez.selection.v1"
        static let manualBlocking = "vibez.manualBlocking.v1"
        static let pendingTriggers = "vibez.pendingTriggers.v1"
        /// Legacy key kept for one-shot migration only.
        static let legacyBlocking = "vibez.isBlocking.v1"
    }

    init() {
        loadSelection()
        loadStateAndMigrate()
        syncAuthState()
        recomputeBlocking()
    }

    // MARK: - Selection helpers

    var hasSelection: Bool {
        !selection.applicationTokens.isEmpty
            || !selection.categoryTokens.isEmpty
            || !selection.webDomainTokens.isEmpty
    }

    var selectedCount: Int {
        selection.applicationTokens.count
            + selection.categoryTokens.count
            + selection.webDomainTokens.count
    }

    var pendingCount: Int { pendingTriggers.count }

    // MARK: - Authorization

    func requestAuthorization() async {
        authState = .requesting
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            syncAuthState()
        } catch {
            lastError = error.localizedDescription
            authState = .denied
        }
    }

    func updateSelection(_ newSelection: FamilyActivitySelection) {
        selection = newSelection
        persistSelection()
        if isBlocking { applyShield() }
    }

    // MARK: - User-facing toggle

    /// Manual toggle from the big switch. When the user turns it OFF we
    /// also clear any pending triggers — they've explicitly decided to
    /// stop, no point keeping the auto-block alive.
    func setBlocking(_ on: Bool) {
        manualBlocking = on
        if !on { pendingTriggers.removeAll() }
        persistManualBlocking()
        persistPendingTriggers()
        recomputeBlocking()
    }

    // MARK: - Per-session pending triggers

    func addTrigger(sessionId: String) {
        guard !sessionId.isEmpty, sessionId != "nosid" else { return }
        pendingTriggers.insert(sessionId)
        persistPendingTriggers()
        recomputeBlocking()
    }

    func resolveTrigger(sessionId: String) {
        guard !sessionId.isEmpty, sessionId != "nosid" else { return }
        pendingTriggers.remove(sessionId)
        persistPendingTriggers()
        recomputeBlocking()
    }

    /// Drop everything pending — useful as an escape hatch.
    func clearTriggers() {
        guard !pendingTriggers.isEmpty else { return }
        pendingTriggers.removeAll()
        persistPendingTriggers()
        recomputeBlocking()
    }

    // MARK: - Internal

    private func recomputeBlocking() {
        let newValue = manualBlocking || !pendingTriggers.isEmpty
        if newValue == isBlocking { return }
        isBlocking = newValue
        if newValue {
            applyShield()
        } else {
            clearShield()
        }
    }

    private func syncAuthState() {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved:
            authState = .authorized
        case .denied:
            authState = .denied
        case .notDetermined:
            authState = .notDetermined
        @unknown default:
            authState = .notDetermined
        }
    }

    private func applyShield() {
        let apps = selection.applicationTokens
        let cats = selection.categoryTokens
        let webs = selection.webDomainTokens

        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)
        store.shield.webDomains = webs.isEmpty ? nil : webs
    }

    private func clearShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
    }

    // MARK: - Persistence

    private func persistSelection() {
        do {
            let data = try PropertyListEncoder().encode(selection)
            defaults.set(data, forKey: Key.selection)
        } catch {
            lastError = "Failed to save selection: \(error.localizedDescription)"
        }
    }

    private func loadSelection() {
        guard let data = defaults.data(forKey: Key.selection) else { return }
        do {
            selection = try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            lastError = "Failed to load saved selection: \(error.localizedDescription)"
        }
    }

    private func persistManualBlocking() {
        defaults.set(manualBlocking, forKey: Key.manualBlocking)
    }

    private func persistPendingTriggers() {
        defaults.set(Array(pendingTriggers), forKey: Key.pendingTriggers)
    }

    private func loadStateAndMigrate() {
        // Migrate the old single-Bool key the first time we see it.
        if defaults.object(forKey: Key.manualBlocking) == nil,
           defaults.object(forKey: Key.legacyBlocking) != nil {
            manualBlocking = defaults.bool(forKey: Key.legacyBlocking)
            defaults.removeObject(forKey: Key.legacyBlocking)
            persistManualBlocking()
        } else {
            manualBlocking = defaults.bool(forKey: Key.manualBlocking)
        }
        if let arr = defaults.array(forKey: Key.pendingTriggers) as? [String] {
            pendingTriggers = Set(arr)
        }
    }
}

private extension ManagedSettingsStore.Name {
    static let vibez = ManagedSettingsStore.Name("vibez.shield")
}
