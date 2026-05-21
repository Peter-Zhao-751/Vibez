//
//  ShieldConfigurationExtension.swift
//  VibezShield
//
//  Replaces iOS's default "App is Restricted, OK" shield. Reads the
//  latest ShieldState from the App Group, rasterizes a SwiftUI
//  ShieldCard to a UIImage via ImageRenderer, and returns a
//  ShieldConfiguration whose icon slot carries the whole visual.
//
//  iOS's surrounding title/subtitle text are intentionally nil so
//  the rendered card is the focus; the primary "Close" button
//  remains to give the user a way out.
//

import ManagedSettings
import ManagedSettingsUI
import SwiftUI
import UIKit
import os

nonisolated final class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(
        shielding application: Application,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(
        shielding webDomain: WebDomain,
        in category: ActivityCategory
    ) -> ShieldConfiguration {
        makeConfiguration()
    }

    private func makeConfiguration() -> ShieldConfiguration {
        let state = ShieldState.read() ?? .fallback
        Logger.shieldExt.info("Shield: agent=\(state.agent.rawValue) title=\(state.title ?? "nil")")

        return MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: ShieldCard(state: state))
            renderer.scale = UIScreen.main.scale
            renderer.proposedSize = ProposedViewSize(width: 360, height: 540)

            return ShieldConfiguration(
                backgroundBlurStyle: .systemThickMaterial,
                backgroundColor: state.dark
                    ? UIColor(red: 0.047, green: 0.051, blue: 0.071, alpha: 1)
                    : UIColor(red: 0.984, green: 0.973, blue: 0.957, alpha: 1),
                icon: renderer.uiImage,
                title: nil,
                subtitle: nil,
                primaryButtonLabel: ShieldConfiguration.Label(
                    text: "Close", color: .white
                ),
                primaryButtonBackgroundColor: state.accentUIColor,
                secondaryButtonLabel: nil
            )
        }
    }
}
