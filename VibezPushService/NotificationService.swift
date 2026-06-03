//
//  NotificationService.swift
//  VibezPushService
//
//  Notification Service Extension. Runs in its own process on every push
//  the server marks `mutable-content: 1`, *before* iOS displays the
//  banner. The host app's AppDelegate.didReceiveRemoteNotification is
//  unreliable on iOS 26 — it isn't called when the app is suspended,
//  even with content-available: 1 — so the only place we can engage
//  the shield while Vibez is backgrounded is here.
//
//  Reads selection/armed/pendingTriggers/blockSeconds from the
//  `group.vibezlol.Vibez` App Group (ScreenTimeManager mirrors them
//  there), writes the shield via `ManagedSettingsStore(named: "vibez.shield")`
//  (the same store the host app uses, OS-wide persistent), and stores a
//  ShieldState dict at `shieldState` for VibezShield to render.
//

import UserNotifications
import ManagedSettings
import FamilyControls
import Foundation
import OSLog

/// Mirror of `Vibez/ScreenTimeManager.swift`'s `PendingTrigger`. Keep the
/// Codable shape in sync — both targets read/write the same App Group
/// data under `vibez.pendingTriggers.v2`.
struct PendingTrigger: Codable, Equatable {
    let sessionId: String
    let addedAt: Date
    let durationSeconds: Int

    /// When this trigger's timer is up. Mirrors the host's computed
    /// property so the NSE can decide whether a timeout unblock is due.
    var expiresAt: Date {
        addedAt.addingTimeInterval(TimeInterval(durationSeconds))
    }
}

private extension ManagedSettingsStore.Name {
    /// Same store name the host app uses. Writes from this extension are
    /// visible to the host app on next activation and vice versa.
    static let vibez = ManagedSettingsStore.Name("vibez.shield")
}

final class NotificationService: UNNotificationServiceExtension {

    private let log = Logger(subsystem: "vibezlol.Vibez", category: "PushService")
    private let store = ManagedSettingsStore(named: .vibez)
    // The App Group container is guaranteed present on a provisioned build
    // (the application-groups entitlement is required), so this is
    // effectively never nil. Call sites guard/optional-chain it rather than
    // force-unwrap so a misconfiguration fails safe (no-op) over a crash.
    private let sharedDefaults = UserDefaults(suiteName: "group.vibezlol.Vibez")

    private enum Key {
        static let selection = "vibez.selection.v1"
        static let armed = "vibez.manualBlocking.v1"
        static let pendingTriggers = "vibez.pendingTriggers.v2"
        static let blockSecondsDone = "vibez.blockSeconds.done"
        static let blockSecondsNeedsInput = "vibez.blockSeconds.needsInput"
        static let notifyBanners = "vibez.notifyBanners"
        static let shieldState = "shieldState"
        static let focusMode = "vibez.focusMode.v1"
    }

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    /// The host's "Show notifications" switch, mirrored into the App Group
    /// by ScreenTimeManager (key `vibez.notifyBanners`, default on). Single
    /// source of truth for the off-state: when off, the NSE delivers every
    /// push passively AND keeps Notification Center swept clear of Vibez
    /// entries.
    private var notificationsOff: Bool {
        !(sharedDefaults?.object(forKey: Key.notifyBanners) as? Bool ?? true)
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        let userInfo = request.content.userInfo
        let shield = (userInfo["shield"] as? String) ?? ""
        let session = (userInfo["session"] as? String) ?? ""
        let event = (userInfo["event"] as? String) ?? ""
        let agent = (userInfo["agent"] as? String) ?? ""
        let title = (userInfo["title"] as? String) ?? ""
        let body = (userInfo["body"] as? String) ?? ""
        let reason = (userInfo["reason"] as? String) ?? ""

        log.info("didReceive: shield=\(shield, privacy: .public) session=\(session, privacy: .public) event=\(event, privacy: .public) agent=\(agent, privacy: .public)")

        applyShieldState(
            shield: shield,
            session: session,
            event: event,
            agent: agent,
            title: title,
            body: body,
            reason: reason
        )

        // Stash the original push payload so the host can replay the
        // overlay / Recent triggers row / analytics when the user
        // re-opens Vibez. Without this the in-app overlay never
        // appears for background-engaged blocks — handleIncoming is
        // driven by NotifyClient.lastMessage, which the NSE (a
        // separate process) can't set directly. Carry the system's
        // request identifier so the host can dedupe replay against
        // pushes it already processed via willPresent — without a
        // stable id, every drain re-enqueues the overlay.
        // A timeout unblock is a backup mechanism, not a ping — never
        // replay it as an in-app overlay / Recent-triggers row.
        if reason != "timeout" {
            writeLastMessageToAppGroup(
                userInfo: userInfo, identifier: request.identifier)
        }

        // Keep Notification Center tidy. Issued here, before contentHandler
        // below, because the extension can be suspended the instant that
        // fires. Widest case first:
        //   • notifications off → pull EVERY Vibez entry on every push, so
        //     nothing piles up while the user has banners disabled.
        //   • a reply (shield:off) → pull just that replied session's now-
        //     stale "Needs you" / "Done" banner, leaving other sessions'.
        // Either way the current push isn't in the delivered list yet, so it
        // still files in passively; the next push (or the host's
        // on-activation sweep) clears the remainder.
        if notificationsOff {
            clearDeliveredNotifications(forSession: nil)
        } else if shield == "off", reason != "timeout",
                  !session.isEmpty, session != "nosid" {
            clearDeliveredNotifications(forSession: session)
        }

        // Pass the notification through with markdown stripped + the
        // event-label prefix iOS can't render natively. Matches what
        // the host app's NotifyClient.scheduleLocalNotification does so
        // banners look the same regardless of which path delivered it.
        if let best = bestAttemptContent {
            best.title = Self.stripMarkdown(Self.displayTitle(title: title, event: event))
            best.body = Self.stripMarkdown(body.isEmpty ? "Vibez ping" : body)
            // Notifications off → deliver this push silently: a passive
            // interruption level files it into Notification Center with no
            // banner, no sound, no screen wake, and we drop the sound the
            // server attached to a shield:on push. The shield work already
            // ran, so apps stay blocked — only the interruption is
            // suppressed, and the sweep above keeps the backlog clear.
            // shield:off is already passive server-side, so this is a no-op
            // for it.
            if notificationsOff {
                best.interruptionLevel = .passive
                best.sound = nil
            }
            contentHandler(best)
        } else {
            contentHandler(request.content)
        }
    }

