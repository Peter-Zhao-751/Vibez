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

    /// Called when a remote push arrives while the app is in foreground OR
    /// background (the latter only when `content-available: 1` is set in
    /// the payload and `remote-notification` is in UIBackgroundModes).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let keys = userInfo.keys.map { String(describing: $0) }.joined(separator: ",")
        let title = (userInfo["title"] as? String) ?? "(no title)"
        let event = (userInfo["event"] as? String) ?? "(no event)"
        let shield = (userInfo["shield"] as? String) ?? "(no shield)"
        let session = (userInfo["session"] as? String) ?? "(no session)"
        let agent = (userInfo["agent"] as? String) ?? "(no agent)"
        let summary = "keys=[\(keys)] title=\(title) event=\(event) shield=\(shield) session=\(session) agent=\(agent)"
        pushLog.info("Remote push received: \(summary, privacy: .public)")
        NotifyClient.shared.acceptPushUserInfo(userInfo)

        // [debug] Diagnostic local notification — proves the FCM path
        // reached the AppDelegate, independent of whatever
        // ContentView.handleIncoming decides to do with the message.
        // Remove (or gate behind a build flag) once push delivery is
        // confirmed solid end to end.
        let content = UNMutableNotificationContent()
        content.title = "[debug] Received"
        content.body = "event=\(event) shield=\(shield)"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        ) { _ in }

        // .newData tells iOS we did meaningful work — improves the chance
        // of getting future silent pushes delivered promptly.
        completionHandler(.newData)
    }

    // Foreground display gate. Remote pushes carry "aps" in userInfo —
    // we suppress those so iOS doesn't auto-banner before
    // ContentView.handleIncoming has a chance to run its armed /
    // shield / ignored gating. Local notifications (the ones the app
    // itself raises via NotifyClient.scheduleLocalNotification when
    // handleIncoming decides a banner is appropriate) have no "aps"
    // key, so they pass through and display normally. Matches the
    // pre-FCM ntfy WebSocket behavior: app code, not iOS, owns
    // foreground visibility.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if userInfo["aps"] != nil {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .list])
    }
}
