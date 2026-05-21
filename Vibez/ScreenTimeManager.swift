//
//  ScreenTimeManager.swift
//  Vibez
//
//  Owns Family Controls authorization, persisted app selection, and the
//  ManagedSettings shield.
//
//  Two-state model:
//    • `armed` — the big toggle. Master switch. When OFF, every pending
//      trigger is cleared and the shield comes down. When ON, Vibez
//      listens for pings but does NOT shield by itself — the shield only
//      goes up while there's an active trigger (i.e., an in-app overlay
//      is showing). This mirrors what the user sees: overlay up ↔ apps
//      shielded. The OR-with-manual model used to keep the shield up
//      between pings; that was confusing and is gone.
//    • `pendingTriggers` — one entry per Claude Code session_id with an
//      open "needs you" / "finished" ping. Each carries its own duration
//      (snapshot of the user's blockSeconds at arrival) and is removed
//      when ANY of these happen:
//        1. the matching `_vibez:shield:off` push lands (user replied),
//        2. the user taps Dismiss on the overlay for that session,
//        3. its individual timer elapses,
//        4. the toggle flips OFF.
//      `isBlocking` = `!pendingTriggers.isEmpty`. Shield follows it 1:1.
//

import Foundation
import FamilyControls
import ManagedSettings
import OSLog

private let shieldLog = Logger(subsystem: "vibezlol.Vibez", category: "Shield")

struct ShieldState {
    enum Agent: String {
        case claude, codex, both, none
    }

    var agent: Agent
    var title: String?
    var body: String?
    var expiresAt: Date?
    var dark: Bool

    var asDict: [String: Any] {
        var d: [String: Any] = [
            "agent": agent.rawValue,
            "dark": dark,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let title { d["title"] = title }
        if let body  { d["body"]  = body }
        if let expiresAt { d["expiresAt"] = expiresAt.timeIntervalSince1970 }
        return d
    }
}

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
    /// Master switch (the big toggle). Doesn't shield by itself — gates
    /// whether incoming pings are accepted as triggers.
    private(set) var armed: Bool = false
    /// Keyed by sessionId. A second ping in the same session overwrites
    /// the prior entry — that's intentional: the new ping "resets" the
    /// per-session timer, since it represents the latest unresolved
    /// state of that conversation.
    private(set) var pendingTriggers: [String: PendingTrigger] = [:]
    /// Shield is up iff at least one trigger is active. Pure derived
    /// state, no separate stored flag.
    var isBlocking: Bool { !pendingTriggers.isEmpty }
    private(set) var lastError: String?
    /// Tracks the OS-store side so we only call apply/clear on transitions.
    private var shieldApplied: Bool = false

    private let store = ManagedSettingsStore(named: .vibez)
    private let defaults = UserDefaults.standard
    private let sharedDefaults = UserDefaults(suiteName: "group.vibezlol.Vibez")

    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private enum Key {
        static let selection = "vibez.selection.v1"
        /// Persists `armed`. Name preserved from the manualBlocking era
        /// to keep existing installs' toggle state across this rename.
        static let armed = "vibez.manualBlocking.v1"
        /// v1: `[String]` of sessionIds. Migrated to v2 on first load.
        static let pendingTriggersV1 = "vibez.pendingTriggers.v1"
        /// v2: JSON-encoded `[PendingTrigger]`.
        static let pendingTriggersV2 = "vibez.pendingTriggers.v2"
        /// Legacy single-Bool key kept for one-shot armed migration.
        static let legacyBlocking = "vibez.isBlocking.v1"
    }

    /// Used when migrating v1 entries that don't know their original
    /// duration. Matches the @AppStorage default in ContentView.
    private static let migrationFallbackDuration = 1800

