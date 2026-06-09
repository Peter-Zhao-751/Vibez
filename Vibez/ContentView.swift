//
//  ContentView.swift
//  Vibez
//
//  Home-screen root: the shared state, the scene-lifecycle plumbing,
//  and the setup-card presentation dance. The rest of the screen lives
//  in sibling files:
//    ContentView+Home.swift      — hero, big toggle, home layout
//    ContentView+Incoming.swift  — push routing + the overlay queue
//    ContentView+Previews.swift  — seeded preview environments
//    OnboardingLaunchGate.swift  — cold-launch onboarding cover
//
//  Members shared with those extensions are internal (not private) on
//  purpose — Swift's `private` is file-scoped.
//

import SwiftUI
import FamilyControls

struct ContentView: View {
    @State var manager: ScreenTimeManager
    // @State-wrapped on purpose. With a plain `private let`, SwiftUI
    // doesn't reliably hook the @Observable into this view's render
    // dependency graph, so .onChange(of: notifyClient.lastMessage)
    // silently stops firing and handleIncoming never runs. @State on
    // an @Observable singleton is the canonical pattern.
    @State var notifyClient: NotifyClient
    @State var registrar: PushTokenRegistrar
    @State var triggerStore: TriggerStore
    @State var ignoreStore: IgnoreStore
    @State var analytics: AnalyticsTracker
    @State var reviewPrompt: ReviewPromptManager

    @MainActor
    init(
        manager: ScreenTimeManager? = nil,
        notifyClient: NotifyClient? = nil,
        registrar: PushTokenRegistrar? = nil,
        triggerStore: TriggerStore? = nil,
        ignoreStore: IgnoreStore? = nil,
        analytics: AnalyticsTracker? = nil,
        reviewPrompt: ReviewPromptManager? = nil
    ) {
        // Default-arg expressions evaluate at the caller's isolation, so
        // any defaults that touch @MainActor types (the whole project,
        // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor) have to be built inside
        // this @MainActor body instead.
        // .shared for the singletons so AppDelegate / NotifyClient and
        // this view operate on the same state. Previews pass explicit
        // instances and remain isolated from prod.
        let reg = registrar ?? .shared
        _manager = State(initialValue: manager ?? .shared)
        _notifyClient = State(initialValue: notifyClient ?? .shared)
        _registrar = State(initialValue: reg)
        _triggerStore = State(initialValue: triggerStore ?? TriggerStore())
        _ignoreStore = State(initialValue: ignoreStore ?? .shared)
        _analytics = State(initialValue: analytics ?? .shared)
        _reviewPrompt = State(initialValue: reviewPrompt ?? .shared)
        // Seed the setup-presentation layout from the live pairing state
        // so frame 1 already shows the right arrangement. Hardcoded
        // "setup card up, layout compact" defaults forced a paired cold
        // start through a one-frame reflow in .onAppear — the mascot
        // snapped to center invisibly, but the hint rode its private
        // caption animation through the move and visibly slid in from
        // above, out of sync with the mascot.
        let needsSetup = Self.setupNeeded(for: reg)
        _setupCardMounted = State(initialValue: needsSetup)
        _setupCardVisible = State(initialValue: needsSetup)
        _unlockedLayoutExpanded = State(initialValue: !needsSetup)
    }

    @AppStorage("vibez.appearance") private var appearanceRaw = AppearancePref.system.rawValue
    @AppStorage("vibez.blockSeconds.needsInput") var blockSecondsNeedsInput = 900
    @AppStorage("vibez.blockSeconds.done") var blockSecondsDone = 30
    @AppStorage("vibez.overlayOrder") private var overlayOrderRaw = OverlayOrder.stack.rawValue
    @AppStorage("vibez.allowDismiss") private var allowDismiss = true
    /// Whether agent pings surface as an OS banner + sound. When off,
    /// blocks still engage; the push just arrives silently (passive) in
    /// Notification Center. Mirrored to the App Group by ScreenTimeManager
    /// so VibezPushService honors it on the background path too.
    @AppStorage("vibez.notifyBanners") var notifyBanners = true
    /// Whether the "tap to enter focus mode" hint shows under the mascot.
    /// Off → the hint is removed (not just faded) and the hero keeps half
    /// the hint's height as padding so the mascot doesn't drop all the way
    /// onto the toggle's gap. Default on. Mirrored in SettingsView.
    @AppStorage("vibez.showFocusHint") var showFocusHint = true
    /// Whether the accent gradient flourishes render: the drifting
    /// background bubbles (ActiveBackdrop), the toggle's colored glow, and
    /// the halo behind the mascot in focus mode (FocusHalo). Off → a flat,
    /// glow-free home screen. Default on. Mirrored in SettingsView.
    @AppStorage("vibez.gradientEffects") var gradientEffects = true

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State var overlayQueue: [NtfyMessage] = []   // order depends on overlayOrder — see enqueueOverlay
    @State var showSettings = false
    /// Drives the automatic "Rate Vibez" sheet (post-dismiss eligibility).
    @State var showReviewPrompt = false
    /// Drives the system app picker presented straight from the mascot
    /// tap when no apps are selected yet (instead of bouncing to
    /// Settings). See `toggleFocusMode` / `pickAppsThenFocus`.
    @State var pickerPresented = false
    @State var draftSelection = FamilyActivitySelection()
    /// True while the picker was opened by a focus-mode tap, so once the
    /// user actually selects apps we engage focus mode for them rather
    /// than making them tap the mascot a second time.
    @State var focusAfterPick = false
    @State var toggleShake = 0
    @State var setupShake = 0
    // Seeded in init from the pairing state — see the note there.
    @State var setupCardMounted: Bool
    @State var setupCardVisible: Bool
    @State var unlockedLayoutExpanded: Bool
    @State private var setupTransitionGeneration = 0
    /// Tracks which incoming push id we've already routed through
    /// handleIncoming. Needed because SwiftUI's .onChange doesn't fire
    /// for changes that landed while the view wasn't actively observing
    /// (e.g. push processed by AppDelegate while the app was suspended).
    /// Pair with .onAppear so a push seen during background-wake gets
    /// reprocessed once the view comes back.
    @State var lastProcessedMessageId: String?

