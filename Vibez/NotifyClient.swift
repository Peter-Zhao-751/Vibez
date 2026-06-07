//
//  NotifyClient.swift
//  Vibez
//
//  The push-message inbox. Vibez used to subscribe to ntfy.sh over a
//  WebSocket; that's been ripped out in favor of an FCM-only path —
//  the Mac plugin POSTs to a Firebase Cloud Function, the function
//  fans out via FCM, AppDelegate delivers the push into
//  `acceptPushUserInfo`, and this class publishes `lastMessage` to
//  whoever is observing (ContentView's `.onChange(of: lastMessage)`).
//
//  The class still carries the `Notify` name because every other file
//  in the project still references `NotifyClient.shared` /
//  `NtfyMessage`; renaming would churn far more files than the migration
//  warrants. The semantics are pure push now.
//

import Foundation
import Intents
import OSLog
import UserNotifications

/// What lifecycle moment the push represents.
/// Carried verbatim in the FCM payload's `event` field.
enum VibezEvent: String, Equatable {
    case done           // Stop hook, last turn was not a question
    case needsInput     = "needs-input"  // Notification, or Stop where the agent asked
    case replied        // UserPromptSubmit

    /// Short human label used as a prefix on overlay + notification
    /// titles, e.g. "Done — <conversation title>".
    var label: String {
        switch self {
        case .done:       return "Done"
        case .needsInput: return "Needs you"
        case .replied:    return "Replied"
        }
    }
}

/// Whether the iPhone should be shielded right now.
enum VibezShield: String, Equatable {
    case on
    case off
}

/// Which agent produced this push.
/// "cc" → Claude Code plugin, "cx" → Codex plugin.
enum VibezAgent: String, Equatable {
    case claude = "cc"
    case codex  = "cx"
}

struct NtfyMessage: Equatable {
    let id: String
    let title: String
    let body: String
    let receivedAt: Date
    /// Lifecycle moment from the FCM payload's `event` field. nil for
    /// pushes that arrive without a Vibez control tag (e.g. a generic
    /// test push from a third party).
    var event: VibezEvent? = nil
    /// Block intent from the FCM payload's `shield` field.
    var shield: VibezShield? = nil
    /// CLI session_id from the FCM payload's `session` field.
    var sessionId: String? = nil
    /// Producing agent from the FCM payload's `agent` field
    /// ("cc" → Claude Code, "cx" → Codex). nil only for untagged
    /// third-party producers (e.g. a raw curl test ping).
    var agent: VibezAgent? = nil
    /// True when this message was reconstituted from a file the NSE
    /// wrote while the host was suspended. The NSE has already done
    /// the model-level work (engaged the shield, persisted the
    /// trigger, written shield-state.json) and iOS has already shown
    /// its banner — so handleIncoming should only do the view-level
    /// work (Recent triggers row, analytics, in-app overlay) and skip
    /// re-engaging the shield (would reset the per-session timer) and
    /// scheduling a local notification (would double-banner the user).
    var wasBackgroundEngaged: Bool = false

    /// True while the agent is parked on a user reply. Derived from
    /// `event` rather than stored separately — `needs-input` is the
    /// only state that means "waiting on the user".
    var needsReply: Bool { event == .needsInput }

    /// Title with the event prefix applied: "Done — Plan plugin distribution".
    /// Used for local notifications and the blocked overlay so the
    /// user can see at a glance what the agent is asking for. Falls
    /// back to the raw title when no event tag is present.
    var displayTitle: String {
        guard let prefix = event?.label else {
            return title.isEmpty ? "Vibez" : title
        }
        if title.isEmpty { return prefix }
        return "\(prefix) — \(title)"
    }
}

@MainActor
@Observable
final class NotifyClient {

    /// Shared instance so AppDelegate can deliver remote-push payloads
    /// into the same lastMessage → handleIncoming pipeline that
    /// ContentView observes. Previews still create isolated instances
    /// via `NotifyClient()`.
    static let shared = NotifyClient()