    init() {
        loadSelection()
        loadStateAndMigrate()
        syncAuthState()
        // Force-sync the OS store on launch. If the previous process
        // exited mid-block (crash, force-quit between persisting state
        // and clearShield()), the OS ManagedSettings store can still
        // hold a stale shield even though our in-memory truth says we
        // should be unblocked. Always reconcile.
        pruneExpired()
        let shouldBlock = isBlocking
        shieldLog.info("init: armed=\(self.armed, privacy: .public) pending=\(self.pendingTriggers.count, privacy: .public) → blocking=\(shouldBlock, privacy: .public)")
        if shouldBlock {
            applyShield()
        } else {
            clearShield(reason: "init-sync")
        }
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

    /// The big switch. ON arms Vibez (listens for pings, doesn't shield
    /// yet). OFF clears any active triggers — the user has explicitly
    /// decided to stop, so any in-flight per-session timer is moot.
    func setArmed(_ on: Bool) {
        armed = on
        if !on { pendingTriggers.removeAll() }
        persistArmed()
        persistPendingTriggers()
        recomputeBlocking()
    }

    // MARK: - Per-session pending triggers

    /// Records a new pending trigger for `sessionId`. Snapshotting
    /// `durationSeconds` here means later edits to the user's slider
    /// don't retroactively extend (or shrink) an in-flight block.
    /// No-ops when not armed — pings shouldn't shield apps if the user
    /// has turned Vibez off.
    func addTrigger(sessionId: String, durationSeconds: Int) {
        guard armed else { return }
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

        let shouldBlock = isBlocking  // computed: !pendingTriggers.isEmpty
        if shouldBlock == shieldApplied { return }
        if shouldBlock {
            applyShield()
        } else {
            clearShield(reason: "recompute → no pending triggers")
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

        // Wipe before applying so a previous selection that included
        // categories or web-domains can't bleed through when the new
        // selection only has apps (or vice-versa).
        store.clearAllSettings()
        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)
        store.shield.webDomains = webs.isEmpty ? nil : webs

        // Refresh shared state so the shield extension renders the latest
        // context. ContentView.handleIncoming may overwrite this immediately
        // with a richer per-message snapshot; here we just publish a generic
        // "shields are on" baseline so a freshly-toggled-on Vibez (no ping
        // yet) shows our card instead of the iOS default.
        writeShieldState(ShieldState(
            agent: .none,
            title: nil,
            body: nil,
            expiresAt: nil,
            dark: true
        ))
        shieldApplied = true
        shieldLog.info("applyShield: apps=\(apps.count, privacy: .public) cats=\(cats.count, privacy: .public) webs=\(webs.count, privacy: .public)")
    }

    private func clearShield(reason: String) {
        // clearAllSettings() is the documented "remove everything this
        // store has set" call. Setting properties to nil one-by-one was
        // observed to leave the OS shield visible on some unblock paths.
        store.clearAllSettings()
        writeShieldState(nil)
        shieldApplied = false
        shieldLog.info("clearShield: \(reason, privacy: .public)")
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

    private func persistArmed() {
        defaults.set(armed, forKey: Key.armed)
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

    private func writeShieldState(_ state: ShieldState?) {
        guard let sharedDefaults else {
            shieldLog.error("App Group defaults unavailable — shield state not written")
            return
        }
        if let state {
            sharedDefaults.set(state.asDict, forKey: "shieldState")
        } else {
            sharedDefaults.removeObject(forKey: "shieldState")
        }
    }

    /// Bridges a fresh NtfyMessage into a ShieldState and writes it to
    /// the App Group. Called from ContentView.handleIncoming so the
    /// extension can read the latest agent/title/body next time iOS
    /// asks for a shield configuration.
    func publishShieldContext(from message: NtfyMessage) {
        let agent: ShieldState.Agent
        if let messageAgent = message.agent {
            switch messageAgent {
            case .claude: agent = .claude
            case .codex:  agent = .codex
            }
        } else {
            // Untagged ntfy ping — no agent context. Use the generic
            // "both" tint so we don't bias the visual toward one agent.
            agent = .both
        }

        var expiry: Date?
        if let sid = message.sessionId,
           let trigger = pendingTriggers[sid] {
            expiry = trigger.expiresAt
        }

        writeShieldState(ShieldState(
            agent: agent,
            title: message.displayTitle,
            body: message.body.isEmpty ? nil : message.body,
            expiresAt: expiry,
            dark: true
        ))
    }

    private func loadStateAndMigrate() {
        // Master-toggle migration (unchanged from before, applies to `armed`).
        if defaults.object(forKey: Key.armed) == nil,
           defaults.object(forKey: Key.legacyBlocking) != nil {
            armed = defaults.bool(forKey: Key.legacyBlocking)
            defaults.removeObject(forKey: Key.legacyBlocking)
            persistArmed()
        } else {
            armed = defaults.bool(forKey: Key.armed)
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
