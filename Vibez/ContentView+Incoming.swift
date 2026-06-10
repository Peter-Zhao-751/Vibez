//
//  ContentView+Incoming.swift
//  Vibez
//
//  The incoming-push half of ContentView: dedupe, analytics, the
//  shield:off / disarmed / shield:on routing, the overlay queue, and
//  the per-ping block-duration policy. Layout lives in
//  ContentView+Home.swift; shared state in ContentView.swift.
//

import SwiftUI
import OSLog

private let handleIncomingLog = Logger(subsystem: "vibezlol.Vibez", category: "handleIncoming")

extension ContentView {

    /// Pick the block duration based on what kind of ping landed:
    /// `done` → short timer (default 30s) just nudges you to glance at
    /// the result. Anything else (needs-input, replied, untagged) →
    /// long timer (default 15m) keeps the shield up while Claude waits.
    /// `replied` is unreachable on the trigger path (it carries
    /// `shield: .off`), but listing it explicitly avoids a `default` arm.
    private func durationFor(_ msg: NtfyMessage) -> Int {
        switch msg.event {
        case .done:                 return blockSecondsDone
        case .needsInput, .replied: return blockSecondsNeedsInput
        case .none:                 return blockSecondsNeedsInput
        }
    }

    private func recordTrigger(from message: NtfyMessage) {
        let source = TriggerEvent.source(for: message.agent)
        triggerStore.record(
            TriggerEvent(
                receivedAt: message.receivedAt,
                source: source,
                title: message.title,
                label: message.body,
                blockSeconds: durationFor(message),
                sessionId: message.sessionId,
                needsReply: message.needsReply
            )
        )
    }

    /// Tap Dismiss on the visible overlay. Depending on the user's setting,
    /// either resolve every pending trigger or only the visible session.
    func dismissOverlays() {
        guard let topMessage = overlayQueue.first else { return }
        // Sync first so both modes see sessions the NSE engaged while the
        // host was suspended.
        manager.reloadFromAppGroup()
        if dismissAllOverlays {
            let sessionIds = Set(manager.pendingTriggers.keys).union(
                overlayQueue.compactMap(\.sessionId).filter(\.isUsableSessionId)
            )
            manager.clearTriggers()
            for sid in sessionIds {
                triggerStore.clearNeedsReply(forSession: sid)
            }
            withAnimation(.easeInOut(duration: 0.32)) {
                overlayQueue.removeAll()
            }
        } else {
            if let sid = topMessage.sessionId, sid.isUsableSessionId {
                manager.resolveTrigger(sessionId: sid)
                triggerStore.clearNeedsReply(forSession: sid)
            }
            withAnimation(.easeInOut(duration: 0.32)) {
                _ = overlayQueue.removeFirst()
            }
        }
        maybePromptForReview()
    }

