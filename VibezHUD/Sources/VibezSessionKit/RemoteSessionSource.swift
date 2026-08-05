import Foundation

/// Network seam for the remote-session feature. Protocol-shaped so unit
/// tests inject canned docs — no network in tests, ever.
public protocol RemoteEventsFetching: Sendable {
    /// Idempotent: ensure this HUD is registered as a `web` device for
    /// the Vibez ID (that registration is what turns ON the server-side
    /// event-log write — the `hasWeb` gate in /notify).
    func registerIfNeeded() async throws
    func fetchRecentEvents() async throws -> [RemoteEventDoc]
}

/// Anonymous Firestore REST reads + the registerPushToken callable.
/// Mirrors the Chrome extension's mechanism (VibezExtension/src/background/
/// firestore.ts) minus the SDK: the API key is the iOS app's non-secret
/// key, reads are gated by security rules (`read: if true` on the events
/// path), and the client id doubles as the device-doc id.
public final class FirestoreRESTClient: RemoteEventsFetching, @unchecked Sendable {
    private let vibezId: String
    private let clientIdURL: URL
    private let session: URLSession
    private var didRegister = false
    private let lock = NSLock()

    private static let apiKey = "AIzaSyAGhYqKjZt5NlrJa5Cqx4PFSP_wVL6hMkI"
    private static let queryURLBase =
        "https://firestore.googleapis.com/v1/projects/vibez-backend/databases/tokens/documents/events/"
    private static let registerURL =
        URL(string: "https://us-central1-vibez-backend.cloudfunctions.net/registerPushToken")!

    public init(vibezId: String,
                clientIdURL: URL = HUDPaths.hudDir.appendingPathComponent("web-client-id"),
                session: URLSession = .shared) {
        self.vibezId = vibezId; self.clientIdURL = clientIdURL; self.session = session
    }

    public func registerIfNeeded() async throws {
        let done = lock.withLock { didRegister }
        guard !done else { return }
        let clientId = try loadOrCreateClientId()
        var req = URLRequest(url: Self.registerURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": ["fcmToken": clientId, "vibezId": vibezId, "platform": "web"],
        ])
        let (_, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        lock.withLock { didRegister = true }
    }

    public func fetchRecentEvents() async throws -> [RemoteEventDoc] {
        var comps = URLComponents(string: Self.queryURLBase + vibezId + ":runQuery")!
        comps.queryItems = [URLQueryItem(name: "key", value: Self.apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "structuredQuery": [
                "from": [["collectionId": "items"]],
                "orderBy": [["field": ["fieldPath": "createdAtMs"],
                             "direction": "DESCENDING"]],
                "limit": 50,
            ],
        ])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return FirestoreRESTParser.parse(data)
    }

    /// A persisted random 32-hex id — it IS the device-doc id server-side,
    /// so it must survive relaunches or every launch would leak one of the
    /// Vibez ID's 10 device slots.
    private func loadOrCreateClientId() throws -> String {
        if let existing = try? String(contentsOf: clientIdURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count == 32 { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try FileManager.default.createDirectory(at: clientIdURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try fresh.write(to: clientIdURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: clientIdURL.path)
        return fresh
    }
}

/// Holds the latest server docs and hands reduced remote sessions to the
/// snapshot path. `start()` spawns one detached polling loop; reads are
/// lock-guarded so the 5 Hz snapshot path never blocks on the network.
public final class RemoteSessionSource: @unchecked Sendable {
    private let fetcher: any RemoteEventsFetching
    private let config: StoreConfig
    private let pollIntervalMs: Int64
    private var latestDocs: [RemoteEventDoc] = []
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(fetcher: any RemoteEventsFetching,
                config: StoreConfig = StoreConfig(),
                pollIntervalMs: Int64 = 15_000) {
        self.fetcher = fetcher; self.config = config; self.pollIntervalMs = pollIntervalMs
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                guard let interval = self?.pollIntervalMs else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }

    public func pollOnce() async {
        // Registration failure must not block reads: the log may already
        // exist (Chrome extension registered), and registration retries
        // on the next poll anyway.
        try? await fetcher.registerIfNeeded()
        guard let docs = try? await fetcher.fetchRecentEvents() else { return }
        lock.withLock { latestDocs = docs }
    }

    public func currentSessions(now: Int64) -> [Session] {
        let docs = lock.withLock { latestDocs }
        return RemoteReducer.sessions(docs: docs, now: now, config: config)
    }

    /// Pure enablement rule, seamed out of makeDefault for testability.
    public static func shouldEnable(vibezId: String?, killSwitch: String?) -> Bool {
        guard killSwitch != "1" else { return false }
        guard let id = vibezId else { return false }
        return id.range(of: #"^[a-z]{3,5}(-[a-z]{3,5}){3}$"#,
                        options: .regularExpression) != nil
    }

    /// nil when the feature is off: kill switch set, or no (valid) Vibez
    /// ID paired on this Mac. The HUD stays fully offline in that case.
    public static func makeDefault() -> RemoteSessionSource? {
        let killSwitch = ProcessInfo.processInfo.environment["VIBEZ_HUD_NO_REMOTE"]
        let idURL = HUDPaths.configDir.appendingPathComponent("vibez-id")
        let vibezId = (try? String(contentsOf: idURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldEnable(vibezId: vibezId, killSwitch: killSwitch),
              let id = vibezId else { return nil }
        return RemoteSessionSource(fetcher: FirestoreRESTClient(vibezId: id))
    }
}
