//
//  ShieldConfigurationExtension.swift
//  VibezShield
//
//  Replaces iOS's default "App is Restricted, OK" shield. Reads the
//  latest ShieldState from the App Group and a host-rendered per-agent
//  PNG card (shield-claude.png / shield-codex.png) from the App Group
//  container. If a PNG is present, slots it into
//  ShieldConfiguration.icon for the rich visual. Otherwise falls back
//  to a Vibez-branded text-only shield.
//
//  Deliberately NO SwiftUI or ImageRenderer here — those are
//  MainActor-isolated and the data-source override methods are
//  called by iOS from a context Swift's runtime does not recognize
//  as MainActor's serial executor; a `MainActor.assumeIsolated`
//  block traps the extension process at runtime. All SwiftUI work
//  lives in the host target's ShieldCardRenderer.swift, where
//  MainActor is the default.
//

import ManagedSettings
import ManagedSettingsUI
import UIKit
import os

nonisolated final class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        // iOS calls this when the user opens a shielded app — the one
        // moment we can attribute a block to a specific app. Tally it so
        // the host's "most blocked" tile ranks what you actually hit.
        if let token = application.token { AppBlockTally.recordOpen(token: token) }
        return makeConfiguration(name: application.localizedDisplayName)
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        // Same per-open attribution when the app was shielded via a
        // category selection. Only one of the two app callbacks fires per
        // open, so this never double-counts.
        if let token = application.token { AppBlockTally.recordOpen(token: token) }
        return makeConfiguration(name: application.localizedDisplayName)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration(name: webDomain.domain)
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration(name: webDomain.domain)
    }

    private func makeConfiguration(name: String?) -> ShieldConfiguration {
        let stateRead = ShieldState.read()
        let state = stateRead ?? .fallback
        Logger.shieldExt.info("Shield: agent=\(state.agent.rawValue) title=\(state.title ?? "nil")")

        // Layout, given iOS's 4 slots (icon, title, subtitle, button):
        //  - icon     : host-rendered mascot
        //  - title    : push displayTitle in fg (white on dark)
        //  - subtitle : push body (already markdown-stripped on the host)
        //               in fgMute (gray)
        //  - button   : "Close" in accent
        let displayName = name ?? "this app"
        let titleText = state.title ?? "Stay focused"
        let subtitleText = state.body ?? "Vibez is keeping you off \(displayName)."

        // Icon comes from the host-pre-rendered per-agent PNG — Claude
        // pixel critter or Codex logo, picked by the agent that engaged
        // the shield. Rendered once in ScreenTimeManager.init, so both
        // the host and VibezPushService (NSE) can engage the shield
        // without doing any rendering at engagement time.
        let icon: UIImage? = loadCachedShieldImage(for: state.agent)
        Logger.shieldExt.info("Icon: \(icon == nil ? "none" : "loaded") agent=\(state.agent.rawValue)")

        // No blur — backgroundColor is the tamed-down agent tint (warm
        // brown for Claude, cool navy for Codex).
        return ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: state.backgroundUIColor,
            icon: icon,
            title: ShieldConfiguration.Label(
                text: titleText,
                color: state.fgUIColor
            ),
            subtitle: ShieldConfiguration.Label(
                text: subtitleText,
                color: state.fgMuteUIColor
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Close",
                color: .white
            ),
            primaryButtonBackgroundColor: state.accentUIColor,
            secondaryButtonLabel: nil
        )
    }

    private func loadCachedShieldImage(for agent: Agent) -> UIImage? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return nil }
        // Only the Claude and Codex cards are pre-rendered. Untagged
        // pings (both/none) — and a missing Codex render (host hasn't
        // relaunched since the update that introduced it) — fall back
        // to the Claude card; text-only shield only if that's gone too.
        if agent == .codex,
           let codex = UIImage(contentsOfFile:
               containerURL.appendingPathComponent("shield-codex.png").path) {
            return codex
        }
        let claudeURL = containerURL.appendingPathComponent("shield-claude.png")
        return UIImage(contentsOfFile: claudeURL.path)
    }
}