    /// After the user dismisses the LAST block overlay, offer the review
    /// prompt if they're engaged + multi-day + not in a cooldown. Shown
    /// after the overlay's 0.32s dismiss animation so we don't stack a
    /// sheet on top of it. Only reachable post-dismiss, so onboarding (a
    /// full-screen cover) is never up at this point.
    private func maybePromptForReview() {
        guard overlayQueue.isEmpty else { return }
        // Design-doc gates (2026-06-09-auto-review-prompt): never over
        // another modal, never before setup completed. Structurally the
        // Dismiss tap can't happen under a sheet/cover, but the DEBUG
        // auto-dismiss seam drives this path programmatically — keep the
        // guards real rather than relying on reachability.
        guard !showSettings, !pickerPresented else { return }
        guard UserDefaults.standard.bool(forKey: "vibez.onboardingCompleted") else { return }
        guard reviewPrompt.shouldPromptNow(pingsToday: analytics.pingsToday) else { return }
        reviewPrompt.markPrompted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showReviewPrompt = true
        }
    }

    /// Countdown on the top overlay reached 0. The trigger has already
    /// auto-pruned in ScreenTimeManager; just clear the recent-trigger
    /// dot and pop.
    func expireTopOverlay() {
        guard let msg = overlayQueue.first else { return }
        if let sid = msg.sessionId, sid.isUsableSessionId {
            triggerStore.clearNeedsReply(forSession: sid)
        }
        withAnimation(.easeInOut(duration: 0.32)) {
            _ = overlayQueue.removeFirst()
        }
    }

    /// Whether an overlay should be surfaced for this message. A
    /// session-tagged message must have a live (present, non-expired)
    /// trigger behind it — that trigger is the clock the overlay's
    /// countdown and its `onExpire` auto-dismiss both read from
    /// (`BlockedOverlay` gates the whole `TimelineView` on
    /// `expiresAt != nil`). Without a live trigger the overlay shows no
    /// timer and can never self-close, so the only escape is the Dismiss
    /// button — exactly the stuck state users hit on the background-replay
    /// path, where `tick()` can prune the expired trigger before
    /// `drainPendingPushFromAppGroup` replays its overlay. Untagged
    /// messages (no session) carry no trigger by design and keep the old
    /// informational-overlay behavior.
    private func shouldEnqueueOverlay(for message: NtfyMessage) -> Bool {
        guard let sid = message.sessionId, sid.isUsableSessionId else {
            return true
        }
        guard let trigger = manager.pendingTriggers[sid] else { return false }
        return !trigger.isExpired(now: Date())
    }

    /// Push a fresh ping onto the queue. If an entry exists with the
    /// same sessionId, remove it first — the new ping carries the
    /// latest state of that conversation, so the old entry is stale.
    /// Where the new entry lands depends on the user's overlayOrder:
    ///   - `.stack` (LIFO): insert at the front so it surfaces on top.
    ///   - `.queue` (FIFO): append at the back so the oldest pending
    ///     block stays visible until dismissed.
    private func enqueueOverlay(_ message: NtfyMessage) {
        if let sid = message.sessionId, sid.isUsableSessionId {
            overlayQueue.removeAll { $0.sessionId == sid }
        }
        switch overlayOrder {
        case .stack: overlayQueue.insert(message, at: 0)
        case .queue: overlayQueue.append(message)
        }
    }

    /// Single entry-point for incoming pushes. Dedupes by message id
    /// so a push that gets observed twice (once via .onChange while
    /// foreground, again via .onAppear after a background wake) only
    /// updates state once.
    func processIfNew(_ message: NtfyMessage?) {
        guard let message else { return }
        guard message.id != lastProcessedMessageId else { return }
        lastProcessedMessageId = message.id
        handleIncoming(message)
    }

    private func handleIncoming(_ message: NtfyMessage) {
        let shieldStr = message.shield.map { $0.rawValue } ?? "nil"
        let armedStr = manager.armed ? "armed" : "disarmed"
        handleIncomingLog.info(
            "enter: shield=\(shieldStr, privacy: .public) \(armedStr, privacy: .public) session=\(message.sessionId ?? "nil", privacy: .public)"
        )

        // Tracker is a passive observer — fires for every incoming
        // message, before any of the gating below. shield:off pings
        // (user replies) and pings that arrive while Vibez is unarmed
        // both still count as activity for today's stats.
        analytics.record(message)
        // Multi-day usage ledger for the review prompt (distinct active days).
        reviewPrompt.recordActivity()

        // shield:off (the user just replied in Claude) is a control
        // signal — never surface it as a notification, and only act on
        // it if we actually have something to resolve. Handled first so
        // it bypasses the toggle gate below: a reply that lands while
        // the user has just flipped the toggle off is harmless to
        // process (resolveTrigger is a no-op when the session isn't
        // pending) and we don't want stale state to linger.
        if message.shield == .off {
            handleIncomingLog.info("branch: shield=off → resolve trigger only")
            if let sid = message.sessionId {
                manager.resolveTrigger(sessionId: sid)
                triggerStore.clearNeedsReply(forSession: sid)
                withAnimation(.easeInOut(duration: 0.32)) {
                    overlayQueue.removeAll { $0.sessionId == sid }
                }
            }
            return
        }

        // Toggle off → Vibez is dormant. Don't notify, don't show the
        // overlay, don't add a trigger — the user has explicitly told us
        // to stay out of the way.
        guard manager.armed else {
            handleIncomingLog.info("branch: disarmed → drop")
            return
        }

        switch message.shield {
        case .on:
            handleIncomingLog.info("branch: shield=on → record trigger + maybe shield/overlay")
            recordTrigger(from: message)

            if let sid = message.sessionId,
               sid.isUsableSessionId {
                if ignoreStore.contains(sessionId: sid, name: message.title) {
                    handleIncomingLog.info("→ ignored, no overlay/shield")
                    // Ignored conversation — keep the row in Recent
                    // triggers (dimmed) but skip the shield and the
                    // overlay. Refresh the cached name so Settings
                    // shows the latest title.
                    ignoreStore.refreshName(
                        sessionId: sid,
                        name: message.title
                    )
                    return
                }
                // Skip addTrigger when the NSE already did it in the
                // background — re-adding would reset the per-session
                // timer to now (giving the user extra free time).
                if !message.wasBackgroundEngaged {
                    manager.addTrigger(sessionId: sid, durationSeconds: durationFor(message))
                }
                // Per-app block counts are no longer bumped here — the
                // VibezShield extension tallies them per actual open, so
                // "most blocked" reflects what you hit, not the whole list.
            }
            // Skip context refresh on drain — NSE wrote it. Otherwise
            // we'd overwrite with the same data.
            if !message.wasBackgroundEngaged {
                manager.publishShieldContext(from: message)
            }

            // Skip local notification on drain — iOS already displayed
            // the NSE-modified banner when the push arrived. Otherwise
            // the user sees a second banner the moment they open Vibez.
            // Also skip when the user has turned banners off — the shield
            // still engaged above; we just don't interrupt them.
            if !message.wasBackgroundEngaged && notifyBanners {
                notifyClient.scheduleLocalNotification(message)
            }
            // Only surface the overlay when a live trigger backs it. On
            // the background-replay path (wasBackgroundEngaged), tick()
            // can prune the NSE-engaged block right before
            // drainPendingPushFromAppGroup replays it; re-enqueuing then
            // strands a timerless overlay that only the Dismiss button can
            // clear (the foreground race). The foreground path called
            // addTrigger just above, so a live trigger is always present
            // there and this stays a no-op guard.
            if shouldEnqueueOverlay(for: message) {
                withAnimation(.easeInOut(duration: 0.32)) {
                    enqueueOverlay(message)
                }
            } else {
                handleIncomingLog.info("→ stale replay, no live trigger — skipping overlay")
            }

        case .none:
            handleIncomingLog.info("branch: shield=nil → record trigger + overlay")
            // Plain push (test ping, third-party producer, etc.) — show
            // the overlay as we always did.
            recordTrigger(from: message)
            if !message.wasBackgroundEngaged && notifyBanners {
                notifyClient.scheduleLocalNotification(message)
            }
            withAnimation(.easeInOut(duration: 0.32)) {
                enqueueOverlay(message)
            }

        case .off:
            // Unreachable — handled above.
            break
        }
    }
}
