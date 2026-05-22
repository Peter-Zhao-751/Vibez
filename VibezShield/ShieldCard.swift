//
//  ShieldCard.swift
//  VibezShield
//
//  Data model the extension reads from the App Group: the latest
//  ShieldState plus the accent/background colors needed for the
//  ShieldConfiguration response. SwiftUI rendering of the rich card
//  lives on the host (see Vibez/ShieldCardRenderer.swift); the
//  extension only consumes the cached PNG it produced.
//

import Foundation
import UIKit
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

    nonisolated var accentUIColor: UIColor {
        switch agent {
        case .codex: return UIColor(red: 0.29, green: 0.48, blue: 1.00, alpha: 1.0)
        default:     return UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)
        }
    }

    nonisolated var backgroundUIColor: UIColor {
        // Tamed-down agent color: 25% accent blended into 75% of the
        // dark/light base. Gives a warm-brown wash for Claude/none/both
        // and a cool-navy wash for Codex without going neon. The flat
        // ShieldConfiguration.backgroundColor slot cannot do gradients,
        // so this single tinted color is the closest approximation.
        let mix: CGFloat = 0.25
        let (ar, ag, ab): (CGFloat, CGFloat, CGFloat)
        switch agent {
        case .codex:
            (ar, ag, ab) = (0.29, 0.48, 1.00)
        default:
            (ar, ag, ab) = (0.95, 0.45, 0.20)
        }
        let dr: CGFloat = dark ? 0.047 : 0.984
        let dg: CGFloat = dark ? 0.051 : 0.973
        let db: CGFloat = dark ? 0.071 : 0.957
        return UIColor(
            red:   dr * (1 - mix) + ar * mix,
            green: dg * (1 - mix) + ag * mix,
            blue:  db * (1 - mix) + ab * mix,
            alpha: 1
        )
    }

    /// Title text color — `theme.fg` equivalent: white on dark, black on
    /// light. Matches BlockedOverlay's `Text(title).foregroundStyle(theme.fg)`.
    nonisolated var fgUIColor: UIColor {
        dark ? UIColor.white : UIColor.black
    }

    /// Body text color — `theme.fgMute` equivalent: 65% white on dark,
    /// 55% black on light. Matches BlockedOverlay's body Text color.
    nonisolated var fgMuteUIColor: UIColor {
        dark ? UIColor(white: 1.0, alpha: 0.65) : UIColor(white: 0.0, alpha: 0.55)
    }
}
