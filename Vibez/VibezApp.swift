//
//  VibezApp.swift
//  Vibez
//

import SwiftUI
import UserNotifications

@main
struct VibezApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.migrateBlockSecondsKey()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    /// One-shot migration: split the legacy single `vibez.blockSeconds`
    /// (1800 default) into separate needs-input + done keys, seeding
    /// both from the previous value. Reads UserDefaults directly so we
    /// don't register a SwiftUI dependency on a key we're about to
    /// delete.
    private static func migrateBlockSecondsKey() {
        let defaults = UserDefaults.standard
        let legacyKey = "vibez.blockSeconds"
        guard let legacy = defaults.object(forKey: legacyKey) as? Int else { return }
        if defaults.object(forKey: "vibez.blockSeconds.needsInput") == nil {
            defaults.set(legacy, forKey: "vibez.blockSeconds.needsInput")
        }
        if defaults.object(forKey: "vibez.blockSeconds.done") == nil {
            defaults.set(legacy, forKey: "vibez.blockSeconds.done")
        }
        defaults.removeObject(forKey: legacyKey)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Show local notifications even when the app is in the foreground.
    // Without this, ntfy pings are swallowed silently while you're looking
    // at Vibez — defeats the whole point.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
