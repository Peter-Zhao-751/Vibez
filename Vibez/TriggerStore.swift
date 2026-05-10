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
    private let maxCount = 10

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