    private var appearance: AppearancePref {
        AppearancePref(rawValue: appearanceRaw) ?? .system
    }

    var effectiveDark: Bool {
        appearance.effectiveDark(systemIsDark: systemColorScheme == .dark)
    }

    var theme: Theme {
        Theme.make()
    }

    private var topOverlayMessage: NtfyMessage? { overlayQueue.first }

    var overlayOrder: OverlayOrder {
        OverlayOrder(rawValue: overlayOrderRaw) ?? .stack
    }

    var setupNeeded: Bool {
        Self.setupNeeded(for: registrar)
    }

    /// Show the setup card only when there's nothing to work with or
    /// something actually failed: no Vibez ID yet, or the backend
    /// rejected the registration. Transient in-flight states (waiting
    /// for the FCM token, registering) keep the home unlocked — the
    /// card would otherwise flash on every cold launch while the
    /// stored ID re-registers. Static so init can seed the layout
    /// state from the same rule before the first render.
    private static func setupNeeded(for registrar: PushTokenRegistrar) -> Bool {
        if registrar.vibezId.isEmpty { return true }
        if case .error = registrar.state { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.bg
                .ignoresSafeArea()

            topGlow

            ActiveBackdrop(accent: theme.accent, active: manager.armed && gradientEffects)
                .ignoresSafeArea()

            mainScreen
                .ignoresSafeArea(edges: .bottom)

            recentTriggersSheet
                .ignoresSafeArea(edges: .bottom)
                .zIndex(2)

            if let msg = topOverlayMessage {
                BlockedOverlay(
                    theme: theme,
                    message: msg,
                    expiresAt: msg.sessionId.flatMap { manager.pendingTriggers[$0]?.expiresAt },
                    stackDepth: overlayQueue.count,
                    allowDismiss: allowDismiss,
                    onDismiss: dismissTopOverlay,
                    onExpire: expireTopOverlay
                )
                .id(msg.id)
                .transition(.opacity)
                .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: effectiveDark)
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "vibez.debug.seedReviewOverlay") {
                reviewPrompt.debugSeedEligible()
                var fake = NtfyMessage(
                    id: "debug-review-overlay",
                    title: "Debug block",
                    body: "Tap Dismiss to test the review prompt.",
                    receivedAt: Date()
                )
                fake.shield = .on
                overlayQueue = [fake]
                // Headless verification seam (no sim tap tooling): drive the
                // real dismiss path so maybePromptForReview → sheet can be
                // screenshotted. The Dismiss-button → dismissTopOverlay
                // wiring itself is pre-existing and unchanged.
                if UserDefaults.standard.bool(forKey: "vibez.debug.autoDismissReview") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismissTopOverlay() }
                }
            }
            #endif
            syncSetupPresentation(animated: false)
            // Keep the shield card's light/dark in step with the app's
            // effective appearance before draining a push that writes
            // shield state.
            manager.updateEffectiveAppearance(dark: effectiveDark)
            // Catch pushes that landed via AppDelegate while the view
            // wasn't actively observing — .onChange below won't fire
            // for those because the value was set before subscription.
            // Also drain any NSE-written push file from the App Group
            // so background-engaged blocks get an in-app overlay on
            // first launch / cold start (not just on subsequent
            // scenePhase transitions). Reload pendingTriggers *first*
            // so handleIncoming (and subsequent user actions like
            // Dismiss) see the NSE-added trigger instead of a stale
            // empty in-memory dict.
            manager.reloadFromAppGroup()
            notifyClient.drainPendingPushFromAppGroup()
            processIfNew(notifyClient.lastMessage)
            // Notifications off → sweep Notification Center clear. The NSE
            // keeps it down to a single passive straggler while we're
            // suspended; this drops that last one now that we're running.
            // Banners on → still mop up stale shield:off control entries
            // ("Replied" pings, timeout unblocks): the newest one always
            // outlives the NSE's sweep because it files in after the NSE
            // ran, so only a later sweep — this one — can drop it.
            if !notifyBanners {
                notifyClient.clearAllDeliveredNotifications()
            } else {
                notifyClient.clearStaleDeliveredNotifications()
            }
        }
        .onChange(of: setupNeeded) { _, _ in
            syncSetupPresentation(animated: true)
        }
        .onChange(of: effectiveDark) { _, newDark in
            // Appearance flipped while running (picker change or a live
            // system light/dark switch) — keep the shield card in step.
            manager.updateEffectiveAppearance(dark: newDark)
        }
        .onChange(of: notifyClient.lastMessage) { _, newValue in
            processIfNew(newValue)
        }
        // Catch the case where a push arrived while the scene was
        // suspended: didReceiveRemoteNotification updated lastMessage
        // in the background, but SwiftUI's .onChange isn't guaranteed
        // to fire for value changes that happened while the view was
        // not actively observing. .onAppear above only fires on first
        // appearance — not on resume — so without this, opening the
        // app via the icon (not the banner tap) leaves the trigger /
        // shield in stale state.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                manager.updateEffectiveAppearance(dark: effectiveDark)
                // Drain anything the NSE wrote to the App Group while
                // we were suspended before processing — this sets
                // lastMessage to the most recent NSE-handled push so
                // handleIncoming can enqueue its overlay. Reload
                // pendingTriggers first so user-driven actions (Dismiss)
                // see the NSE-added trigger instead of an empty cache.
                manager.reloadFromAppGroup()
                notifyClient.drainPendingPushFromAppGroup()
                processIfNew(notifyClient.lastMessage)
                // Notifications off → drop the lone passive straggler the
                // NSE leaves behind (it runs before that entry posts).
                // Banners on → mop up stale shield:off control entries the
                // NSE's sweep can't reach (each files in after it ran).
                if !notifyBanners {
                    notifyClient.clearAllDeliveredNotifications()
                } else {
                    notifyClient.clearStaleDeliveredNotifications()
                }
            }
        }
        .onChange(of: manager.pendingTriggers) { _, newPending in
            // A non-top entry's per-session timer expired in the
            // background. Drop those queue entries so popping the top
            // doesn't reveal a stale entry that would immediately fire
            // onExpire. Untagged pings (nil sessionId) aren't reconciled
            // — they have no backing trigger and are removed only by
            // the Dismiss button.
            overlayQueue.removeAll { msg in
                guard let sid = msg.sessionId, sid.isUsableSessionId
                else { return false }
                return newPending[sid] == nil
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            // Push any block-duration edits to the server so it
            // schedules timeout unblocks with the latest values;
            // reregister() re-reads them from UserDefaults. Design
            // spec §1. Lives here (not on the sheet's Done button)
            // so swipe-down dismissals push edits too.
            Task { await registrar.reregister() }
        }) {
            SettingsView(
                isPresented: $showSettings,
                manager: manager,
                notifyClient: notifyClient,
                registrar: registrar,
                triggerStore: triggerStore,
                ignoreStore: ignoreStore,
                reviewPrompt: reviewPrompt
            )
        }
        .sheet(isPresented: $showReviewPrompt) {
            PleaseReviewView(
                onClose: { showReviewPrompt = false },
                onRated: { reviewPrompt.markRated() }
            )
            .presentationDragIndicator(.visible)
        }
        // Cold-launch onboarding decision + the fullScreenCover live in
        // OnboardingLaunchGate.swift.
        .onboardingLaunchGate(manager: manager, registrar: registrar)
        .familyActivityPicker(
            isPresented: $pickerPresented,
            selection: $draftSelection
        )
        .onChange(of: pickerPresented) { _, presented in
            if !presented { handlePickerDismiss() }
        }
    }

    /// The setup card owns enough height that removing it and expanding
    /// the unlocked layout in one animation looks like a jump. Fade the
    /// card first while it still occupies space; then, a beat later,
    /// let the mascot grow and move the controls down toward the sheet.
    private func syncSetupPresentation(animated: Bool) {
        setupTransitionGeneration &+= 1
        let generation = setupTransitionGeneration

        if setupNeeded {
            if animated {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                    unlockedLayoutExpanded = false
                    setupCardMounted = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    guard generation == setupTransitionGeneration, setupNeeded else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        setupCardVisible = true
                    }
                }
            } else {
                unlockedLayoutExpanded = false
                setupCardMounted = true
                setupCardVisible = true
            }
        } else {
            if animated {
                withAnimation(.easeInOut(duration: 0.44)) {
                    setupCardVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) {
                    guard generation == setupTransitionGeneration, !setupNeeded else { return }
                    withAnimation(.spring(response: 0.58, dampingFraction: 0.86)) {
                        setupCardMounted = false
                        unlockedLayoutExpanded = true
                    }
                }
            } else {
                setupCardVisible = false
                setupCardMounted = false
                unlockedLayoutExpanded = true
            }
        }
    }
}
