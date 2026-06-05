//
//  ContentView+Previews.swift
//  Vibez
//
//  Preview support for the home screen. Each preview wires up a
//  fully-seeded environment so it renders as if Vibez had been running
//  for a while. Three knobs:
//    • seedAppStorageDefaults() pre-fills the agent + appearance
//      @AppStorage values.
//    • PushTokenRegistrar.previewRegistrar() bypasses the FCM round-trip
//      and pins a Vibez ID + a `.registered` state, the second half of
//      setupNeeded.
//    • ScreenTimeManager.previewManager(...) sets armed and any pending
//      triggers; the rest of the store (selection, auth) is left to the
//      real init (no-op on the simulator).
//

import SwiftUI

#Preview("bruh") {
    ContentView()
}

#if DEBUG

private func seedAppStorageDefaults(
    appearance: AppearancePref = .dark
) {
    let d = UserDefaults.standard
    d.set(appearance.rawValue, forKey: "vibez.appearance")
}

private func previewTrigger(
    minutesAgo: Int,
    source: TriggerEvent.Source,
    title: String,
    label: String,
    blockSeconds: Int = 900,
    needsReply: Bool = false,
    repliedAfterSeconds: Int? = nil
) -> TriggerEvent {
    let receivedAt = Date().addingTimeInterval(-Double(minutesAgo) * 60)
    return TriggerEvent(
        receivedAt: receivedAt,
        source: source,
        title: title,
        label: label,
        blockSeconds: blockSeconds,
        sessionId: "preview-\(UUID().uuidString.prefix(8))",
        needsReply: needsReply,
        repliedAt: repliedAfterSeconds.map { receivedAt.addingTimeInterval(Double($0)) }
    )
}

private func previewTriggerStore(events: [TriggerEvent]) -> TriggerStore {
    let store = TriggerStore()
    store.clear()
    // Insert oldest first so the resulting `events` array has newest at
    // index 0, which is the natural order downstream code expects.
    for event in events.sorted(by: { $0.receivedAt < $1.receivedAt }) {
        store.record(event)
    }
    return store
}

private let previewClaudeTitles: [(String, String)] = [
    ("Refactor blocking panel", "Wrapped the panel in a lazy stack and trimmed the unused gradient. Tests pass."),
    ("Investigate WebSocket disconnects", "Reconnect logic is dropping the second frame on iOS 17 — want me to add a retry guard?"),
    ("Ship the Q4 changelog", "Want me to bundle the design-system entries under a single section, or keep them split out?"),
    ("Wire up SSE handler", "Need confirmation before I rip out the polling fallback."),
    ("Trace the analytics rollover", "Stats persisted across midnight on the simulator — added a regression test."),
    ("Audit Vibez entitlements", "Distribution request needs the family-controls justification — should I draft the copy?"),
    ("Migrate trigger store to v2", "Old persisted events decode fine. Ready to remove the v1 fallback?"),
    ("Plan plugin distribution", "Permission required to run `npm install` in the plugin package."),
    ("Profile blocked overlay", "Time-to-first-frame dropped from 180ms to 42ms after the GeometryReader rip-out."),
    ("Fix App Group write race", "Two writers were racing on `shieldState`. Want a serial queue or a lock?"),
    ("Document hook env-var quirks", "Wrote up the `${VAR}` vs `${VAR:-fallback}` gotcha in CLAUDE.md."),
    ("Bump iOS deploy target", "Ready to set it to 17.0 and drop the availability checks?"),
]

private let previewCodexTitles: [(String, String)] = [
    ("Rescue plan: stale shield", "Manager carried `shieldApplied=true` across an unblock. Reset hook proposed."),
    ("Rebuild ShieldCard renderer", "Want me to swap ImageRenderer for a UIGraphicsImageRenderer pass?"),
    ("Diagnose push delivery timing", "Backoff was 3s flat — bumped to exponential with jitter."),
    ("Codex hook permission probe", "Need approval to write `~/.claude/hooks/`."),
    ("Sweep dead code in Components", "Found 4 unused helpers. Safe to delete?"),
    ("Audit MainActor isolation", "Three call sites missed `@MainActor`. Patch ready for review."),
    ("Verify SettingsView regression", "Toggle survived a force-quit on the simulator. Want me to add a snapshot test?"),
    ("Plan VibezShield asset sync", "Codex avatar copy step is fragile. Suggesting a build phase."),
]

@MainActor
private func previewContent(
    vibezId: String = "moss-pine-fox-jazz",
    registrarState: PushTokenRegistrar.State = .registered,
    appearance: AppearancePref = .dark,
    armed: Bool = true,
    focusMode: Bool = false,
    pendingTriggers: [PendingTrigger] = [],
    events: [TriggerEvent] = []
) -> some View {
    seedAppStorageDefaults(appearance: appearance)
    return ContentView(
        manager: ScreenTimeManager.previewManager(
            armed: armed,
            pendingTriggers: pendingTriggers,
            focusMode: focusMode
        ),
        notifyClient: NotifyClient.previewClient(),
        registrar: PushTokenRegistrar.previewRegistrar(
            vibezId: vibezId,
            state: registrarState
        ),
        triggerStore: previewTriggerStore(events: events),
        ignoreStore: IgnoreStore(),
        analytics: AnalyticsTracker()
    )
    .preferredColorScheme(appearance == .light ? .light : .dark)
}

