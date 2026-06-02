// Today-only analytics, reset at local midnight (analog of AnalyticsTracker).

import type { AnalyticsToday, VibezEventDoc } from "../types";
import { freshAnalytics, todayLocal } from "../storage";

/// Return a fresh bucket if the stored date is no longer today; otherwise the
/// same reference (so callers can identity-compare to detect a rollover).
export function rollover(a: AnalyticsToday): AnalyticsToday {
  return a.date === todayLocal() ? a : freshAnalytics();
}

/// Count one incoming event. Passive — runs for every event regardless of the
/// armed toggle, matching the iOS tracker (which observes before the gate).
export function recordEvent(a0: AnalyticsToday, doc: VibezEventDoc): AnalyticsToday {
  const a = rollover(a0);
  const sessionIds =
    doc.session && !a.sessionIds.includes(doc.session)
      ? [...a.sessionIds, doc.session]
      : a.sessionIds;
  return {
    ...a,
    pings: a.pings + 1,
    replies: a.replies + (doc.shield === "off" ? 1 : 0),
    sessionIds,
  };
}

/// Total focus seconds today, including any in-flight block interval.
export function focusSecondsNow(a: AnalyticsToday, now = Date.now()): number {
  const live = a.blockStartedAt != null ? Math.round((now - a.blockStartedAt) / 1000) : 0;
  return a.focusSeconds + Math.max(0, live);
}
