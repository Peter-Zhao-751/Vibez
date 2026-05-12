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
}

/// Whether the iPhone should be shielded right now, parsed from
/// "_vibez:shield:<value>".
enum VibezShield: String, Equatable {
    case on
    case off
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

    /// True while Claude is parked on a user reply. Derived from `event`
    /// rather than stored separately — `needs-input` is the only state
    /// that means "waiting on the user".
    var needsReply: Bool { event == .needsInput }
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

    /// Fakes an incoming ntfy message. Used for the in-app "Test push"
    /// button so the user can see the overlay + local notification flow
    /// without the network in the loop.
    func injectFakeMessage(title: String = "Claude Code",
                           body: String = "Permission required to run a tool.",
                           event: VibezEvent = .needsInput,
                           shield: VibezShield = .on,
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

        // ntfy considers a connection established once the upgrade succeeds;
        // reaching the first receive() is a strong signal.
        receiveLoop(generation: myGen)
        state = .connected
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
            default:        continue
            }
        }
        if msg.shield == .on {
            deliver(msg)
        }
    }

    // MARK: - Notification delivery

    private func deliver(_ msg: NtfyMessage) {
        lastMessage = msg
        scheduleLocalNotification(msg)
    }

    private func scheduleLocalNotification(_ msg: NtfyMessage) {
        let content = UNMutableNotificationContent()
        content.title = msg.title
        content.body = msg.body.isEmpty ? "Vibez ping" : msg.body
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
