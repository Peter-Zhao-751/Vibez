//
//  ScreenTimeManager.swift
//  Vibez
//
//  Owns Family Controls authorization, persisted app selection, and the
//  ManagedSettings shield.
//
//  Blocking is the OR of two inputs:
//    • `manualBlocking` — what the user toggled in the big switch.
//    • `pendingTriggers` — one entry per Claude Code session_id that has
//      an open "Claude needs you" / "Claude finished" ping. Each entry
//      carries its own duration (snapshot of the user's blockSeconds at
//      arrival) and is removed when ANY of these happen:
//        1. the matching `_vibez:shield:off` push lands (user replied),
//        2. the user taps Dismiss on the overlay for that session,
//        3. its individual timer elapses.
//      The shield only lifts once every pending trigger is gone.
//

import Foundation
import FamilyControls
import ManagedSettings

/// A single open ping awaiting one of {reply, dismiss, timeout}. Keyed
/// by `sessionId` in the manager.
struct PendingTrigger: Codable, Equatable, Identifiable {
    let sessionId: String
    let addedAt: Date
    let durationSeconds: Int

    var id: String { sessionId }

    var expiresAt: Date {
        addedAt.addingTimeInterval(TimeInterval(durationSeconds))
    }

    func isExpired(now: Date) -> Bool {
        now >= expiresAt
    }
}

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
    /// Keyed by sessionId. A second ping in the same session overwrites
    /// the prior entry — that's intentional: the new ping "resets" the
    /// per-session timer, since it represents the latest unresolved
    /// state of that conversation.
    private(set) var pendingTriggers: [String: PendingTrigger] = [:]
    private(set) var isBlocking: Bool = false
    private(set) var lastError: String?

    private let store = ManagedSettingsStore(named: .vibez)
    private let defaults = UserDefaults.standard

    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private enum Key {
        static let selection = "vibez.selection.v1"
        static let manualBlocking = "vibez.manualBlocking.v1"
        /// v1: `[String]` of sessionIds. Migrated to v2 on first load.
        static let pendingTriggersV1 = "vibez.pendingTriggers.v1"
        /// v2: JSON-encoded `[PendingTrigger]`.
        static let pendingTriggersV2 = "vibez.pendingTriggers.v2"
        /// Legacy single-Bool key kept for one-shot manualBlocking migration.
        static let legacyBlocking = "vibez.isBlocking.v1"
    }

    /// Used when migrating v1 entries that don't know their original
    /// duration. Matches the @AppStorage default in ContentView.
    private static let migrationFallbackDuration = 1800

    init() {
        loadSelection()
        loadStateAndMigrate()
        syncAuthState()
        recomputeBlocking()  // also prunes anything that expired while off
        startTicking()
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
    /// stop, so the per-session timers no longer matter.
    func setBlocking(_ on: Bool) {
        manualBlocking = on
        if !on { pendingTriggers.removeAll() }
        persistManualBlocking()
        persistPendingTriggers()
        recomputeBlocking()
    }

    // MARK: - Per-session pending triggers

    /// Records a new pending trigger for `sessionId`. Snapshotting
    /// `durationSeconds` here means later edits to the user's slider
    /// don't retroactively extend (or shrink) an in-flight block.
    func addTrigger(sessionId: String, durationSeconds: Int) {
        guard !sessionId.isEmpty, sessionId != "nosid" else { return }
        let duration = max(1, durationSeconds)
        pendingTriggers[sessionId] = PendingTrigger(
            sessionId: sessionId,
            addedAt: Date(),
            durationSeconds: duration
        )
        persistPendingTriggers()
        recomputeBlocking()
    }

    /// Removes a single trigger by sessionId. Same code path is used by:
    /// reply (shield:off push), Dismiss button, and timer expiry.
    func resolveTrigger(sessionId: String) {
        guard !sessionId.isEmpty, sessionId != "nosid" else { return }
        guard pendingTriggers.removeValue(forKey: sessionId) != nil else { return }
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

    /// Runs the timer-driven prune. Cheap: a Dictionary scan plus the
    /// early-return inside `recomputeBlocking()` if nothing flipped.
    private func tick() {
        let pruned = pruneExpired()
        if pruned {
            recomputeBlocking()
        }
    }

    /// Removes any pending triggers whose per-session timer has run out.
    /// Returns true if anything was removed (caller decides whether to
    /// recompute the shield).
    @discardableResult
    private func pruneExpired() -> Bool {
        let now = Date()
        let expired = pendingTriggers.values.filter { $0.isExpired(now: now) }
        guard !expired.isEmpty else { return false }
        for trigger in expired {
            pendingTriggers.removeValue(forKey: trigger.sessionId)
        }
        persistPendingTriggers()
        return true
    }

    private func recomputeBlocking() {
        // Prune before deciding — an expired-but-unpruned entry would
        // otherwise keep the shield up for up to one tick longer.
        pruneExpired()

        let newValue = manualBlocking || !pendingTriggers.isEmpty
        if newValue == isBlocking { return }
        isBlocking = newValue
        if newValue {
            applyShield()
        } else {
            clearShield()
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
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
        if pendingTriggers.isEmpty {
            defaults.removeObject(forKey: Key.pendingTriggersV2)
            return
        }
        do {
            let data = try JSONEncoder().encode(Array(pendingTriggers.values))
            defaults.set(data, forKey: Key.pendingTriggersV2)
        } catch {
            lastError = "Failed to save pending triggers: \(error.localizedDescription)"
        }
    }

    private func loadStateAndMigrate() {
        // Manual-toggle migration (unchanged from before).
        if defaults.object(forKey: Key.manualBlocking) == nil,
           defaults.object(forKey: Key.legacyBlocking) != nil {
            manualBlocking = defaults.bool(forKey: Key.legacyBlocking)
            defaults.removeObject(forKey: Key.legacyBlocking)
            persistManualBlocking()
        } else {
            manualBlocking = defaults.bool(forKey: Key.manualBlocking)
        }

        // v2 wins if present.
        if let data = defaults.data(forKey: Key.pendingTriggersV2),
           let decoded = try? JSONDecoder().decode([PendingTrigger].self, from: data) {
            pendingTriggers = Dictionary(
                uniqueKeysWithValues: decoded.map { ($0.sessionId, $0) }
            )
            return
        }

        // One-shot v1 → v2 migration. We didn't record durations under
        // v1, so assume "added now" with the default duration — the user
        // can flip the toggle off to wipe if these stale entries bug
        // them.
        if let arr = defaults.array(forKey: Key.pendingTriggersV1) as? [String] {
            let now = Date()
            pendingTriggers = Dictionary(uniqueKeysWithValues: arr.compactMap { sid in
                guard !sid.isEmpty, sid != "nosid" else { return nil }
                return (sid, PendingTrigger(
                    sessionId: sid,
                    addedAt: now,
                    durationSeconds: Self.migrationFallbackDuration
                ))
            })
            defaults.removeObject(forKey: Key.pendingTriggersV1)
            persistPendingTriggers()
        }
    }
}

private extension ManagedSettingsStore.Name {
    static let vibez = ManagedSettingsStore.Name("vibez.shield")
}