#Preview("Paired · ready · dark") {
    // Right after the user pastes a working Vibez ID. Setup card has
    // animated out, toggle is interactive but still OFF; mascot is
    // dimmed/desaturated and the bubbles are faded. This is the
    // "everything is wired up and ready" empty state.
    previewContent(
        armed: false
    )
}

#Preview("Armed · listening · dark") {
    // Toggle flipped ON: bubbles drifting, top glow on, mascot in its
    // listening pose with the "tap to enter focus mode" hint. No pings
    // have landed yet, so the Recent triggers sheet is blank.
    previewContent(
        armed: true
    )
}

#Preview("Focus mode · dark") {
    // Armed and holding a manual focus block: squinting mascot with the
    // accent halo, and the toggle morphed into the "Focus mode — tap to
    // release" banner. No triggers — the shield is held by the tap alone.
    previewContent(
        armed: true,
        focusMode: true
    )
}

#Preview("Recent triggers · dark") {
    // A full Recent triggers list — collapsed sheet shows the top three,
    // with the rest available on expand. Mix of replied/pending and a
    // Codex row so the sheet shows both cc and cx source chips.
    let events: [TriggerEvent] = [
        previewTrigger(minutesAgo: 1,   source: .claude,
                       title: previewClaudeTitles[0].0, label: previewClaudeTitles[0].1,
                       needsReply: true),
        previewTrigger(minutesAgo: 6,   source: .claude,
                       title: previewClaudeTitles[1].0, label: previewClaudeTitles[1].1,
                       repliedAfterSeconds: 142),
        previewTrigger(minutesAgo: 22,  source: .codex,
                       title: previewCodexTitles[0].0, label: previewCodexTitles[0].1,
                       repliedAfterSeconds: 38),
        previewTrigger(minutesAgo: 41,  source: .claude,
                       title: previewClaudeTitles[2].0, label: previewClaudeTitles[2].1,
                       repliedAfterSeconds: 95),
        previewTrigger(minutesAgo: 84,  source: .claude,
                       title: previewClaudeTitles[3].0, label: previewClaudeTitles[3].1,
                       blockSeconds: 30),
        previewTrigger(minutesAgo: 132, source: .codex,
                       title: previewCodexTitles[1].0, label: previewCodexTitles[1].1,
                       repliedAfterSeconds: 220),
        previewTrigger(minutesAgo: 175, source: .claude,
                       title: previewClaudeTitles[4].0, label: previewClaudeTitles[4].1,
                       repliedAfterSeconds: 60),
        previewTrigger(minutesAgo: 240, source: .claude,
                       title: previewClaudeTitles[5].0, label: previewClaudeTitles[5].1,
                       repliedAfterSeconds: 410),
        previewTrigger(minutesAgo: 310, source: .codex,
                       title: previewCodexTitles[2].0, label: previewCodexTitles[2].1,
                       repliedAfterSeconds: 18),
        previewTrigger(minutesAgo: 405, source: .claude,
                       title: previewClaudeTitles[6].0, label: previewClaudeTitles[6].1,
                       repliedAfterSeconds: 70),
    ]
    return previewContent(
        armed: true,
        events: events
    )
}

#Preview("Busy day · Claude · dark") {
    // Everything: armed, a block in progress for one session, 12 recent
    // triggers across the day. This is the "you've been pairing with
    // Claude all afternoon" view.
    let active = PendingTrigger(
        sessionId: "preview-active-session",
        addedAt: Date().addingTimeInterval(-90),
        durationSeconds: 900
    )
    let events: [TriggerEvent] = (0..<12).map { i in
        let (title, label) = previewClaudeTitles[i % previewClaudeTitles.count]
        return previewTrigger(
            minutesAgo: i == 0 ? 1 : (i * 17),
            source: i % 4 == 3 ? .codex : .claude,
            title: title,
            label: label,
            needsReply: i == 0,
            repliedAfterSeconds: i == 0 ? nil : 30 + (i * 22)
        )
    }
    return previewContent(
        armed: true,
        pendingTriggers: [active],
        events: events
    )
}

#Preview("Busy day · Codex · dark") {
    // Same shape as the Claude variant but with a higher proportion of
    // `.codex` rows (Codex pings still arrive; they render in the
    // single Claude theme).
    let active = PendingTrigger(
        sessionId: "preview-codex-active",
        addedAt: Date().addingTimeInterval(-180),
        durationSeconds: 900
    )
    let events: [TriggerEvent] = (0..<11).map { i in
        let pool = i % 3 == 0 ? previewClaudeTitles : previewCodexTitles
        let (title, label) = pool[i % pool.count]
        return previewTrigger(
            minutesAgo: i == 0 ? 3 : (i * 21),
            source: i % 3 == 0 ? .claude : .codex,
            title: title,
            label: label,
            needsReply: i == 0,
            repliedAfterSeconds: i == 0 ? nil : 45 + (i * 19)
        )
    }
    return previewContent(
        armed: true,
        pendingTriggers: [active],
        events: events
    )
}

#endif
