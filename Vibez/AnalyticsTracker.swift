//
//  AnalyticsTracker.swift
//  Vibez
//
//  Per-day usage stats: distinct conversations seen, user replies,
//  reply body lengths, total incoming pings. Resets at local midnight
//  on the first event of the new day (lazy — no timer). Persists to
//  standard UserDefaults so today's numbers survive force-quit.
//
//  Not visible to the shield extension. App Group is unused here.
//

import Foundation
import FamilyControls
import ManagedSettings

struct DailyStats: Codable, Equatable {
    /// Calendar day (startOfDay) these stats are for. Drives midnight rollover.
    var date: Date
    /// Distinct session_ids seen today.
    var conversationIds: Set<String>
    /// Count of `_vibez:event:replied` pings.
    var responseCount: Int
    /// Character count of `NtfyMessage.body` for each `replied` ping, in arrival order.
    var responseLengths: [Int]
    /// Count of all incoming ntfy messages today (any event, including untagged).
    var pingCount: Int
    /// Accumulated shield-armed seconds for `date`. Closed intervals only —
    /// any in-flight interval is represented by `shieldArmedAt` and added
    /// in at display time.
    var focusSeconds: TimeInterval
    /// Non-nil while the shield is currently up. Cleared on lift; the
    /// elapsed delta is folded into `focusSeconds` at that moment.
    var shieldArmedAt: Date?

    static func zero(on date: Date) -> DailyStats {
        DailyStats(
            date: date,
            conversationIds: [],
            responseCount: 0,
            responseLengths: [],
            pingCount: 0,
            focusSeconds: 0,
            shieldArmedAt: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case date, conversationIds, responseCount, responseLengths, pingCount, focusSeconds, shieldArmedAt
    }

    init(
        date: Date,
        conversationIds: Set<String>,
        responseCount: Int,
        responseLengths: [Int],
        pingCount: Int,
        focusSeconds: TimeInterval = 0,
        shieldArmedAt: Date? = nil
    ) {
        self.date = date
        self.conversationIds = conversationIds
        self.responseCount = responseCount
        self.responseLengths = responseLengths
        self.pingCount = pingCount
        self.focusSeconds = focusSeconds
        self.shieldArmedAt = shieldArmedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        conversationIds = try c.decode(Set<String>.self, forKey: .conversationIds)
        responseCount = try c.decode(Int.self, forKey: .responseCount)
        responseLengths = try c.decode([Int].self, forKey: .responseLengths)
        pingCount = try c.decode(Int.self, forKey: .pingCount)
        // Back-compat: older persisted DailyStats predates these fields.
        focusSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .focusSeconds) ?? 0
        shieldArmedAt = try c.decodeIfPresent(Date.self, forKey: .shieldArmedAt)
    }
}

/// Host-side mirror of VibezShield's `AppBlockTally` (separate target, same
/// JSON shape, default `JSONEncoder`/`JSONDecoder`). The shield extension
/// owns writes; `AnalyticsTracker` only reads and ranks.
private struct AppBlockTally: Codable {
    var date: Date
    var counts: [ApplicationToken: Int]
}

@MainActor
@Observable
final class AnalyticsTracker {
    /// Shared instance backing ScreenTimeManager's focus-time edges and
    /// ContentView's default analytics state. Previews still inject
    /// their own via the standard initializer.
    static let shared = AnalyticsTracker()

    private(set) var stats: DailyStats

