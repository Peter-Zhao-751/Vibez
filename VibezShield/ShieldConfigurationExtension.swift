//
//  ShieldConfigurationExtension.swift
//  VibezShield
//
//  Replaces iOS's default "App is Restricted, OK" shield. Reads the
//  latest ShieldState from the App Group and a host-rendered PNG
//  card from the App Group container. If the PNG is present, slots
//  it into ShieldConfiguration.icon for the rich visual. Otherwise
//  falls back to a Vibez-branded text-only shield.
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
        makeConfiguration(name: application.localizedDisplayName)
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration(name: application.localizedDisplayName)
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
        //  - title    : ntfy displayTitle in fg (white on dark)
        //  - subtitle : ntfy body (already markdown-stripped on the host)
        //               in fgMute (gray)
        //  - button   : "Close" in accent
        let displayName = name ?? "this app"
        let titleText = state.title ?? "Stay focused"
        let subtitleText = state.body ?? "Vibez is keeping you off \(displayName)."

        // Icon comes from the host-rendered cache when state is fresh;
        // a stale snapshot would mislead, so we skip the image then.
        let icon: UIImage? = (stateRead != nil) ? loadCachedShieldImage() : nil
        Logger.shieldExt.info("Icon: \(icon == nil ? "none" : "host-rendered")")

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

    private func loadCachedShieldImage() -> UIImage? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return nil }
        let imageURL = containerURL.appendingPathComponent("shield.png")
        return UIImage(contentsOfFile: imageURL.path)
    }
}
