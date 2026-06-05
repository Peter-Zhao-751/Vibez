//
//  VibezApp.swift
//  Vibez
//

import FirebaseCore
import FirebaseMessaging
import OSLog
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

    private let pushLog = Logger(subsystem: "vibezlol.Vibez", category: "Push")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configure Firebase before anything else — FCM/Firestore/Functions
        // calls below all assume the default app is initialized.
        FirebaseApp.configure()

        UNUserNotificationCenter.current().delegate = self

        // PushTokenRegistrar is the FCM MessagingDelegate; touching shared
        // here installs it so iOS can deliver the registration token as
        // soon as APN→FCM exchange completes.
        Messaging.messaging().delegate = PushTokenRegistrar.shared

        // Touch the singleton eagerly so it exists by the time a remote
        // push arrives — even on a background launch where SwiftUI views
        // haven't been instantiated yet.
        _ = NotifyClient.shared

        // Ask iOS for an APN device token. Requires the Push Notifications
        // capability to be enabled in Signing & Capabilities; without it
        // this no-ops and didFailToRegisterForRemoteNotifications fires.
        application.registerForRemoteNotifications()

        // If we were launched directly from a remote push tap, process the
        // payload now so the shield extension can read fresh state on the
        // next tap.
        if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            NotifyClient.shared.acceptPushUserInfo(userInfo)
        }
        return true
    }

    // MARK: - Remote-notification registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        pushLog.info("APN device token: \(hex, privacy: .public)")
        // Stash the most recent token in the App Group so the host UI
        // (Settings or a debug screen) can surface it for copy-paste into
        // the Mac-side push sender.
        UserDefaults(suiteName: "group.vibezlol.Vibez")?
            .set(hex, forKey: "apnDeviceToken")

        // Hand the raw APN token to FCM. This is what triggers FCM to
        // mint (or refresh) the registration token that gets pushed back
        // to us via MessagingDelegate.messaging(_:didReceiveRegistrationToken:).
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushLog.error("APN registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Receiving remote notifications

    /// Called when a remote push arrives while the app is suspended /
    /// backgrounded (content-available wakes the app to deliver here).
    /// Foreground alert pushes go through `willPresent` below instead —
    /// iOS 16+ does NOT reliably call this method for foreground alert
    /// pushes, even with content-available:1 in the payload. Gating on
    /// applicationState != .active makes the two delegates mutually
    /// exclusive so we don't double-process.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let keys = userInfo.keys.map { String(describing: $0) }.joined(separator: ",")
        let apsAlert = ((userInfo["aps"] as? [String: Any])?["alert"])
            as? [String: Any]
        let pushTitle = (apsAlert?["title"] as? String)
            ?? (userInfo["title"] as? String) ?? "(no title)"
        let event = (userInfo["event"] as? String) ?? "(no event)"
        let shield = (userInfo["shield"] as? String) ?? "(no shield)"
        let session = (userInfo["session"] as? String) ?? "(no session)"
        let agent = (userInfo["agent"] as? String) ?? "(no agent)"
        let summary = "keys=[\(keys)] title=\(pushTitle) event=\(event) shield=\(shield) session=\(session) agent=\(agent) appState=\(application.applicationState.rawValue)"
        pushLog.info("didReceiveRemoteNotification: \(summary, privacy: .public)")

        // willPresent only fires for ALERT pushes. shield:off is sent
        // as a silent push (no aps.alert), so it has no willPresent
        // path — didReceive is its only entry point, foreground OR
        // background. The earlier blanket `applicationState == .active`
        // gate was dropping foreground silent pushes entirely, which
        // is why replying in the agent never lifted the shield while
        // Vibez was open. Only skip when there's also an alert payload
        // (the case willPresent actually handles).
        let aps = userInfo["aps"] as? [String: Any]
        let hasAlert = aps?["alert"] != nil
        if application.applicationState == .active && hasAlert {
            pushLog.info("didReceiveRemoteNotification: foreground alert — willPresent owns this path")
            completionHandler(.noData)
            return
        }

        NotifyClient.shared.acceptPushUserInfo(userInfo)
        completionHandler(.newData)
    }

    // Foreground push entry point. iOS 16+ routes foreground alert
    // pushes through this delegate, NOT through
    // didReceiveRemoteNotification, regardless of content-available.
    // So this is where we have to fish the userInfo out and feed it to
    // NotifyClient — otherwise handleIncoming never runs, no shield, no
    // trigger row (only the iOS auto-banner shows, which is exactly the
    // symptom that kept coming back after the ntfy → FCM migration).
    //
    // We also suppress iOS's auto-banner for remote pushes (return [])
    // so handleIncoming can apply its armed/ignored gating and raise
    // the user-visible banner itself via scheduleLocalNotification
    // (with markdown stripped). Local notifications (the ones the app
    // itself raises) have no "aps" key and pass through unchanged.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var userInfo = notification.request.content.userInfo
        if userInfo["aps"] != nil {
            pushLog.info("willPresent: remote push, routing to NotifyClient + suppressing iOS banner")
            // Tag the userInfo with the system's request identifier so
            // processIfNew can dedupe this foreground delivery against
            // a later drain of the NSE-written last-message.json — both
            // see the same id and the overlay isn't re-enqueued every
            // time the app comes back to foreground.
            userInfo["id"] = notification.request.identifier
            NotifyClient.shared.acceptPushUserInfo(userInfo)
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .list])
    }
}
