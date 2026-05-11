//
//  IgnoreStore.swift
//  Vibez
//
//  Persists the set of conversation session_ids the user has chosen to
//  mute. When a ping arrives for one of these sids, it's still logged
//  in Recent triggers but the shield is never engaged.
//

import Foundation

struct IgnoredConversation: Codable, Identifiable, Equatable {
    /// session_id is the natural key — name is just for display/search.
    var id: String { sessionId }
    let sessionId: String
    var name: String
    let ignoredAt: Date
}

@MainActor
@Observable
final class IgnoreStore {
    private(set) var conversations: [IgnoredConversation] = []

    private let defaults: UserDefaults
    private let key = "vibez.ignored.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func contains(_ sessionId: String) -> Bool {
        guard isUsableSid(sessionId) else { return false }
        return conversations.contains { $0.sessionId == sessionId }
    }

    /// Upsert: ignore a new sid, or refresh the stored name if it's
    /// already ignored.
    func ignore(sessionId: String, name: String) {
        guard isUsableSid(sessionId) else { return }
        if let idx = conversations.firstIndex(where: { $0.sessionId == sessionId }) {
            conversations[idx].name = name
        } else {
            conversations.insert(
                IgnoredConversation(
                    sessionId: sessionId,
                    name: name,
                    ignoredAt: Date()
                ),
                at: 0
            )
        }
        save()
    }

    func unignore(sessionId: String) {
        guard isUsableSid(sessionId) else { return }
        let before = conversations.count
        conversations.removeAll { $0.sessionId == sessionId }
        if conversations.count != before { save() }
    }

    /// Update the cached name on an already-ignored conversation. No-op
    /// if the sid isn't ignored.
    func refreshName(sessionId: String, name: String) {
        guard isUsableSid(sessionId) else { return }
        guard let idx = conversations.firstIndex(where: { $0.sessionId == sessionId })
        else { return }
        guard conversations[idx].name != name else { return }
        conversations[idx].name = name
        save()
    }

    private func isUsableSid(_ sid: String) -> Bool {
        !sid.isEmpty && sid != "nosid"
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        if let decoded = try? JSONDecoder().decode([IgnoredConversation].self, from: data) {
            conversations = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        defaults.set(data, forKey: key)
    }
}