    private(set) var lastMessage: NtfyMessage?

    private let log = Logger(subsystem: "vibezlol.Vibez", category: "NotifyClient")

    // MARK: - Push entry points

    /// Build an NtfyMessage from an APN remote-push userInfo dict and
    /// deliver it. Called from AppDelegate when iOS wakes the app for
    /// a push.
    ///
    /// Payload shape (sent by the Firebase /notify function — see
    /// Backend/functions/src/index.ts):
    /// ```json
    /// {
    ///   "aps": { "alert": { "title": "...", "body": "..." },
    ///            "sound": "default" },
    ///   "event":   "needs-input" | "done" | "replied",
    ///   "shield":  "on" | "off",
    ///   "session": "<session-id>",
    ///   "agent":   "cc" | "cx"
    /// }
    /// ```
    /// title/body live only in aps.alert; the NSE's App Group drain
    /// file uses flat top-level title/body keys instead (no aps), and
    /// this parser accepts both shapes.
    func acceptPushUserInfo(
        _ userInfo: [AnyHashable: Any],
        wasBackgroundEngaged: Bool = false
    ) {
        // Timeout unblocks are the server's backup layer. The NSE applies
        // them (if due), and while we're awake the 1 Hz prune owns expiry.
        // The host must NOT act here — resolving unconditionally would
        // drop a session that may have been re-pinged. (Design spec §3.)
        if (userInfo["reason"] as? String) == "timeout" {
            log.info("acceptPushUserInfo: ignoring reason=timeout (NSE + prune own it)")
            return
        }
        // Live pushes carry title/body ONLY inside aps.alert (the
        // backend stopped duplicating them at the top level). The flat
        // fallback is permanent, not transitional: the NSE's
        // last-message.json drain replays through this same parser
        // with flat keys (and pre-dedup pushes parse the same way).
        let alert = ((userInfo["aps"] as? [String: Any])?["alert"])
            as? [String: Any]
        var msg = NtfyMessage(
            id: (userInfo["id"] as? String) ?? UUID().uuidString,
            title: (alert?["title"] as? String)
                ?? (userInfo["title"] as? String) ?? "Vibez",
            body: (alert?["body"] as? String)
                ?? (userInfo["body"] as? String) ?? "",
            receivedAt: Date()
        )
        if let event   = userInfo["event"]   as? String { msg.event     = VibezEvent(rawValue: event) }
        if let shield  = userInfo["shield"]  as? String { msg.shield    = VibezShield(rawValue: shield) }
        if let session = userInfo["session"] as? String { msg.sessionId = session }
        if let agent   = userInfo["agent"]   as? String { msg.agent     = VibezAgent(rawValue: agent) }
        msg.wasBackgroundEngaged = wasBackgroundEngaged
        // [debug] One log line per push so we can confirm parsing.
        // Enum-with-raw-value fields (event/shield/agent) decode to
        // nil when the wire string doesn't match a known case — that
        // shows up as "nil" here, indicating a server-side mismatch.
        let eventStr = msg.event.map { $0.rawValue } ?? "nil"
        let shieldStr = msg.shield.map { $0.rawValue } ?? "nil"
        let agentStr = msg.agent.map { $0.rawValue } ?? "nil"
        let sessionStr = msg.sessionId ?? "nil"
        log.info(
            "Parsed push: title=\(msg.title, privacy: .public) event=\(eventStr, privacy: .public) shield=\(shieldStr, privacy: .public) session=\(sessionStr, privacy: .public) agent=\(agentStr, privacy: .public) drain=\(wasBackgroundEngaged, privacy: .public)"
        )

        // Engage the shield here, NOT in ContentView.handleIncoming.
        // When the app is in background, the view isn't observing
        // lastMessage, so the shield-engagement path through .onChange
        // doesn't fire until the user opens Vibez — by which point
        // they've already had a free pass to scroll Instagram.
        // ScreenTimeManager.applyTriggerFor is idempotent on sessionId,
        // so foreground (where ContentView.handleIncoming also calls
        // addTrigger) is harmless double-fire. Skip when draining the
        // NSE-written file — the NSE already did all of this and
        // re-running addTrigger would reset the per-session timer.
        if !wasBackgroundEngaged {
            ScreenTimeManager.shared.applyTriggerFor(message: msg)
        }

        lastMessage = msg
    }

