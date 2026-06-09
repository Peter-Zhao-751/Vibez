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
function makeSessionKey(session: string | null | undefined, id: string): string {
  return session && session !== "nosid" ? session : `untagged:${id}`;
}

export function sessionKeyFor(doc: VibezEventDoc): string {
  return makeSessionKey(doc.session, doc.id);
}

export function triggerKey(t: TriggerRecord): string {
  return makeSessionKey(t.sessionId, t.id);
}

/// Prepend `trigger` to the Recent Triggers list, replacing any prior
/// record with the same id and capping the result. The id-dedupe makes
/// applyEvent replay-safe: events are processed at-least-once (a crash
/// after partial apply re-delivers), so a re-applied event must update
/// its existing row, not duplicate it.
export function insertRecent(
  recents: TriggerRecord[],
  trigger: TriggerRecord,
  max: number,
): TriggerRecord[] {
  return [trigger, ...recents.filter((t) => t.id !== trigger.id)].slice(0, max);
}

export function prune(sessions: PendingSessions, now = Date.now()): PendingSessions {
  const out: PendingSessions = {};
  for (const [k, exp] of Object.entries(sessions)) if (exp > now) out[k] = exp;
  return out;
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
