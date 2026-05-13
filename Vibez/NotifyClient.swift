//
//  NotifyClient.swift
//  Vibez
//
//  Subscribes to a ntfy.sh topic over WebSocket while the app is in
//  the foreground. On each incoming message, fires a local notification
//  and surfaces the message via @Observable so the UI can react
//  (e.g. show the BlockedOverlay).
//
//  This is the "demo" path until Family Controls is unlocked: we can't
//  actually shield apps yet, but we can prove the Mac → ntfy → phone
//  pipeline by lighting up the device.
//

import Foundation
import UserNotifications

/// What lifecycle moment the push represents, parsed from
/// "_vibez:event:<value>".
enum VibezEvent: String, Equatable {
    case done           // Stop hook, last turn was not a question
    case needsInput     = "needs-input"  // Notification, or Stop where Claude asked
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

/// Whether the iPhone should be shielded right now, parsed from
/// "_vibez:shield:<value>".
enum VibezShield: String, Equatable {
    case on
    case off
}

/// Which agent produced this push, parsed from "_vibez:agent:<value>".
/// Set by the plugin so the app doesn't have to sniff title/body strings.
enum VibezAgent: String, Equatable {
    case claude = "cc"
    case codex  = "cx"
}

struct NtfyMessage: Equatable {
    let id: String
    let title: String
    let body: String
    let receivedAt: Date
    /// Lifecycle moment from "_vibez:event:<value>". nil for pushes with
    /// no Vibez control tags (third-party producer, test pings, etc.).
    var event: VibezEvent? = nil
    /// Block intent from "_vibez:shield:<value>". nil for pushes with no
    /// Vibez control tags.
    var shield: VibezShield? = nil
    /// Claude Code session_id from "_vibez:session:<value>".
    var sessionId: String? = nil
    /// Producing agent from "_vibez:agent:<value>" ("cc" → Claude Code,
    /// "cx" → Codex). The Vibez plugin always sets this; nil only for
    /// untagged third-party producers (e.g. a raw `curl` test ping).
    var agent: VibezAgent? = nil

    /// True while Claude is parked on a user reply. Derived from `event`
    /// rather than stored separately — `needs-input` is the only state
    /// that means "waiting on the user".
    var needsReply: Bool { event == .needsInput }

    /// Title with the event prefix applied: "Done — Plan plugin distribution".
    /// Used for local notifications and the blocked overlay so the user can
    /// see at a glance what Claude is asking for. Falls back to the raw
    /// title when no event tag is present (third-party / untagged pings).
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

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case error(String)
    }

    private(set) var state: ConnectionState = .idle
    private(set) var lastMessage: NtfyMessage?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession = .shared
    private var currentURL: String = ""
    private var reconnectWorkItem: Task<Void, Never>?
    private var generation = 0

    // MARK: - Public API