    /// Writes the push payload to `last-message.json` in the App Group
    /// container. The host reads + deletes this on scene activation
    /// (NotifyClient.drainPendingPushFromAppGroup) to drive the
    /// in-app overlay for background-engaged shields. Snapshots only
    /// the top-level Vibez fields (skips the nested `aps` dict and
    /// non-string values that wouldn't round-trip through JSON).
    private func writeLastMessageToAppGroup(userInfo: [AnyHashable: Any], identifier: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return }

        var dict: [String: Any] = [:]
        for key in ["title", "body", "event", "shield", "session", "agent"] {
            if let value = userInfo[key] as? String {
                dict[key] = value
            }
        }
        // `identifier` is the same value willPresent receives via
        // notification.request.identifier, so the host's processIfNew
        // dedup sees the same id whether the push lands via the
        // foreground willPresent path or via this file drain.
        dict["id"] = identifier
        dict["_writtenAt"] = Date().timeIntervalSince1970

        let url = containerURL.appendingPathComponent("last-message.json")
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: url, options: .atomic)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS is about to terminate us. Hand back whatever we have.
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Shield state

    private func applyShieldState(
        shield: String,
        session: String,
        event: String,
        agent: String,
        title: String,
        body: String,
        reason: String
    ) {
        guard sharedDefaults != nil else {
            log.error("App Group defaults unavailable — check the application-groups entitlement")
            return
        }

        if shield == "off" {
            handleShieldOff(session: session, reason: reason)
        } else {
            handleShieldOn(session: session, event: event, agent: agent, title: title, body: body)
        }
    }

    /// shield:off — the user just replied in the agent. Remove the
    /// matching pending trigger and, if nothing else is open, drop the OS
    /// shield. Runs regardless of `armed` (resolving stale state when the
    /// toggle is off is harmless).
    private func handleShieldOff(session: String, reason: String) {
        guard !session.isEmpty, session != "nosid" else { return }
        var triggers = loadPendingTriggers()
        if reason == "timeout" {
            // Backup unblock: drop ONLY if this session's timer is
            // actually due. Not due (the timer was reset by a later
            // ping) or already gone → no-op, so a stale/duplicate
            // dispatch can never unblock early. Design spec §3.
            guard let t = triggers.first(
                      where: {$0.sessionId == session}),
                  Date() >= t.expiresAt else {
                log.info("shield=off timeout \(session, privacy: .public): not due / gone — no-op")
                return
            }
        }
        let before = triggers.count
        triggers.removeAll { $0.sessionId == session }
        savePendingTriggers(triggers)
        // A manual focus hold (mascot tap) keeps the shield up even
        // when no per-session triggers remain — don't lift a hand-set
        // hold that a backgrounded reply/timeout would otherwise drop.
        let focusMode = sharedDefaults?.bool(forKey: Key.focusMode) ?? false
        if triggers.isEmpty && !focusMode {
            clearShield()
        }
        log.info("shield=off: \(session, privacy: .public) (\(before, privacy: .public)→\(triggers.count, privacy: .public)) focus=\(focusMode, privacy: .public) reason=\(reason, privacy: .public)")
    }

    /// shield:on or untagged — engage the shield if Vibez is armed,
    /// adding (or refreshing) the per-session pending trigger.
    private func handleShieldOn(
        session: String,
        event: String,
        agent: String,
        title: String,
        body: String
    ) {
        let armed = sharedDefaults?.bool(forKey: Key.armed) ?? false
        guard armed else {
            log.info("disarmed — no-op")
            return
        }

        guard !session.isEmpty, session != "nosid" else {
            // Untagged ping — still refresh the shield context so the
            // extension's card has the latest title/body, but there's
            // no per-session trigger to add.
            publishShieldContext(agent: agent, title: title, body: body, event: event, expiresAt: nil)
            return
        }

        // Add (or refresh) the pending trigger keyed by sessionId. Same
        // semantics as ScreenTimeManager.addTrigger: a second ping for
        // the same session resets the timer.
        let durationSeconds = durationFor(event: event)
        var triggers = loadPendingTriggers()
        triggers.removeAll { $0.sessionId == session }
        triggers.append(
            PendingTrigger(
                sessionId: session,
                addedAt: Date(),
                durationSeconds: durationSeconds
            )
        )
        savePendingTriggers(triggers)

        // Write the shield card's title/body BEFORE engaging the OS
        // shield. When the user is already inside the blocked app,
        // setting store.shield.applications makes iOS re-render the
        // shield immediately and query VibezShield — which reads
        // shield-state.json. If we engaged first, that read would race
        // ahead of this write and pick up the PREVIOUS push's message
        // (the "second block shows the first block's text" bug). Writing
        // the file first guarantees the freshest message is on disk
        // before iOS asks for it.
        let expiresAt = Date().addingTimeInterval(TimeInterval(durationSeconds))
        publishShieldContext(agent: agent, title: title, body: body, event: event, expiresAt: expiresAt)

        applyShield()

        log.info("shield=on: added \(session, privacy: .public), pending=\(triggers.count, privacy: .public), duration=\(durationSeconds, privacy: .public)s")
    }

    private func applyShield() {
        guard let data = sharedDefaults?.data(forKey: Key.selection),
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
        else {
            log.warning("applyShield: no selection in App Group — host app hasn't picked apps yet")
            return
        }
        let apps = selection.applicationTokens
        let cats = selection.categoryTokens
        let webs = selection.webDomainTokens

        // Assign each facet directly instead of clearAllSettings()+set.
        // The shield store is shared with the host app; a destructive
        // clear here (or on a repeat push for an already-shielded app)
        // momentarily drops the live OS shield, which reads as a flash
        // when the user is inside a shielded app. Guarding the
        // assignment keeps a re-apply of the same selection a no-op,
        // while still writing nil for empty facets so stale
        // categories/domains can't bleed through on a real change.
        let desiredApps = apps.isEmpty ? nil : apps
        let desiredWebs = webs.isEmpty ? nil : webs
        if store.shield.applications != desiredApps {
            store.shield.applications = desiredApps
        }
        if store.shield.webDomains != desiredWebs {
            store.shield.webDomains = desiredWebs
        }
        store.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)

        log.info("applyShield: apps=\(apps.count, privacy: .public) cats=\(cats.count, privacy: .public) webs=\(webs.count, privacy: .public)")
    }

    private func clearShield() {
        store.clearAllSettings()
        // Delete the file VibezShield actually reads (shield-state.json),
        // mirroring the host's writeShieldState(nil). Removing only the
        // legacy `shieldState` UserDefaults key (below) left the file on
        // disk, so the NEXT background block — engaged while the user was
        // still inside the app — rendered this block's stale title/body.
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) {
            try? FileManager.default.removeItem(
                at: containerURL.appendingPathComponent("shield-state.json")
            )
        }
        sharedDefaults?.removeObject(forKey: Key.shieldState)
        log.info("clearShield")
    }

    /// Pull delivered notifications out of Notification Center. Pass `nil`
    /// to clear every Vibez entry (notifications switched off); pass a
    /// session id to clear only that conversation's banner(s) (a reply made
    /// them stale). For the scoped case we match on the payload's own
    /// `session` field — present on every push the server sends, and
    /// mirrored onto locally-scheduled banners by
    /// NotifyClient.scheduleLocalNotification — so it works regardless of
    /// how the banner was raised, rather than relying on the system id.
    ///
    /// Runs synchronously: the removal must be *issued* before didReceive
    /// hands control back to iOS via contentHandler, because the extension
    /// can be suspended the moment that fires. getDeliveredNotifications'
    /// completion is invoked on a private UN queue (never the caller's
    /// thread), so the wait can't deadlock; the timeout is a belt-and-
    /// suspenders bound well inside our ~30s budget — if the local query
    /// somehow stalls we skip removal that once rather than hang to death.
    private func clearDeliveredNotifications(forSession session: String?) {
        let center = UNUserNotificationCenter.current()
        // Clearing everything needs no enumerate round-trip.
        guard let session else {
            center.removeAllDeliveredNotifications()
            log.info("cleared all delivered banners (notifications off)")
            return
        }
        let sem = DispatchSemaphore(value: 0)
        var ids: [String] = []
        center.getDeliveredNotifications { delivered in
            ids = delivered
                .filter { ($0.request.content.userInfo["session"] as? String) == session }
                .map { $0.request.identifier }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 5) == .success else {
            log.warning("clearDeliveredNotifications: query timed out for \(session, privacy: .public)")
            return
        }
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        log.info("cleared \(ids.count, privacy: .public) delivered banner(s) for \(session, privacy: .public)")
    }

    private func publishShieldContext(
        agent: String,
        title: String,
        body: String,
        event: String,
        expiresAt: Date?
    ) {
        // Write as a JSON file in the App Group container — matches
        // the host (see ScreenTimeManager.writeShieldState). NSE writes
        // to App Group UserDefaults get stranded in an in-memory cache
        // on iOS 26 (cfprefsd persona-sandbox bug) and VibezShield
        // never sees them, which is why background-engaged shields
        // were showing the "Stay focused" fallback. File-based writes
        // propagate to other processes via the filesystem.
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return }

        let agentEnum: String
        switch agent {
        case "cc": agentEnum = "claude"
        case "cx": agentEnum = "codex"
        default:   agentEnum = "both"
        }
        var dict: [String: Any] = [
            "agent": agentEnum,
            "dark": true,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        // Use the same prefixed displayTitle the host writes — matches
        // the foreground card so users see "Done — title" / "Needs you
        // — title" regardless of which path engaged the shield.
        let cleanTitle = Self.stripMarkdown(Self.displayTitle(title: title, event: event))
        if !cleanTitle.isEmpty { dict["title"] = cleanTitle }
        if !body.isEmpty { dict["body"] = Self.stripMarkdown(body) }
        if let expiresAt {
            dict["expiresAt"] = expiresAt.timeIntervalSince1970
        }

        let url = containerURL.appendingPathComponent("shield-state.json")
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - App Group persistence

    private func loadPendingTriggers() -> [PendingTrigger] {
        guard let data = sharedDefaults?.data(forKey: Key.pendingTriggers),
              let decoded = try? JSONDecoder().decode([PendingTrigger].self, from: data)
        else { return [] }
        return decoded
    }

    private func savePendingTriggers(_ triggers: [PendingTrigger]) {
        guard let sharedDefaults else { return }
        if triggers.isEmpty {
            sharedDefaults.removeObject(forKey: Key.pendingTriggers)
            return
        }
        if let data = try? JSONEncoder().encode(triggers) {
            sharedDefaults.set(data, forKey: Key.pendingTriggers)
        }
    }

    private func durationFor(event: String) -> Int {
        switch event {
        case "done":
            return sharedDefaults?.object(forKey: Key.blockSecondsDone) as? Int ?? 30
        default:
            return sharedDefaults?.object(forKey: Key.blockSecondsNeedsInput) as? Int ?? 900
        }
    }

    // MARK: - Display helpers (duplicated from NotifyClient)

    private static func displayTitle(title: String, event: String) -> String {
        let prefix: String?
        switch event {
        case "done":        prefix = "Done"
        case "needs-input": prefix = "Needs you"
        case "replied":     prefix = "Replied"
        default:            prefix = nil
        }
        guard let prefix else {
            return title.isEmpty ? "Vibez" : title
        }
        if title.isEmpty { return prefix }
        return "\(prefix) — \(title)"
    }

    private static func stripMarkdown(_ s: String) -> String {
        var out = s
        let subs: [(String, String)] = [
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"\*\*(.+?)\*\*"#, "$1"),
            (#"__(.+?)__"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
            (#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, "$1"),
        ]
        for (pat, repl) in subs {
            out = out.replacingOccurrences(of: pat, with: repl, options: .regularExpression)
        }
        out = out.replacingOccurrences(of: "`", with: "")
        return out
    }
}