    private let defaults: UserDefaults
    private static let key = "vibez.analytics.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.stats = Self.load(defaults: defaults)
            ?? DailyStats.zero(on: Calendar.current.startOfDay(for: Date()))
        rollIfNeeded()
    }

    /// Feed every incoming ntfy message. Rolls the day first, then folds
    /// the message into today's stats. Safe to call for any message —
    /// untagged pings still increment `pingCount`.
    func record(_ message: NtfyMessage) {
        rollIfNeeded()
        stats.pingCount += 1
        if let sid = message.sessionId, sid.isUsableSessionId {
            stats.conversationIds.insert(sid)
        }
        if message.event == .replied {
            stats.responseCount += 1
            stats.responseLengths.append(message.body.count)
        }
        save()
    }

    /// Edge: shield just went up. Idempotent — repeated calls without a
    /// matching `noteShieldLifted` are no-ops, so callers (applyShield)
    /// don't need to track transitions themselves.
    func noteShieldArmed() {
        rollIfNeeded()
        guard stats.shieldArmedAt == nil else { return }
        stats.shieldArmedAt = Date()
        save()
    }

    /// Edge: shield just came down. Folds the in-flight interval into
    /// `focusSeconds` and clears the marker. Idempotent when not armed.
    func noteShieldLifted() {
        rollIfNeeded()
        guard let armedAt = stats.shieldArmedAt else { return }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let from = max(armedAt, startOfDay)
        stats.focusSeconds += Date().timeIntervalSince(from)
        stats.shieldArmedAt = nil
        save()
    }

    // MARK: - Derived views
    //
    // Currently unread by the UI — the home screen's "Today" panel was
    // dropped in the prototype-match redesign. Recording stays live (the
    // tracker still counts every ping, reply, and focus interval) so a
    // future stats surface can pick these up without losing history.

    var conversationsToday: Int { stats.conversationIds.count }
    var responsesToday: Int { stats.responseCount }
    var pingsToday: Int { stats.pingCount }
    var averageResponseLength: Double {
        guard !stats.responseLengths.isEmpty else { return 0 }
        let sum = stats.responseLengths.reduce(0, +)
        return Double(sum) / Double(stats.responseLengths.count)
    }

    /// Total seconds the shield has been up so far today, including any
    /// currently-running interval. Computed at call time so periodic UI
    /// refreshes (e.g. a TimelineView) animate.
    var focusSecondsToday: TimeInterval {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let stored = stats.date == startOfDay ? stats.focusSeconds : 0
        guard let armedAt = stats.shieldArmedAt else { return stored }
        let from = max(armedAt, startOfDay)
        return stored + Date().timeIntervalSince(from)
    }

    /// Today's top-N most-blocked apps, ordered by descending count — the
    /// apps you opened into the shield most. Read from the App-Group tally
    /// the VibezShield extension writes (see `loadBlockTally`). Tie-broken
    /// by hash so near-equal apps order stably within a session.
    func topBlockedApps(limit: Int = 3) -> [ApplicationToken] {
        let sorted = loadBlockTally().sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.hashValue > rhs.key.hashValue
        }
        return sorted.prefix(limit).map { $0.key }
    }

    /// Today's per-app block counts, written by the VibezShield extension
    /// each time the user opens a shielded app. Read straight from the App
    /// Group file on every call — it's tiny and the tile renders
    /// infrequently. A missing file or stale day reads as empty, so the
    /// tile resets at local midnight like the rest of the Today panel.
    private func loadBlockTally() -> [ApplicationToken: Int] {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        )?.appendingPathComponent("app-block-tally.json"),
              let data = try? Data(contentsOf: url),
              let tally = try? JSONDecoder().decode(AppBlockTally.self, from: data),
              tally.date == Calendar.current.startOfDay(for: Date())
        else { return [:] }
        return tally.counts
    }

    // MARK: - Rollover

    private func rollIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if stats.date != today {
            // Preserve the in-flight armed marker so a shield that
            // straddles midnight keeps counting toward the new day,
            // starting from 00:00 of the new day rather than the
            // original armedAt (which would inflate today's focus by
            // however long the shield was up yesterday).
            let carriedArmedAt: Date? = stats.shieldArmedAt != nil ? today : nil
            stats = DailyStats.zero(on: today)
            stats.shieldArmedAt = carriedArmedAt
            save()
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(defaults: UserDefaults) -> DailyStats? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(DailyStats.self, from: data)
    }
}
