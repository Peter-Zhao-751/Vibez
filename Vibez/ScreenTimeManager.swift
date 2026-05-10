//
//  ScreenTimeManager.swift
//  Vibez
//
//  Owns Family Controls authorization, persisted app selection, and the
//  ManagedSettings shield. Toggle blocking with `setBlocking(_:)`.
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
    private(set) var isBlocking = false
    private(set) var lastError: String?

    private let store = ManagedSettingsStore(named: .vibez)
    private let defaults = UserDefaults.standard

    private enum Key {
        static let selection = "vibez.selection.v1"
        static let blocking = "vibez.isBlocking.v1"
    }

    init() {
        loadSelection()
        isBlocking = defaults.bool(forKey: Key.blocking)
        syncAuthState()

        // If a previous session left blocking on, re-apply on launch so
        // the shield matches our persisted toggle state.
        if isBlocking {
            applyShield()
        } else {
            clearShield()
        }
    }

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
        if isBlocking {
            applyShield()
        }
    }

    func setBlocking(_ on: Bool) {
        isBlocking = on
        defaults.set(on, forKey: Key.blocking)
        if on {
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
}

private extension ManagedSettingsStore.Name {
    static let vibez = ManagedSettingsStore.Name("vibez.shield")
}
