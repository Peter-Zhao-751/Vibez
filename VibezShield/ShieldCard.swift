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
import ManagedSettings
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

    /// Reads the latest snapshot from `shield-state.json` in the App
    /// Group container. Returns nil when state is missing or older than
    /// the 24h cutoff — callers fall back to `ShieldState.fallback`.
    ///
    /// Reads from a file (not App Group UserDefaults) because iOS 26's
    /// cfprefsd persona-sandbox bug causes writes from VibezPushService
    /// (the NSE) to land in an in-memory cache that this process never
    /// sees, leading to the "Stay focused" fallback every time the
    /// shield was engaged from the background.
    nonisolated static func read() -> ShieldState? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else {
            Logger.shieldExt.info("ShieldState: App Group container unavailable")
            return nil
        }
        let url = containerURL.appendingPathComponent("shield-state.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    /// Single Claude accent — the shield renders Claude visuals no
    /// matter which agent's push engaged it (the `agent` field is kept
    /// as schema data, not a theme switch).
    nonisolated var accentUIColor: UIColor {
        UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)
    }

    nonisolated var backgroundUIColor: UIColor {
        // Tamed-down accent: 25% Claude orange blended into 75% of the
        // dark/light base — a warm-brown wash without going neon. The
        // flat ShieldConfiguration.backgroundColor slot cannot do
        // gradients, so this single tinted color is the closest
        // approximation.
        let mix: CGFloat = 0.25
        let (ar, ag, ab): (CGFloat, CGFloat, CGFloat) = (0.95, 0.45, 0.20)
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

/// Per-app "you bumped into the shield" tally for today, shared from this
/// extension to the host via the App Group container. Keyed by
/// `ApplicationToken` so the host can render the same app icons it already
/// stores in its `FamilyActivitySelection`. Lives in a file (not App Group
/// UserDefaults) for the same iOS 26 cfprefsd reason `ShieldState` does —
/// see `ShieldState.read()`.
///
/// The host has its own mirror of this shape (`AnalyticsTracker`'s private
/// `AppBlockTally`); both use default `JSONEncoder`/`JSONDecoder`, so the
/// file round-trips across targets. It's an approximate counter — iOS may
/// invoke `configuration(shielding:)` more than once per open — but the
/// *ranking* it produces is all the "most blocked" tile needs.
nonisolated struct AppBlockTally: Codable {
    /// `startOfDay` this tally covers. A stale day reads as empty so the
    /// tile resets at local midnight like the rest of the Today panel.
    var date: Date
    var counts: [ApplicationToken: Int]

    private static let fileName = "app-block-tally.json"

    private static func fileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        )?.appendingPathComponent(fileName)
    }

    /// Bump one app's count for today. Read-modify-write on the App Group
    /// file, resetting the bucket when the stored day is stale. Called from
    /// the shield-config callback on iOS's own thread, so it stays cheap and
    /// swallows every error — a dropped count never matters here.
    static func recordOpen(token: ApplicationToken) {
        guard let url = fileURL() else { return }
        let today = Calendar.current.startOfDay(for: Date())
        var tally = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(AppBlockTally.self, from: $0) }
            ?? AppBlockTally(date: today, counts: [:])
        if tally.date != today {
            tally = AppBlockTally(date: today, counts: [:])
        }
        tally.counts[token, default: 0] += 1
        guard let data = try? JSONEncoder().encode(tally) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
