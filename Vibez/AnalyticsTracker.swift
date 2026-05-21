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

    static func zero(on date: Date) -> DailyStats {
        DailyStats(
            date: date,
            conversationIds: [],
            responseCount: 0,
            responseLengths: [],
            pingCount: 0
        )
    }
}

@MainActor
@Observable
final class AnalyticsTracker {
    private(set) var stats: DailyStats

    private let defaults: UserDefaults
    private let key = "vibez.analytics.v1"

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
        if let sid = message.sessionId, !sid.isEmpty, sid != "nosid" {
            stats.conversationIds.insert(sid)
        }
        if message.event == .replied {
            stats.responseCount += 1
            stats.responseLengths.append(message.body.count)
        }
        save()
    }

    // MARK: - Derived views

    var conversationsToday: Int { stats.conversationIds.count }
    var responsesToday: Int { stats.responseCount }
    var pingsToday: Int { stats.pingCount }
    var averageResponseLength: Double {
        guard !stats.responseLengths.isEmpty else { return 0 }
        let sum = stats.responseLengths.reduce(0, +)
        return Double(sum) / Double(stats.responseLengths.count)
    }

    // MARK: - Rollover

    private func rollIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if stats.date != today {
            stats = DailyStats.zero(on: today)
            save()
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(defaults: UserDefaults) -> DailyStats? {
        guard let data = defaults.data(forKey: "vibez.analytics.v1") else { return nil }
        return try? JSONDecoder().decode(DailyStats.self, from: data)
    }
}
