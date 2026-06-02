//
//  IgnoreStore.swift
//  Vibez
//
//  Persists the user's mute rules. Two kinds:
//
//   • .session(sid, name)  — silences exactly one conversation by sid.
//                            Used for one-off "ignore this thread."
//   • .name(name)          — silences any conversation whose title matches
//                            (case-insensitive). For recurring agents
//                            (e.g. a cron-launched `claude` invocation
//                            that gets a fresh sid every run).
//
//  When a ping arrives that matches any rule, it's still appended to
//  Recent triggers (dimmed) but the shield is never engaged.
//

import Foundation

enum IgnoreRule: Codable, Identifiable, Equatable {
    case session(sessionId: String, name: String, ignoredAt: Date)
    case name(name: String, ignoredAt: Date)

    var id: String {
        switch self {
        case .session(let sid, _, _): return "sid:\(sid)"
        case .name(let n, _): return "name:\(n.lowercased())"
        }
    }

    var displayName: String {
        switch self {
        case .session(_, let n, _), .name(let n, _): return n
        }
    }

    var ignoredAt: Date {
        switch self {
        case .session(_, _, let d), .name(_, let d): return d
        }
    }

    var isNameRule: Bool {
        if case .name = self { return true }
        return false
    }

    fileprivate func matches(sessionId: String, name: String) -> Bool {
        switch self {
        case .session(let sid, _, _):
            return sid == sessionId
        case .name(let muted, _):
            return muted.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }
}

@MainActor
@Observable
final class IgnoreStore {
    /// Singleton so ScreenTimeManager.applyTriggerFor (called from the
    /// background push path) can read ignore rules without going through
    /// a view's @State. ContentView defaults to this same instance;
    /// previews still inject their own via the explicit init parameter.
    static let shared = IgnoreStore()

    private(set) var rules: [IgnoreRule] = []

    private let defaults: UserDefaults
    private let key = "vibez.ignored.v2"
    private let legacyKey = "vibez.ignored.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// True when any rule (session or name) matches this trigger.
    func contains(sessionId: String, name: String) -> Bool {
        guard isUsableSid(sessionId) else { return false }
        return rules.contains { $0.matches(sessionId: sessionId, name: name) }
    }

    func sessionRuleMatching(sessionId: String) -> IgnoreRule? {
        guard isUsableSid(sessionId) else { return nil }
        return rules.first { rule in
            if case .session(let sid, _, _) = rule, sid == sessionId { return true }
            return false
        }
    }

    func nameRuleMatching(name: String) -> IgnoreRule? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return rules.first { rule in
            if case .name(let muted, _) = rule {
                return muted.compare(trimmed, options: .caseInsensitive) == .orderedSame
            }
            return false
        }
    }

    func ignoreSession(sessionId: String, name: String) {
        guard isUsableSid(sessionId) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = rules.firstIndex(where: { rule in
            if case .session(let sid, _, _) = rule, sid == sessionId { return true }
            return false
        }) {
            // Refresh stored display name in place; keep ignoredAt stable.
            rules[idx] = .session(
                sessionId: sessionId,
                name: trimmedName,
                ignoredAt: rules[idx].ignoredAt
            )
        } else {
            rules.insert(
                .session(sessionId: sessionId, name: trimmedName, ignoredAt: Date()),
                at: 0
            )
        }
        save()
    }

    func ignoreName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if nameRuleMatching(name: trimmed) != nil { return }
        rules.insert(.name(name: trimmed, ignoredAt: Date()), at: 0)
        save()
    }

    func remove(ruleId: String) {
        let before = rules.count
        rules.removeAll { $0.id == ruleId }
        if rules.count != before { save() }
    }

    /// Refresh the cached display name on a session rule. No-op if the
    /// sid isn't covered by a session rule.
    func refreshName(sessionId: String, name: String) {
        guard isUsableSid(sessionId) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = rules.firstIndex(where: { rule in
            if case .session(let sid, _, _) = rule, sid == sessionId { return true }
            return false
        }) else { return }
        if case .session(_, let existing, let date) = rules[idx], existing != trimmed {
            rules[idx] = .session(sessionId: sessionId, name: trimmed, ignoredAt: date)
            save()
        }
    }

    private func isUsableSid(_ sid: String) -> Bool {
        !sid.isEmpty && sid != "nosid"
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([IgnoreRule].self, from: data) {
            rules = decoded
            return
        }
        // v1 → v2 migration: every legacy entry was a session rule.
        if let data = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode([LegacyIgnored].self, from: data) {
            rules = legacy.map {
                .session(sessionId: $0.sessionId, name: $0.name, ignoredAt: $0.ignoredAt)
            }
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }

    private struct LegacyIgnored: Codable {
        let sessionId: String
        var name: String
        let ignoredAt: Date
    }
}
