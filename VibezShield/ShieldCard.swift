//
//  ShieldCard.swift
//  VibezShield
//
//  Self-contained model + SwiftUI view rendered to UIImage and slotted
//  into ShieldConfiguration.icon. Mirrors BlockedOverlay's aesthetic
//  within the constraints of the Shield Configuration API: no
//  animations, no live countdown, no interactivity. The image is
//  rasterized once per `configuration(shielding:)` call.
//

import SwiftUI
import os

extension Logger {
    static let shieldExt = Logger(subsystem: "vibezlol.Vibez.Shield", category: "Extension")
}

enum Agent: String {
    case claude, codex, both, none
}

struct ShieldState {
    let agent: Agent
    let title: String?
    let body: String?
    let expiresAt: Date?
    let dark: Bool

    /// Reads the latest snapshot from the shared App Group defaults.
    /// Returns nil when state is missing or older than the 24h
    /// cutoff — callers fall back to `ShieldState.fallback`.
    nonisolated static func read() -> ShieldState? {
        let group = UserDefaults(suiteName: "group.vibezlol.Vibez")
        guard let dict = group?.dictionary(forKey: "shieldState"),
              let agentRaw = dict["agent"] as? String,
              let agent = Agent(rawValue: agentRaw),
              let updatedAt = dict["updatedAt"] as? Double
        else {
            Logger.shieldExt.info("ShieldState: missing or malformed; using fallback")
            return nil
        }

        let age = Date().timeIntervalSince1970 - updatedAt
        guard age < 60 * 60 * 24 else {
            Logger.shieldExt.info("ShieldState: stale (\(Int(age))s); using fallback")
            return nil
        }

        return ShieldState(
            agent: agent,
            title: dict["title"] as? String,
            body: dict["body"] as? String,
            expiresAt: (dict["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)),
            dark: (dict["dark"] as? Bool) ?? true
        )
    }

    nonisolated static let fallback = ShieldState(
        agent: .none,
        title: nil,
        body: nil,
        expiresAt: nil,
        dark: true
    )

    /// Accent color used by ShieldCard and ShieldConfiguration's
    /// primary button. Claude orange / Codex blue / Vibez orange for
    /// the generic case.
    nonisolated var accentUIColor: UIColor {
        switch agent {
        case .claude, .both, .none:
            return UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)
        case .codex:
            return UIColor(red: 0.29, green: 0.48, blue: 1.00, alpha: 1.0)
        }
    }
}
