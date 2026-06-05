//
//  ContentView+Home.swift
//  Vibez
//
//  The home screen's layout half of ContentView: top bar + glow, the
//  mascot hero, the big toggle, the setup card, and the Recent triggers
//  sheet — plus the focus-mode tap flow and its app-picker detour.
//  Push routing lives in ContentView+Incoming.swift; shared state in
//  ContentView.swift.
//

import SwiftUI
import FamilyControls
import UIKit

extension ContentView {

    @ViewBuilder
    var mainScreen: some View {
        VStack(spacing: 0) {
            TopBar(
                theme: theme,
                onOpenSettings: { showSettings = true }
            )

            homeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Color.clear
                .frame(height: RecentTriggersLayout.collapsedReserveHeight)
        }
    }

    /// Static top accent glow — fades in while armed. The reference's
    /// `radial-gradient(ellipse 80% 60% at 50% 0%)` over a 360pt strip
    /// that bleeds 120pt above the viewport.
    var topGlow: some View {
        Ellipse()
            .fill(
                // EllipticalGradient stretches its falloff to the wide,
                // short frame — matching the reference's anisotropic
                // `ellipse 80% 60%` rather than a circular fade.
                EllipticalGradient(
                    stops: [
                        .init(
                            color: theme.accent.opacity(effectiveDark ? 0.18 : 0.125),
                            location: 0
                        ),
                        .init(color: .clear, location: 0.7),
                    ],
                    center: .top
                )
            )
            .frame(height: 360)
            .padding(.horizontal, -40)
            // Anchor to the physical screen top (not the safe area),
            // then bleed 120pt above it — the reference's `top: -120`.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(y: -120)
            .ignoresSafeArea()
            .opacity(manager.armed ? 1 : 0)
            .animation(.easeInOut(duration: 0.5), value: manager.armed)
            .allowsHitTesting(false)
    }

    var recentTriggersSheet: some View {
        RecentTriggersSection(
            events: triggerStore.events,
            theme: theme,
            ignoreStore: ignoreStore,
            onIgnoreSession: { event in
                guard let sid = event.sessionId else { return }
                let name = displayName(for: event)
                ignoreStore.ignoreSession(sessionId: sid, name: name)
            },
            onIgnoreName: { event in
                let name = displayName(for: event)
                ignoreStore.ignoreName(name)
            },
            onUnignoreSession: { event in
                guard let sid = event.sessionId,
                      let rule = ignoreStore.sessionRuleMatching(sessionId: sid)
                else { return }
                ignoreStore.remove(ruleId: rule.id)
            },
            onUnignoreName: { event in
                let name = displayName(for: event)
                guard let rule = ignoreStore.nameRuleMatching(name: name)
                else { return }
                ignoreStore.remove(ruleId: rule.id)
            }
        )
    }

    /// Best display name for an ignore rule sourced from a Recent
    /// triggers row. Title wins; falls back to the body label so older
    /// title-less events still produce a usable rule.
    private func displayName(for event: TriggerEvent) -> String {
        if let t = event.title, !t.isEmpty { return t }
        return event.label
    }

