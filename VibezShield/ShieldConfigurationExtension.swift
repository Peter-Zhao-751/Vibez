//
//  ShieldConfigurationExtension.swift
//  VibezShield
//
//  Replaces iOS's default "App is Restricted, OK" shield with a
//  Vibez-branded one. Same dark/orange palette as the in-app BlockedOverlay.
//

import ManagedSettings
import ManagedSettingsUI
import UIKit

// `nonisolated` because the project's SWIFT_DEFAULT_ACTOR_ISOLATION is
// MainActor, but ShieldConfigurationDataSource's overridden methods are
// `nonisolated` in the framework — keep the override actor-isolation
// matching the superclass.
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

    // Vibez accent (orange) — matches Theme.swift's claude/codex accents
    // closely enough without needing an App Group to share the live theme.
    private let vibezAccent = UIColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1.0)

    private func makeConfiguration(name: String?) -> ShieldConfiguration {
        let displayName = name ?? "this app"
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            backgroundColor: nil,
            icon: nil,
            title: ShieldConfiguration.Label(
                text: "BLOCKING IN PROGRESS",
                color: vibezAccent
            ),
            subtitle: ShieldConfiguration.Label(
                text: "Vibez is keeping you off \(displayName).\n\nOpen Vibez to check what your agent needs.",
                color: .label
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Close",
                color: .white
            ),
            primaryButtonBackgroundColor: vibezAccent,
            secondaryButtonLabel: nil
        )
    }
}
