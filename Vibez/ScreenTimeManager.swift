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
    /// Singleton so AppDelegate / NotifyClient can engage the shield at
    /// push-receive time, not view-render time. Critical for the
    /// background case: an iOS push lands while Vibez is suspended,
    /// `NotifyClient.acceptPushUserInfo` runs on the background wake,
    /// and we need the shield up *before* the user opens Vibez — not
    /// after. ContentView defaults to this same instance, so previews
    /// (which inject their own) stay isolated.
    static let shared = ScreenTimeManager()

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
    /// Manual focus hold started by tapping the mascot. ORs with
    /// `isBlocking` to decide the OS shield. Unlike a trigger it has no
    /// timer — it holds until the user taps to release (or disarms).
    private(set) var focusMode: Bool = false
    /// When the current hold began — drives the elapsed-time label.
    /// nil whenever `focusMode` is false.
    private(set) var focusModeStartedAt: Date?
    /// Shield is up iff at least one trigger is active. Pure derived
    /// state, no separate stored flag.
    var isBlocking: Bool { !pendingTriggers.isEmpty }
    /// OS shield is up iff a trigger is pending OR a manual focus hold is
    /// active. `isBlocking` keeps its trigger-only meaning for the overlay
    /// layer; this is the shield decision used by init/recompute/setArmed.
    var shouldShield: Bool { isBlocking || focusMode }
    private(set) var lastError: String?
    /// Tracks the OS-store side so we only call apply/clear on transitions.
    private var shieldApplied: Bool = false

    private let store = ManagedSettingsStore(named: .vibez)
    /// Source of truth for the host app. iOS' `UserDefaults(suiteName:)`
    /// for App Groups intermittently fails reads with
    /// "Using kCFPreferencesAnyUser with a container is only allowed for
    /// System Containers" (a cfprefsd persona-sandbox issue). Writes
    /// land but reads silently return nil — which decoded as an empty
    /// FamilyActivitySelection and broke blocking entirely. Stay on
    /// `.standard` for the host's own state; mirror to App Group below
    /// so VibezPushService can still read what it needs.
    private let defaults = UserDefaults.standard
    // The App Group container is guaranteed present on a provisioned build
    // (the application-groups entitlement is required), so this is
    // effectively never nil. Call sites optional-chain it rather than
    // force-unwrap so a misconfiguration fails safe (no-op) over a crash.
    private let sharedDefaults = UserDefaults(suiteName: "group.vibezlol.Vibez")

    @ObservationIgnored private var tickTask: Task<Void, Never>?

    private enum Key {
        static let selection = "vibez.selection.v1"
        /// Companion to `selection`: PropertyListDecoder always decodes
        /// `includeEntireCategory` as false (the flag isn't preserved by
        /// Codable), so it's persisted separately and re-seeded on load.
        static let selectionIncludeEntireCategory = "vibez.selection.includeEntireCategory.v1"
        /// Persists `armed`. Name preserved from the manualBlocking era
        /// to keep existing installs' toggle state across this rename.
        static let armed = "vibez.manualBlocking.v1"
        /// v1: `[String]` of sessionIds. Migrated to v2 on first load.
        static let pendingTriggersV1 = "vibez.pendingTriggers.v1"
        /// v2: JSON-encoded `[PendingTrigger]`.
        static let pendingTriggersV2 = "vibez.pendingTriggers.v2"
        /// Legacy single-Bool key kept for one-shot armed migration.
        static let legacyBlocking = "vibez.isBlocking.v1"
        /// Manual focus-mode hold (mascot tap). Host-authoritative;
        /// mirrored to the App Group so VibezPushService won't lift the
        /// shield on a backgrounded shield:off while a hold is active.
        static let focusMode = "vibez.focusMode.v1"
        static let focusModeStartedAt = "vibez.focusModeStartedAt.v1"
    }

    /// Used when migrating v1 entries that don't know their original
    /// duration. Matches the @AppStorage default in ContentView.
    private static let migrationFallbackDuration = 1800

    init() {
        Self.recoverFromAppGroupIfNeeded()
        mirrorLiveSettingsToAppGroup()
        prerenderAgentShieldsIfNeeded()
        loadSelection()
        loadStateAndMigrate()
        loadFocusState()
        mirrorAllToAppGroup()
        syncAuthState()
        // Force-sync the OS store on launch. If the previous process
        // exited mid-block (crash, force-quit between persisting state
        // and clearShield()), the OS ManagedSettings store can still
        // hold a stale shield even though our in-memory truth says we
        // should be unblocked. Always reconcile.
        pruneExpired()
        let shouldBlock = shouldShield
        shieldLog.info("init: armed=\(self.armed, privacy: .public) pending=\(self.pendingTriggers.count, privacy: .public) focus=\(self.focusMode, privacy: .public) → blocking=\(shouldBlock, privacy: .public)")
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

    /// Count of the icons the UI actually draws — matches the icon
    /// grids, which hide a category's own icon once the selection is
    /// expanded (its member apps are then in `applicationTokens`).
    var selectedCount: Int {
        selection.applicationTokens.count
            + selection.displayCategoryTokens.count
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

    /// Re-reads the live Family Controls status. Public hook for
    /// onboarding's scenePhase refresh — a grant made in the Settings
    /// app doesn't update `authState` until something re-syncs it.
    func refreshAuthorizationStatus() {
        syncAuthState()
    }

    func updateSelection(_ newSelection: FamilyActivitySelection) {
        selection = newSelection
        persistSelection()
        if shouldShield { applyShield() }
    }

    // MARK: - User-facing toggle

    /// The big switch. ON arms Vibez (listens for pings, doesn't shield
    /// yet). OFF clears any active triggers — the user has explicitly
    /// decided to stop, so any in-flight per-session timer is moot.
    func setArmed(_ on: Bool) {
        armed = on
        if !on {
            pendingTriggers.removeAll()
            focusMode = false
            focusModeStartedAt = nil
        }
        persistArmed()
        persistPendingTriggers()
        persistFocusMode()
        // Force the OS shield to match `shouldShield`. recomputeBlocking
        // would short-circuit when `shieldApplied == shouldBlock`, but
        // VibezPushService (the NSE) engages the shield from its own
        // process without bumping our `shieldApplied` flag — so toggling
        // off while the NSE had silently engaged would leave apps
        // shielded. This bypass guarantees the user's toggle wins.
        if shouldShield {
            applyShield()
        } else {
            clearShield(reason: "setArmed(\(on))")
        }
        shieldApplied = shouldShield
    }

    /// Toggles the manual focus hold. Requires `armed` (the UI only
    /// enables the mascot tap when armed; this guard is defensive).
    /// Reconciles the OS shield via `recomputeBlocking`, which now reads
    /// `shouldShield`. Turning focus off while triggers remain leaves the
    /// shield up for them.
    func setFocusMode(_ on: Bool) {
        guard armed else { return }
        guard on != focusMode else { return }
        focusMode = on
        focusModeStartedAt = on ? Date() : nil
        persistFocusMode()
        recomputeBlocking()
    }

    private func persistFocusMode() {
        defaults.set(focusMode, forKey: Key.focusMode)
        sharedDefaults?.set(focusMode, forKey: Key.focusMode)
        if let startedAt = focusModeStartedAt {
            defaults.set(startedAt.timeIntervalSince1970, forKey: Key.focusModeStartedAt)
            sharedDefaults?.set(startedAt.timeIntervalSince1970, forKey: Key.focusModeStartedAt)
        } else {
            defaults.removeObject(forKey: Key.focusModeStartedAt)
            sharedDefaults?.removeObject(forKey: Key.focusModeStartedAt)
        }
    }

    /// Loads the persisted focus hold on launch. A persisted `focusMode`
    /// with no timestamp is normalized to "started now" so a hold that
    /// survived a kill keeps the shield up rather than being dropped.
    private func loadFocusState() {
        focusMode = defaults.bool(forKey: Key.focusMode)
        if focusMode {
            if let ts = defaults.object(forKey: Key.focusModeStartedAt) as? Double {
                focusModeStartedAt = Date(timeIntervalSince1970: ts)
            } else {
                focusModeStartedAt = Date()
            }
        } else {
            focusModeStartedAt = nil
        }
    }

    // MARK: - Per-session pending triggers

    /// Records a new pending trigger for `sessionId`. Snapshotting
    /// `durationSeconds` here means later edits to the user's slider
    /// don't retroactively extend (or shrink) an in-flight block.
    /// No-ops when not armed — pings shouldn't shield apps if the user
    /// has turned Vibez off.
    func addTrigger(sessionId: String, durationSeconds: Int) {
        guard armed else { return }
        guard sessionId.isUsableSessionId else { return }
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
        guard sessionId.isUsableSessionId else { return }
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
    /// Also pulls in changes the NSE made to `pendingTriggers` while
    /// the host app was suspended (the NSE adds/removes triggers when
    /// pushes arrive in the background), and re-mirrors the live user
    /// settings (block durations + the notify-banner toggle) from
    /// `.standard` so the NSE sees changes the user just made.
    private func tick() {
        let externalChanges = reloadPendingTriggersFromAppGroupIfChanged()
        let pruned = pruneExpired()
        if externalChanges || pruned {
            recomputeBlocking()
        }
        mirrorLiveSettingsToAppGroup()
    }

    /// Public hook so the view layer can pull in App Group updates
    /// right before user-driven actions (dismiss, scene activation),
    /// instead of waiting up to a second for the next tick. Returns
    /// silently — the diff is observed through `pendingTriggers`'s
    /// @Observable updates and via `.onChange(of: pendingTriggers)`.
    func reloadFromAppGroup() {
        _ = reloadPendingTriggersFromAppGroupIfChanged()
    }

    /// Re-reads `pendingTriggers` from the App Group and replaces the
    /// in-memory dictionary if disk diverged. NSE writes there when a
    /// push arrives while the host is suspended; reading App Group
    /// (not `.standard`) is what surfaces those writes. When a change
    /// is detected, also mirrors back to `.standard` so the host's
    /// source of truth stays consistent on the next launch.
    private func reloadPendingTriggersFromAppGroupIfChanged() -> Bool {
        var fresh: [String: PendingTrigger] = [:]
        if let data = sharedDefaults?.data(forKey: Key.pendingTriggersV2),
           let decoded = try? JSONDecoder().decode([PendingTrigger].self, from: data) {
            fresh = Dictionary(uniqueKeysWithValues: decoded.map { ($0.sessionId, $0) })
        }
        if fresh != pendingTriggers {
            pendingTriggers = fresh
            // Keep the standard-defaults source of truth in sync with
            // whatever the NSE wrote, so a host-side persist later
            // doesn't accidentally overwrite the NSE's addition.
            if fresh.isEmpty {
                defaults.removeObject(forKey: Key.pendingTriggersV2)
            } else if let data = try? JSONEncoder().encode(Array(fresh.values)) {
                defaults.set(data, forKey: Key.pendingTriggersV2)
            }
            return true
        }
        return false
    }

    /// Recovers from the brief window where `defaults` pointed at the
    /// App Group and we wrote selection/armed/pendingTriggers there
    /// without keeping `.standard` in sync. If `.standard` lacks a key
    /// but the App Group has it, copy back to standard so the host's
    /// reads succeed. Idempotent — once standard has the key, this
    /// stops touching it.
    private static func recoverFromAppGroupIfNeeded() {
        guard let shared = UserDefaults(suiteName: "group.vibezlol.Vibez") else { return }
        let std = UserDefaults.standard
        let keys = [
            "vibez.selection.v1",
            "vibez.manualBlocking.v1",
            "vibez.pendingTriggers.v2",
            "vibez.pendingTriggers.v1",
            "vibez.isBlocking.v1",
            "vibez.blockSeconds.done",
            "vibez.blockSeconds.needsInput",
            "vibez.focusMode.v1",
            "vibez.focusModeStartedAt.v1",
        ]
        for key in keys {
            guard std.object(forKey: key) == nil,
                  let value = shared.object(forKey: key) else { continue }
            std.set(value, forKey: key)
        }
    }

    /// Push host-authoritative state into the App Group on init so the NSE
    /// can read it. Deliberately EXCLUDES `pendingTriggers`: that's the one
    /// key the NSE also writes — in the background, App Group only — so the
    /// App Group is its source of truth (see `loadStateAndMigrate`). Copying
    /// `.standard`'s possibly-stale trigger set over it here is exactly what
    /// used to clobber the NSE's background resolution and resurrect an
    /// already-finished block on the next cold launch. `selection` and
    /// `armed` are only ever written by the host, so standard → App Group is
    /// the correct direction for them.
    private func mirrorAllToAppGroup() {
        guard let shared = sharedDefaults else { return }
        let std = UserDefaults.standard
        let keys = [
            Key.selection,
            Key.selectionIncludeEntireCategory,
            Key.armed,
            Key.focusMode,
            Key.focusModeStartedAt,
        ]
        for key in keys {
            if let value = std.object(forKey: key) {
                shared.set(value, forKey: key)
            } else {
                shared.removeObject(forKey: key)
            }
        }
    }

    /// One mascot PNG per agent, written to the App Group container.
    /// VibezShield (extension) reads `shield-<agent>.png` and slots it
    /// into `ShieldConfiguration.icon`. Pre-rendering here means the
    /// extension never has to run SwiftUI/ImageRenderer (which can
    /// trap in nonisolated extension contexts) AND VibezPushService
    /// (NSE) doesn't have to render either — both just write the
    /// `shieldState` dict, and the right PNG is already on disk.
    ///
    /// Idempotent: skips agents whose PNG already exists. Bump the
    /// filename suffix (or wipe the App Group container) when the
    /// visual changes.
    private func prerenderAgentShieldsIfNeeded() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return }

        // Legacy single-PNG path from before per-agent renders. Safe
        // to drop — VibezShield no longer looks at it.
        let legacy = container.appendingPathComponent("shield.png")
        try? FileManager.default.removeItem(at: legacy)

        let agents: [ShieldState.Agent] = [.claude, .codex, .both, .none]
        for agent in agents {
            let url = container.appendingPathComponent("shield-\(agent.rawValue).png")
            if FileManager.default.fileExists(atPath: url.path) { continue }
            let state = ShieldState(
                agent: agent,
                title: nil,
                body: nil,
                expiresAt: nil,
                dark: true
            )
            if let png = renderShieldCardPNG(state: state) {
                try? png.write(to: url)
                shieldLog.info("prerendered shield-\(agent.rawValue, privacy: .public).png")
            }
        }
    }

    /// Mirrors the live user settings ContentView/SettingsView write via
    /// @AppStorage — the two block durations and the notification-banner
    /// toggle — from `.standard` into the App Group. The NSE reads from
    /// the App Group, so without this the user could change a setting and
    /// the next background shield would still pick up the old value until
    /// the host app relaunched. Called on init and every tick, so a change
    /// propagates within ~1s while the app is foreground.
    private func mirrorLiveSettingsToAppGroup() {
        guard let shared = sharedDefaults else { return }
        let std = UserDefaults.standard
        for key in ["vibez.blockSeconds.done", "vibez.blockSeconds.needsInput"] {
            guard let value = std.object(forKey: key) as? Int else { continue }
            if shared.object(forKey: key) as? Int != value {
                shared.set(value, forKey: key)
            }
        }
        // Notification-banner toggle (absent → on, matching the @AppStorage
        // default). Only mirror once the user has set it explicitly; until
        // then the key stays absent on both sides and the NSE defaults to
        // showing banners.
        if let notify = std.object(forKey: "vibez.notifyBanners") as? Bool,
           shared.object(forKey: "vibez.notifyBanners") as? Bool != notify {
            shared.set(notify, forKey: "vibez.notifyBanners")
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

        let shouldBlock = shouldShield  // !pendingTriggers.isEmpty || focusMode
        // Always apply/clear — don't short-circuit on `shieldApplied`.
        // VibezPushService (NSE) engages the shield from its own
        // process without bumping our `shieldApplied` flag, so if the
        // NSE engaged + later a shield:off arrives, the host would
        // see shouldBlock=false AND shieldApplied=false and skip
        // calling clearShield. Result: host's ManagedSettings
        // container was never cleared, OS shield stayed on. Both
        // apply and clear are idempotent at the OS level so calling
        // them when state already matches is safe.
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

        // Assign each shield facet directly rather than
        // clearAllSettings()+re-set. The store is OS-wide and shared
        // with VibezPushService (the NSE): the NSE engages the shield
        // from its own process, then this host app — woken into the
        // background by the same push — runs tick(), sees the NSE's
        // App-Group trigger via reloadPendingTriggersFromAppGroupIfChanged(),
        // and calls applyShield again with the *identical* selection.
        // clearAllSettings() momentarily drops the live OS shield before
        // re-applying it, which the user sees as a second shield
        // "flashing in" ~1s after the first while inside a shielded app.
        // Guarding the assignment makes that reconcile a no-op (no
        // flash); we still write nil for any empty facet so a real
        // selection change can't leave stale categories/domains behind.
        let desiredApps = apps.isEmpty ? nil : apps
        let desiredWebs = webs.isEmpty ? nil : webs
        if store.shield.applications != desiredApps {
            store.shield.applications = desiredApps
        }
        if store.shield.webDomains != desiredWebs {
            store.shield.webDomains = desiredWebs
        }
        store.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)

        // Deliberately do NOT write a generic shieldState here. The
        // per-message context (title / body / agent) is owned by
        // `publishShieldContext` — for foreground pushes from
        // ContentView.handleIncoming, and for background pushes from
        // VibezPushService.didReceive. Overwriting with a generic
        // baseline at every applyShield call wipes out the NSE's
        // rich state on the host's next launch, leaving VibezShield
        // with no title/body and falling back to "Stay focused".
        // If no state has ever been written, VibezShield's fallback
        // text is the worst case — same as before this change.
        shieldApplied = true
        AnalyticsTracker.shared.noteShieldArmed()
        shieldLog.info("applyShield: apps=\(apps.count, privacy: .public) cats=\(cats.count, privacy: .public) webs=\(webs.count, privacy: .public)")
    }

    private func clearShield(reason: String) {
        // clearAllSettings() is the documented "remove everything this
        // store has set" call. Setting properties to nil one-by-one was
        // observed to leave the OS shield visible on some unblock paths.
        store.clearAllSettings()
        writeShieldState(nil)
        shieldApplied = false
        AnalyticsTracker.shared.noteShieldLifted()
        shieldLog.info("clearShield: \(reason, privacy: .public)")
    }

    // MARK: - Persistence

    private func persistSelection() {
        do {
            let data = try PropertyListEncoder().encode(selection)
            defaults.set(data, forKey: Key.selection)
            sharedDefaults?.set(data, forKey: Key.selection)
            // The flag doesn't survive the encode (see Key doc) — keep
            // it alongside so loadSelection can restore it.
            defaults.set(selection.includeEntireCategory, forKey: Key.selectionIncludeEntireCategory)
            sharedDefaults?.set(selection.includeEntireCategory, forKey: Key.selectionIncludeEntireCategory)
        } catch {
            lastError = "Failed to save selection: \(error.localizedDescription)"
        }
    }

    private func loadSelection() {
        guard let data = defaults.data(forKey: Key.selection) else { return }
        do {
            var decoded = try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
            // PropertyListDecoder always hands back includeEntireCategory
            // == false; without restoring it, displayCategoryTokens would
            // resurface the category icon next to its already-expanded
            // member apps after every relaunch.
            if defaults.bool(forKey: Key.selectionIncludeEntireCategory) {
                decoded = decoded.expandingCategories
            }
            selection = decoded
        } catch {
            lastError = "Failed to load saved selection: \(error.localizedDescription)"
        }
    }

    private func persistArmed() {
        defaults.set(armed, forKey: Key.armed)
        sharedDefaults?.set(armed, forKey: Key.armed)
    }

    private func persistPendingTriggers() {
        if pendingTriggers.isEmpty {
            defaults.removeObject(forKey: Key.pendingTriggersV2)
            sharedDefaults?.removeObject(forKey: Key.pendingTriggersV2)
            return
        }
        do {
            let data = try JSONEncoder().encode(Array(pendingTriggers.values))
            defaults.set(data, forKey: Key.pendingTriggersV2)
            sharedDefaults?.set(data, forKey: Key.pendingTriggersV2)
        } catch {
            lastError = "Failed to save pending triggers: \(error.localizedDescription)"
        }
    }

    private var sharedShieldImageURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez")?
            .appendingPathComponent("shield.png")
    }

    private func writeShieldState(_ state: ShieldState?) {
        // Write as a JSON file in the App Group container, NOT into
        // App Group UserDefaults. iOS 26's cfprefsd persona-sandbox
        // bug causes writes from the NSE to land in an in-memory cache
        // that VibezShield (a different process) never sees — so the
        // shield card would fall back to "Stay focused" for any
        // background-engaged shield. File writes propagate across
        // processes through the filesystem, not cfprefsd, so this
        // path is reliable in both directions.
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else {
            shieldLog.error("App Group container unavailable — shield state not written")
            return
        }
        let url = containerURL.appendingPathComponent("shield-state.json")
        if let state,
           let data = try? JSONSerialization.data(withJSONObject: state.asDict) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        // Also clear any legacy UserDefaults entry so VibezShield
        // doesn't read stale state if a previous build left one behind.
        sharedDefaults?.removeObject(forKey: "shieldState")
    }

    /// Engages (or lifts) the shield based on a fresh push. Mirrors the
    /// shield/trigger logic that used to live in ContentView.handleIncoming
    /// but called from NotifyClient.acceptPushUserInfo so it runs at
    /// push-receive time regardless of whether the view is observing.
    /// Idempotent on sessionId, so foreground (where handleIncoming
    /// also calls addTrigger via its own path) doesn't double-engage —
    /// addTrigger just overwrites the same entry with a fresh timer.
    ///
    /// View-only effects (overlay enqueue, Recent triggers row,
    /// analytics) still happen in ContentView.handleIncoming when the
    /// view observes lastMessage — those are allowed to be late.
    func applyTriggerFor(message: NtfyMessage) {
        let shieldStr = message.shield.map { $0.rawValue } ?? "nil"
        let sidStr = message.sessionId ?? "nil"
        shieldLog.info("applyTriggerFor: shield=\(shieldStr, privacy: .public) armed=\(self.armed, privacy: .public) session=\(sidStr, privacy: .public) selection=\(self.selection.applicationTokens.count, privacy: .public) apps")

        if message.shield == .off,
           let sid = message.sessionId, sid.isUsableSessionId {
            // Sync from App Group first — the NSE may have added this
            // session's trigger in the background and host's in-memory
            // dict hasn't picked it up yet (tick is 1Hz). Without this,
            // resolveTrigger's `removeValue(forKey:) != nil` guard
            // short-circuits because the in-memory dict is empty, and
            // recomputeBlocking → clearShield never runs. Apps stay
            // blocked.
            _ = reloadPendingTriggersFromAppGroupIfChanged()
            shieldLog.info("applyTriggerFor: shield=off → resolveTrigger(\(sid, privacy: .public))")
            resolveTrigger(sessionId: sid)
            return
        }
        // shield:on or untagged → engage if armed and not ignored.
        guard armed else {
            shieldLog.info("applyTriggerFor: disarmed → no-op")
            return
        }
        if let sid = message.sessionId, sid.isUsableSessionId {
            if IgnoreStore.shared.contains(sessionId: sid, name: message.title) {
                shieldLog.info("applyTriggerFor: ignored session \(sid, privacy: .public)")
                IgnoreStore.shared.refreshName(sessionId: sid, name: message.title)
                return
            }
            let duration = durationFor(message)
            shieldLog.info("applyTriggerFor: addTrigger(\(sid, privacy: .public), \(duration, privacy: .public)s)")
            addTrigger(sessionId: sid, durationSeconds: duration)
        } else {
            shieldLog.info("applyTriggerFor: no usable session id — skipping addTrigger")
        }
        publishShieldContext(from: message)
    }

    /// Picks the per-trigger duration the way ContentView.durationFor
    /// does, but reading UserDefaults directly so this method works
    /// without a SwiftUI environment. `done` → short timer (nudge to
    /// glance); anything else → long timer (keep shield up while
    /// agent waits). Defaults match ContentView's `@AppStorage`.
    private func durationFor(_ message: NtfyMessage) -> Int {
        let key: String
        let fallback: Int
        switch message.event {
        case .done:
            key = "vibez.blockSeconds.done"
            fallback = 30
        case .needsInput, .replied, .none:
            key = "vibez.blockSeconds.needsInput"
            fallback = 900
        }
        return defaults.object(forKey: key) as? Int ?? fallback
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

        // ShieldConfiguration.Label.text is plain text — iOS does not
        // render markdown there. Strip the inline markers (**bold**,
        // *italic*, `code`, etc.) so they don't show literally on the
        // shield. Matches what NotifyClient does for push notifications.
        let cleanTitle = NotifyClient.stripMarkdown(message.displayTitle)
        let cleanBody = message.body.isEmpty
            ? nil
            : NotifyClient.stripMarkdown(message.body)

        writeShieldState(ShieldState(
            agent: agent,
            title: cleanTitle,
            body: cleanBody,
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

        // pendingTriggers is the ONLY state the NSE also writes — in the
        // background, App Group only, while the host is suspended. So the
        // App Group, not `.standard`, is its single source of truth, and
        // cold launch loads it the same way warm resume does (see
        // reloadPendingTriggersFromAppGroupIfChanged). Reading `.standard`
        // here is what used to resurrect a block the NSE had already lifted:
        // `.standard` lagged behind the NSE's App Group write, init trusted
        // the lagging copy, and mirrorAllToAppGroup then clobbered the App
        // Group with it. Absent == nothing pending, exactly as the App Group
        // encodes "empty."
        if let data = sharedDefaults?.data(forKey: Key.pendingTriggersV2),
           let decoded = try? JSONDecoder().decode([PendingTrigger].self, from: data) {
            pendingTriggers = Dictionary(
                uniqueKeysWithValues: decoded.map { ($0.sessionId, $0) }
            )
            // Keep `.standard` coherent with the authoritative App Group copy.
            defaults.set(data, forKey: Key.pendingTriggersV2)
            return
        }

        // No v2 in the App Group → one-shot v1 → v2 migration for installs
        // upgrading from the pre-v2 format (v1 only ever lived in `.standard`).
        // We didn't record durations under v1, so assume "added now" with the
        // default duration. persistPendingTriggers seeds BOTH stores so the
        // App Group becomes populated as the new source of truth.
        if let arr = defaults.array(forKey: Key.pendingTriggersV1) as? [String] {
            let now = Date()
            pendingTriggers = Dictionary(uniqueKeysWithValues: arr.compactMap { sid in
                guard sid.isUsableSessionId else { return nil }
                return (sid, PendingTrigger(
                    sessionId: sid,
                    addedAt: now,
                    durationSeconds: Self.migrationFallbackDuration
                ))
            })
            defaults.removeObject(forKey: Key.pendingTriggersV1)
            persistPendingTriggers()
            return
        }

        // Nothing pending in either store. Drop any stale `.standard` copy so
        // the two stores don't silently disagree on the next read.
        pendingTriggers = [:]
        defaults.removeObject(forKey: Key.pendingTriggersV2)
    }
}

private extension ManagedSettingsStore.Name {
    static let vibez = ManagedSettingsStore.Name("vibez.shield")
}

// MARK: - Category-expanded display

extension FamilyActivitySelection {
    /// Copy of this selection re-created with `includeEntireCategory`,
    /// so the next picker session expands a category pick into its
    /// member apps' tokens — that's what lets the UI show real app
    /// icons instead of one opaque category icon. The flag is fixed at
    /// init and NOT preserved by Codable (PropertyListDecoder always
    /// yields false) — persistSelection stores it under a companion
    /// key and loadSelection re-seeds it through this same copy.
    var expandingCategories: FamilyActivitySelection {
        guard !includeEntireCategory else { return self }
        var expanded = FamilyActivitySelection(includeEntireCategory: true)
        expanded.applicationTokens = applicationTokens
        expanded.categoryTokens = categoryTokens
        expanded.webDomainTokens = webDomainTokens
        return expanded
    }

    /// Category tokens the UI should render as icons. An expanded
    /// selection already carries every member app in
    /// `applicationTokens`, so drawing the category icon too would
    /// show duplicates; a legacy (unexpanded) selection still needs
    /// it — the category icon is all it has.
    var displayCategoryTokens: [ActivityCategoryToken] {
        includeEntireCategory ? [] : Array(categoryTokens)
    }
}

#if DEBUG
extension ScreenTimeManager {
    /// Yields a ScreenTimeManager pre-seeded for SwiftUI previews. The
    /// real `init` still runs (its ManagedSettings calls are no-ops in
    /// the simulator per CLAUDE.md), then we overwrite the bits the UI
    /// reads so the home screen renders an armed/blocked state without
    /// going through Family Controls.
    static func previewManager(
        armed: Bool,
        pendingTriggers: [PendingTrigger] = [],
        authState: AuthState = .authorized,
        focusMode: Bool = false
    ) -> ScreenTimeManager {
        let m = ScreenTimeManager()
        m.armed = armed
        m.pendingTriggers = Dictionary(
            uniqueKeysWithValues: pendingTriggers.map { ($0.sessionId, $0) }
        )
        m.authState = authState
        m.focusMode = focusMode
        m.focusModeStartedAt = focusMode ? Date().addingTimeInterval(-(12 * 60 + 34)) : nil
        return m
    }
}
#endif