    /// Reads `last-message.json` (written by VibezPushService when it
    /// handled a push in the background) and feeds it through
    /// `acceptPushUserInfo` so the in-app overlay + Recent triggers
    /// row + analytics catch up to what already happened in the
    /// background. Tags the message as `wasBackgroundEngaged` so
    /// model-level side effects (shield engagement, banner) aren't
    /// duplicated. Removes the file after reading.
    func drainPendingPushFromAppGroup() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return }
        let url = containerURL.appendingPathComponent("last-message.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        try? FileManager.default.removeItem(at: url)

        var userInfo: [AnyHashable: Any] = [:]
        for (key, value) in dict where key != "_writtenAt" {
            userInfo[key] = value
        }
        guard !userInfo.isEmpty else { return }

        log.info("drainPendingPushFromAppGroup: replaying NSE push for overlay")
        acceptPushUserInfo(userInfo, wasBackgroundEngaged: true)
    }

    /// Fakes an incoming push. Used by previews / test affordances so
    /// the overlay + local-notification flow can be exercised without
    /// the network in the loop.
    func injectFakeMessage(title: String = "Claude Code",
                           body: String = "Permission required to run a tool.",
                           event: VibezEvent = .needsInput,
                           shield: VibezShield = .on,
                           agent: VibezAgent = .claude,
                           sessionId: String? = "test-session") {
        var msg = NtfyMessage(
            id: UUID().uuidString,
            title: title,
            body: body,
            receivedAt: Date()
        )
        msg.event = event
        msg.shield = shield
        msg.sessionId = sessionId
        msg.agent = agent
        lastMessage = msg
    }

    // MARK: - Notification delivery

    /// Strip the inline Markdown markers Claude/Codex emit (`**bold**`,
    /// `*italic*`, `` `code` ``, `~~strike~~`, `[text](url)`) so they
    /// don't render literally in iOS notifications. iOS push UI is plain
    /// text — SwiftUI handles rich rendering in-app via `Text(.init(...))`.
    static func stripMarkdown(_ s: String) -> String {
        var out = s
        let subs: [(String, String)] = [
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),      // [text](url) → text
            (#"\*\*(.+?)\*\*"#,         "$1"),      // **bold** → bold
            (#"__(.+?)__"#,             "$1"),      // __bold__ → bold
            (#"~~(.+?)~~"#,             "$1"),      // ~~strike~~ → strike
            (#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, "$1"),// *italic* → italic
        ]
        for (pat, repl) in subs {
            out = out.replacingOccurrences(of: pat, with: repl, options: .regularExpression)
        }
        out = out.replacingOccurrences(of: "`", with: "")
        return out
    }

    /// Schedule a local notification for this message. Caller owns the
    /// gating policy (toggle state, shield kind) — this just renders.
    func scheduleLocalNotification(_ msg: NtfyMessage) {
        let content = UNMutableNotificationContent()
        content.title = Self.stripMarkdown(msg.displayTitle)
        let rawBody = msg.body.isEmpty ? "Vibez ping" : msg.body
        content.body = Self.stripMarkdown(rawBody)
        content.sound = .default
        // Carry the session id so the Notification Service Extension can
        // pull this banner back out of Notification Center when the user
        // replies (shield:off — see NotificationService.clearDeliveredNotifications).
        // Remote-push banners already carry `session` from the server
        // payload; foreground-scheduled ones need it stamped here or they'd
        // survive the reply.
        if let sessionId = msg.sessionId {
            content.userInfo["session"] = sessionId
        }
        // Codex pings get the blue pixel-Z identity: communication-
        // notification styling puts the blue avatar in the banner's
        // app-icon slot (iOS badges the real app icon on its corner —
        // system behavior, not removable). Deliberately NO attachment:
        // device banners render an attachment as a SECOND blue icon on
        // the trailing edge (the sim doesn't, which hid it). Missing
        // PNG (first-launch race) or a styling failure → plain banner,
        // same as today.
        var finalContent: UNNotificationContent = content
        if msg.agent == .codex {
            if let comm = Self.codexCommunicationContent(
                updating: content, sessionId: msg.sessionId
            ) {
                finalContent = comm
                log.info("scheduleLocalNotification: applied codex communication styling")
            } else {
                log.warning("scheduleLocalNotification: codex communication styling unavailable")
            }
        }

        let request = UNNotificationRequest(
            identifier: msg.id,
            content: finalContent,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Restyles a Codex notification as a communication notification:
    /// donates an INSendMessageIntent whose sender carries the blue
    /// pixel-Z avatar (the App Group PNG), so iOS renders that avatar
    /// in the banner's app-icon slot. The sender's display name is the
    /// content's (already prefixed, markdown-stripped) title, so the
    /// visible text is unchanged — only the icon is. Requires the
    /// com.apple.developer.usernotifications.communication entitlement
    /// + INSendMessageIntent in NSUserActivityTypes. Mirrored in
    /// VibezPushService/NotificationService.swift; keep the two in sync.
    static func codexCommunicationContent(
        updating content: UNNotificationContent,
        sessionId: String?
    ) -> UNNotificationContent? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ), let avatarData = try? Data(
            contentsOf: container.appendingPathComponent("notif-codex-v2.png")
        ) else { return nil }

        let sender = INPerson(
            personHandle: INPersonHandle(value: "codex", type: .unknown),
            nameComponents: nil,
            displayName: content.title,
            image: INImage(imageData: avatarData),
            contactIdentifier: nil,
            customIdentifier: "codex"
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: sessionId ?? "codex",
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try? content.updating(from: intent)
    }

    /// Clear every Vibez entry from Notification Center. Called on
    /// foreground when the user has notifications switched off, to mop up
    /// the lone passive straggler the Notification Service Extension can't
    /// remove itself: the NSE runs *before* that entry is delivered, so
    /// only a later, guaranteed execution — the app coming to the
    /// foreground — can drop it (see
    /// NotificationService.clearDeliveredNotifications). App-scoped: iOS
    /// only ever removes this app's own delivered notifications.
    func clearAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Remove every stale shield:off control entry ("Replied" pings,
    /// timeout unblocks) from Notification Center. Those pushes must be
    /// alert pushes (silent pushes don't wake the NSE), so each files in
    /// as a passive entry AFTER the NSE's own sweep ran — the newest one
    /// always outlives it. The NSE catches the backlog on the next push;
    /// this catches it on app activation, so nothing lingers once the
    /// user is here. Matches on the push payload's `shield` field —
    /// locally-scheduled banners never carry it, so they're untouched.
    func clearStaleDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { ($0.request.content.userInfo["shield"] as? String) == "off" }
                .map { $0.request.identifier }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - Permissions

    static func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Permission denied or restricted — silent failure, the in-app
            // overlay still works.
        }
    }

    /// Current notification permission, read fresh from the system.
    /// OnboardingState gates the notifications step on this —
    /// requestAuthorization() above deliberately swallows the grant
    /// result, so callers re-read the status through here after asking.
    static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current()
            .notificationSettings()
            .authorizationStatus
    }
}

#if DEBUG
extension NotifyClient {
    /// Yields a fresh NotifyClient for previews. Same-file access means
    /// we can write through `private(set) var lastMessage` if needed.
    static func previewClient() -> NotifyClient {
        NotifyClient()
    }
}
#endif
