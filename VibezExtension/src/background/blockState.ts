// Pure helpers for the per-session block map (analog of
// ScreenTimeManager.pendingTriggers). A block is active while any session's
// expiry is in the future.

import type {
  OverlayInfo,
  PendingSessions,
  Settings,
  TriggerRecord,
  VibezEvent,
  VibezEventDoc,
} from "../types";

/// done → short timer; everything else → long timer (mirrors ContentView.durationFor).
export function durationSecondsFor(event: VibezEvent | null, s: Settings): number {
  return event === "done" ? s.blockSecondsDone : s.blockSecondsNeedsInput;
}

/// Stable key for a session. Untagged events (no/`nosid` session) get a
/// synthetic per-event key so they still occupy the pending map.
export function sessionKeyFor(doc: VibezEventDoc): string {
  return doc.session && doc.session !== "nosid"
    ? doc.session
    : `untagged:${doc.id}`;
}

export function triggerKey(t: TriggerRecord): string {
  return t.sessionId && t.sessionId !== "nosid"
    ? t.sessionId
    : `untagged:${t.id}`;
}

export function prune(sessions: PendingSessions, now = Date.now()): PendingSessions {
  const out: PendingSessions = {};
  for (const [k, exp] of Object.entries(sessions)) if (exp > now) out[k] = exp;
  return out;
}

export function isActive(sessions: PendingSessions, now = Date.now()): boolean {
  return Object.values(sessions).some((exp) => exp > now);
}

export function soonestExpiry(sessions: PendingSessions): number | null {
  const xs = Object.values(sessions);
  return xs.length ? Math.min(...xs) : null;
}

/// The overlay reflects one pending trigger: the newest still-pending one by
/// default, or the oldest when overlayOrder is "oldest". Falls back to a bare
/// overlay if an active session has no matching record. `recents` is
/// newest-first.
export function overlayFor(
  recents: TriggerRecord[],
  sessions: PendingSessions,
  order: "newest" | "oldest" = "newest",
): OverlayInfo | null {
  const ordered = order === "oldest" ? [...recents].reverse() : recents;
  for (const t of ordered) {
    const k = triggerKey(t);
    if (sessions[k] != null) {
      return {
        title: t.title,
        body: t.body,
        agent: t.agent,
        event: t.event,
        expiresAt: sessions[k],
      };
    }
  }
  const keys = Object.keys(sessions);
  if (keys.length) {
    return { title: "Vibez", body: "", agent: null, event: null, expiresAt: sessions[keys[0]] };
  }
  return null;
}
