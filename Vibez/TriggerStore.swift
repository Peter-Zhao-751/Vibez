//
//  TriggerStore.swift
//  Vibez
//
//  Persists the most recent agent triggers (capped at 10) to UserDefaults
//  so the "Recent triggers" section keeps state across launches.
//

import Foundation

@MainActor
@Observable
final class TriggerStore {
    private(set) var events: [TriggerEvent] = []

    private let defaults: UserDefaults
    private let key = "vibez.triggers.v1"
    private let maxCount = 100

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func record(_ event: TriggerEvent) {
        events.insert(event, at: 0)
        if events.count > maxCount {
            events = Array(events.prefix(maxCount))
        }
        save()
    }

    func clear() {
        events = []
        save()
    }

    /// Marks any TriggerEvent for the given session id as no-longer-
    /// awaiting-reply. Called when a `_vibez:unblock:<sid>` arrives
    /// because the user just replied in that conversation.
    func clearNeedsReply(forSession sid: String) {
        var changed = false
        for i in events.indices where events[i].sessionId == sid && events[i].needsReply {
            events[i].needsReply = false
            changed = true
        }
        if changed {
            save()
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([TriggerEvent].self, from: data) {
            events = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: key)
    }
}
