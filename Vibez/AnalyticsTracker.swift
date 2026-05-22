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
    /// Per-app shield-activation count for today. Bumped once per
    /// ApplicationToken in the active selection each time a shield
    /// actually fires (i.e. trigger arrived, blocking armed, session
    /// not ignored). Categories and web domains aren't counted —
    /// they don't expose member apps, so a category-only blocker
    /// shows nothing here.
    var appBlockCounts: [ApplicationToken: Int]

    static func zero(on date: Date) -> DailyStats {
        DailyStats(
            date: date,
            conversationIds: [],
            responseCount: 0,
            responseLengths: [],
            pingCount: 0,
            appBlockCounts: [:]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case date, conversationIds, responseCount, responseLengths, pingCount, appBlockCounts
    }

    init(
        date: Date,
        conversationIds: Set<String>,
        responseCount: Int,
        responseLengths: [Int],
        pingCount: Int,
        appBlockCounts: [ApplicationToken: Int]
    ) {
        self.date = date
        self.conversationIds = conversationIds
        self.responseCount = responseCount
        self.responseLengths = responseLengths
        self.pingCount = pingCount
        self.appBlockCounts = appBlockCounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        conversationIds = try c.decode(Set<String>.self, forKey: .conversationIds)
        responseCount = try c.decode(Int.self, forKey: .responseCount)
        responseLengths = try c.decode([Int].self, forKey: .responseLengths)
        pingCount = try c.decode(Int.self, forKey: .pingCount)
        // Back-compat: older persisted DailyStats predates this field.
        appBlockCounts = try c.decodeIfPresent([ApplicationToken: Int].self, forKey: .appBlockCounts) ?? [:]
    }
}

@MainActor
@Observable
final class AnalyticsTracker {
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
        if let sid = message.sessionId, !sid.isEmpty, sid != "nosid" {
            stats.conversationIds.insert(sid)
        }
        if message.event == .replied {
            stats.responseCount += 1
            stats.responseLengths.append(message.body.count)
        }
        save()
    }

    /// Bump per-app block counts. Call once per shield activation
    /// with the active `FamilyActivitySelection.applicationTokens`.
    func recordShieldActivation(applicationTokens: Set<ApplicationToken>) {
        guard !applicationTokens.isEmpty else { return }
        rollIfNeeded()
        for token in applicationTokens {
            stats.appBlockCounts[token, default: 0] += 1
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

    /// Today's top-N most-blocked apps, ordered by descending count.
    /// Tie-broken by hash so the ordering is stable within a session.
    func topBlockedApps(limit: Int = 3) -> [ApplicationToken] {
        let sorted = stats.appBlockCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.hashValue > rhs.key.hashValue
        }
        return sorted.prefix(limit).map { $0.key }
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
        defaults.set(data, forKey: Self.key)
    }

    private static func load(defaults: UserDefaults) -> DailyStats? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(DailyStats.self, from: data)
    }
}
