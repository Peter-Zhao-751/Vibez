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
    ///   "title": "...",
    ///   "body":  "...",
    ///   "event":   "needs-input" | "done" | "replied",
    ///   "shield":  "on" | "off",
    ///   "session": "<session-id>",
    ///   "agent":   "cc" | "cx"
    /// }
    /// ```
    func acceptPushUserInfo(_ userInfo: [AnyHashable: Any]) {
        var msg = NtfyMessage(
            id: (userInfo["id"] as? String) ?? UUID().uuidString,
            title: (userInfo["title"] as? String) ?? "Vibez",
            body: (userInfo["body"] as? String) ?? "",
            receivedAt: Date()
        )
        if let event   = userInfo["event"]   as? String { msg.event     = VibezEvent(rawValue: event) }
        if let shield  = userInfo["shield"]  as? String { msg.shield    = VibezShield(rawValue: shield) }
        if let session = userInfo["session"] as? String { msg.sessionId = session }
        if let agent   = userInfo["agent"]   as? String { msg.agent     = VibezAgent(rawValue: agent) }
        lastMessage = msg
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

        let request = UNNotificationRequest(
            identifier: msg.id,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in }
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