    func updateURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == currentURL { return }
        currentURL = trimmed
        disconnect()
        guard !trimmed.isEmpty, let _ = makeWebSocketURL(from: trimmed) else {
            state = .idle
            return
        }
        connect()
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        generation += 1
        if case .connecting = state { state = .idle }
        if case .connected = state { state = .idle }
    }

    /// One-shot connectivity probe. Opens a parallel WebSocket to
    /// `urlString`, waits for the first server frame (ntfy sends an
    /// "open" event on subscribe), and returns true on receipt or false
    /// on error/timeout. The test task is always cancelled before
    /// returning, so this leaves no connection sitting around.
    ///
    /// Used by the setup card to verify a candidate URL before
    /// committing it to `ntfyURL` — otherwise a junk URL would unlock
    /// the main toggle while the real connection silently fails in
    /// the background.
    func validate(urlString: String, timeout: TimeInterval = 5.0) async -> Bool {
        guard let url = makeWebSocketURL(from: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let probe = session.webSocketTask(with: request)
        probe.resume()
        defer {
            probe.cancel(with: .normalClosure, reason: nil)
        }

        // A timeout task that force-cancels the probe — which makes
        // receive() resolve with .failure(.cancelled), so we never wait
        // forever on a URL that accepted the TCP/TLS handshake but
        // doesn't speak the ntfy protocol.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            probe.cancel(with: .normalClosure, reason: nil)
        }

        let success: Bool = await withCheckedContinuation { cont in
            probe.receive { result in
                switch result {
                case .success: cont.resume(returning: true)
                case .failure: cont.resume(returning: false)
                }
            }
        }
        timeoutTask.cancel()
        return success
    }

    /// Fakes an incoming ntfy message. Used for the in-app "Test push"
    /// button so the user can see the overlay + local notification flow
    /// without the network in the loop.
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
        deliver(msg)
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard let url = makeWebSocketURL(from: currentURL) else { return }
        generation += 1
        let myGen = generation
        state = .connecting

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()

        // Stay in .connecting until the first server frame lands — ntfy
        // sends an "open" event on subscribe, so the success branch in
        // receiveLoop is what tells us the handshake actually completed.
        // Setting .connected here would lie about bad URLs and make the
        // setup card flicker on the connecting/error reconnect loop.
        receiveLoop(generation: myGen)
    }

    private func receiveLoop(generation myGen: Int) {
        guard let task = task, myGen == generation else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if myGen != self.generation { return } // stale
                switch result {
                case .failure(let error):
                    self.state = .error(error.localizedDescription)
                    self.scheduleReconnect()
                case .success(let message):
                    // First successful frame promotes us to .connected.
                    // Later frames just re-enter — case .connected is
                    // already the steady state.
                    if case .connecting = self.state {
                        self.state = .connected
                    }
                    self.handle(message: message)
                    self.receiveLoop(generation: myGen)
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let myGen = generation
        reconnectWorkItem = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                guard let self, !Task.isCancelled, myGen == self.generation else { return }
                self.connect()
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let text: String? = {
            switch message {
            case .string(let s): return s
            case .data(let d): return String(data: d, encoding: .utf8)
            @unknown default: return nil
            }
        }()
        guard let text, let data = text.data(using: .utf8) else { return }
        guard let payload = try? JSONDecoder().decode(NtfyPayload.self, from: data) else {
            return
        }
        guard payload.event == "message" else { return } // ignore open/keepalive
            
        var msg = NtfyMessage(
            id: payload.id ?? UUID().uuidString,
            title: payload.title ?? "Vibez",
            body: payload.message ?? "",
            receivedAt: Date()
        )
        // Control tags arrive as three orthogonal "_vibez:<key>:<value>"
        // tuples — event, session, shield. Any combination may be
        // present; unknown values are ignored.
        for tag in payload.tags ?? [] {
            let parts = tag.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "_vibez" else { continue }
            let key = String(parts[1])
            let value = String(parts[2])
            switch key {
            case "event":   msg.event = VibezEvent(rawValue: value)
            case "shield":  msg.shield = VibezShield(rawValue: value)
            case "session": msg.sessionId = value
            case "agent":   msg.agent = VibezAgent(rawValue: value)
            default:        continue
            }
        }
        // Hand off to ContentView. shield:on raises the shield, shield:off
        // lowers it for the matching session, untagged pings just surface
        // the overlay — the routing lives in handleIncoming(), not here.
        deliver(msg)
    }

    // MARK: - Notification delivery

    /// Just publish the message — the decision to surface a local
    /// notification lives in ContentView.handleIncoming so it can be
    /// gated on the user's toggle and skipped for shield:off replies.
    private func deliver(_ msg: NtfyMessage) {
        lastMessage = msg
    }

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

    // MARK: - URL helpers

    /// Converts an arbitrary user-pasted ntfy URL into a WebSocket URL.
    /// Examples accepted:
    ///   - https://ntfy.sh/abc        -> wss://ntfy.sh/abc/ws
    ///   - http://my.ntfy.example/abc -> ws://my.ntfy.example/abc/ws
    ///   - ntfy.sh/abc                -> wss://ntfy.sh/abc/ws
    ///   - ntfy.sh/abc/ws             -> wss://ntfy.sh/abc/ws (idempotent)
    private func makeWebSocketURL(from input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if !s.contains("://") {
            s = "https://" + s
        }
        if s.hasSuffix("/") {
            s.removeLast()
        }
        if !s.hasSuffix("/ws") {
            s += "/ws"
        }
        if s.hasPrefix("https://") {
            s = "wss://" + s.dropFirst("https://".count)
        } else if s.hasPrefix("http://") {
            s = "ws://" + s.dropFirst("http://".count)
        }
        return URL(string: s)
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

// MARK: - Wire format

private struct NtfyPayload: Decodable {
    let id: String?
    let event: String?
    let topic: String?
    let title: String?
    let message: String?
    let time: Int?
    let tags: [String]?
}