    /// Tapping the locked toggle: shake the toggle first, then the
    /// setup card a beat later, so the eye is led from "this didn't
    /// work" to "fix it here." Delay is a hair shorter than the toggle
    /// shake so the two feel like one continuous gesture.
    private func bounceToShowSetup() {
        toggleShake &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            setupShake &+= 1
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            // mainScreen ignores the bottom safe area, so the reserve
            // spacer below this view ends at the physical screen bottom —
            // our bottom edge plus the reserve is the screen height.
            let screenHeight = frame.maxY + RecentTriggersLayout.collapsedReserveHeight
            // Rest the toggle's center on the screen's vertical center.
            // BigToggle keeps a constant pillH-tall layout box through the
            // focus-banner morph, so the center holds in focus mode too.
            let toggleCenterY = screenHeight / 2 - frame.minY
            let topSpacer = max(
                0,
                toggleCenterY - BigToggle.pillH / 2 - Self.heroToggleGap - heroHeight
            )

            VStack(spacing: 0) {
                if unlockedLayoutExpanded {
                    Spacer()
                        .frame(height: topSpacer)
                }

                hero
                    .padding(.top, unlockedLayoutExpanded ? 0 : 8)

                BigToggle(
                    enabled: Binding(
                        get: { manager.armed && !setupNeeded },
                        set: { manager.setArmed($0) }
                    ),
                    theme: theme,
                    isInteractive: !registrar.vibezId.isEmpty,
                    focusMode: manager.focusMode,
                    onLockedTap: bounceToShowSetup,
                    onReleaseFocus: { toggleFocusMode() }
                )
                .padding(.top, unlockedLayoutExpanded ? Self.heroToggleGap : 14)
                .padding(.bottom, unlockedLayoutExpanded ? 0 : 14)
                .shake(trigger: toggleShake)

                if setupCardMounted {
                    VibezSetupCard(
                        registrar: registrar,
                        theme: theme
                    )
                    .opacity(setupCardVisible ? 1 : 0)
                    .allowsHitTesting(setupCardVisible)
                    .accessibilityHidden(!setupCardVisible)
                    .padding(.top, 18)
                    .shake(trigger: setupShake, amount: 5, duration: 0.84)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    /// VStack spacing between the mascot frame and the hint. Negative:
    /// the mascot frames carry empty space below the feet, so the hint
    /// is pulled up into it to sit close under the mascot.
    private static let captionGap: CGFloat = -6
    /// Fixed hint line height so the hero's height is deterministic.
    private static let captionHeight: CGFloat = 12

    /// Vertical air between the hero and the toggle — lifts the mascot
    /// clear of the screen-centered toggle. The hero is bottom-anchored
    /// against this gap, so shrinking it drops mascot + hint together.
    private static let heroToggleGap: CGFloat = 26

    /// Mascot + focus halo + the "tap to enter focus mode" hint.
    /// Desaturated and dimmed while disarmed; tapping toggles a manual
    /// focus hold. Mascot and hint live in the SAME stack: every move,
    /// size change, and filter applies to both as one rigid unit. The
    /// hint is always rendered (visibility is opacity-only), so the
    /// stack's height never changes and the hint can't pop in late.
    private var hero: some View {
        VStack(spacing: showFocusHint ? Self.captionGap : 0) {
            ClaudeMascot(
                listening: manager.armed,
                size: mascotSize,
                focused: manager.focusMode,
                // The reference hero passes animate={false} — no body
                // bob on the home screen; eyes still cycle.
                animate: false
            )
            // The halo is decoration behind the mascot — .background so
            // its 1.9× footprint never inflates the hero's layout.
            .background {
                if manager.focusMode {
                    FocusHalo(color: theme.accent, size: mascotSize * 1.9)
                }
            }
            // Hint hidden → drop the mascot by half the hint's height vs
            // the shown layout. Shown below-mascot space is
            // captionGap + captionHeight; removing captionHeight/2 of it
            // lowers the mascot by that much.
            .padding(.bottom, showFocusHint ? 0 : Self.captionGap + Self.captionHeight / 2)

            if showFocusHint {
                Text("tap to enter focus mode")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(theme.fgMute)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: Self.captionHeight)
                    // Scoped form on purpose: .animation(_:value:) would
                    // re-time EVERY animatable property of the text — the
                    // parent-assigned position included — whenever
                    // captionVisible flips inside a layout move (pairing
                    // expansion), detaching the hint from the mascot. This
                    // animates the fade and nothing else; geometry rides
                    // the same transaction as the rest of the hero.
                    .animation(.easeInOut(duration: 0.3)) { content in
                        content.opacity(captionVisible ? 1 : 0)
                    }
                    .accessibilityHidden(!captionVisible)
            }
        }
        .saturation(manager.armed ? 1 : 0.12)
        .brightness(manager.armed ? 0 : -0.08)
        .opacity(manager.armed ? 1 : 0.7)
        .animation(.easeInOut(duration: 0.5), value: manager.armed)
        .contentShape(Rectangle())
        .onTapGesture { toggleFocusMode() }
    }

    /// Hint visibility: paired (animated layout state, so show/hide
    /// rides the same transactions that move the mascot), armed (toggle
    /// off → invisible), and not already in focus mode.
    private var captionVisible: Bool {
        unlockedLayoutExpanded && manager.armed && !manager.focusMode
    }

    /// The hero's layout height — the mascot frame plus the
    /// always-rendered hint row. Deterministic, no measurement needed.
    private var heroHeight: CGFloat {
        let mascotFrame = mascotSize * 0.9   // viewBox 100×90
        // Mirror the `hero` layout: with the hint, the full caption row
        // (negative gap + caption height); without it, that same space
        // minus half the caption height — so the mascot sits half a
        // text-height lower when the hint is gone.
        let belowMascot = showFocusHint
            ? Self.captionGap + Self.captionHeight
            : Self.captionGap + Self.captionHeight / 2
        return mascotFrame + belowMascot
    }

    /// Tap the mascot to start/stop a manual focus hold. Only meaningful
    /// while armed. With no apps selected, open the system app picker
    /// directly (an empty shield would block nothing) and engage focus
    /// once the user has picked something — see `pickAppsThenFocus`.
    private func toggleFocusMode() {
        guard manager.armed else { return }
        guard manager.hasSelection else {
            pickAppsThenFocus()
            return
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            manager.setFocusMode(!manager.focusMode)
        }
    }

    /// Present the FamilyActivityPicker seeded with the current
    /// selection (expanded so a category pick returns its member apps).
    /// `focusAfterPick` flags that this was a focus-mode tap, so the
    /// picker's dismiss handler can engage focus once apps land.
    private func pickAppsThenFocus() {
        draftSelection = manager.selection.expandingCategories
        focusAfterPick = true
        pickerPresented = true
    }

    /// Persist the picker result and, if it was opened by a focus tap
    /// and apps are now selected, engage focus mode. Mirrors the
    /// save-only-real-edits logic in SettingsView so a cancelled picker
    /// doesn't flip the includeEntireCategory flag and hide icons.
    func handlePickerDismiss() {
        let wantsFocus = focusAfterPick
        focusAfterPick = false

        let unchanged = draftSelection.applicationTokens == manager.selection.applicationTokens
            && draftSelection.categoryTokens == manager.selection.categoryTokens
            && draftSelection.webDomainTokens == manager.selection.webDomainTokens
        if !unchanged {
            manager.updateSelection(draftSelection)
        }

        if wantsFocus && manager.armed && manager.hasSelection && !manager.focusMode {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                manager.setFocusMode(true)
            }
        }
    }

    private var mascotSize: CGFloat {
        unlockedLayoutExpanded ? 140 : 100
    }
}
