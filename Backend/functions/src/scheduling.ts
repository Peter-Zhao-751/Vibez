// Pure, side-effect-free helpers for the timeout-unblock backup layer.
// No firebase imports here, so they unit-test without the admin SDK.

/**
 * Seconds added to every scheduled unblock so the push lands AFTER the
 * device's own expiry — the device starts its countdown when the block
 * push arrives (~1-5s after the server sent it). Design spec §2.
 */
export const UNBLOCK_BUFFER_SECONDS = 8;

/**
 * Clamp an untrusted duration to [1, 86400] seconds.
 * @param {unknown} value Candidate duration in seconds.
 * @param {number} fallback Used when `value` is not a finite number.
 * @return {number} The clamped duration, or the fallback.
 */
export function clampDuration(value: unknown, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }
  return Math.min(86400, Math.max(1, Math.round(value)));
}

/**
 * Seconds to wait before the timeout unblock for this event, including
 * the delivery-skew buffer. `done` uses the short duration; everything
 * else (needs-input / absent) uses the long one.
 * @param {string|undefined} event Lifecycle event (e.g. "done").
 * @param {object} durations Per-event seconds ({done, needsInput}).
 * @return {number} Delay in seconds (duration + buffer).
 */
export function delayForEvent(
  event: string | undefined,
  durations: {done: number; needsInput: number},
): number {
  const base = event === "done" ? durations.done : durations.needsInput;
  return base + UNBLOCK_BUFFER_SECONDS;
}

/**
 * Whether a /notify push should schedule a timeout unblock. Only blocks
 * that create a per-session timed trigger qualify: not replies
 * (shield:off), not focus/untagged (no session), not `replied`. An
 * absent event is treated as needs-input and DOES qualify.
 * @param {object} p Push fields (shield, session, event).
 * @return {boolean} True if a timeout unblock should be enqueued.
 */
export function shouldScheduleUnblock(p: {
  shield?: string;
  session?: string;
  event?: string;
}): boolean {
  if (p.shield === "off") return false;
  if (!p.session || p.session === "nosid") return false;
  if (p.event === "replied") return false;
  return true;
}

/** APNs headers shared by every Vibez push. */
export const APNS_HEADERS: Record<string, string> = {
  "apns-push-type": "alert",
  "apns-priority": "10",
};

/** The fields a Vibez push carries — shared by /notify and dispatchUnblock. */
export interface VibezPushFields {
  title: string;
  body: string;
  event?: string;
  shield?: string;
  session?: string;
  agent?: string;
  reason?: string;
  /**
   * Per-session ordering stamp (epoch millis). The phone applies a
   * shield state change for a session ONLY if seq >= the last seq it
   * applied for that session, so a shield:on/off pair delivered out of
   * order (FCM/APNs give no cross-message ordering) can't leave the
   * phone stuck. /notify stamps Date.now(); dispatchUnblock re-emits the
   * ORIGINAL on's seq so a genuine re-ping (higher seq) beats the stale
   * timeout. Absent on legacy pushes — the phone falls back to
   * arrival-order behavior when it's missing.
   */
  seq?: number;
}

/** The `aps` dictionary of an APNs alert payload. */
interface ApsDictionary {
  "alert": {title: string; body: string};
  "sound"?: string;
  "interruption-level"?: string;
  "content-available": number;
  "mutable-content": number;
}

/**
 * apns.payload: the `aps` dictionary plus Vibez's custom fields, which
 * sit at the top level (siblings of `aps`) so iOS surfaces them in
 * userInfo. title/body live ONLY inside aps.alert — the NSE reads them
 * from request.content and the host digs into aps.alert (design spec
 * §5); duplicating them at the top level was an ntfy-era leftover.
 */
export interface VibezApnsPayload {
  aps: ApsDictionary;
  event?: string;
  shield?: string;
  session?: string;
  agent?: string;
  reason?: string;
  seq?: number;
}

/**
 * Build the apns.payload for a Vibez push. `shield:"off"` → passive
 * (silent) alert; otherwise a standard alert with sound. Custom fields
 * sit at the top level (siblings of `aps`); title/body ride ONLY in
 * aps.alert — each piece of information exactly once.
 * @param {VibezPushFields} f Push fields: title, body, event, shield,
 *   session, agent, reason.
 * @return {VibezApnsPayload} The apns.payload (aps + custom fields).
 */
export function buildApnsPayload(f: VibezPushFields): VibezApnsPayload {
  const isSilent = f.shield === "off";
  const aps: ApsDictionary = isSilent ?
    {
      "alert": {title: f.title, body: f.body},
      "interruption-level": "passive",
      "content-available": 1,
      "mutable-content": 1,
    } :
    {
      "alert": {title: f.title, body: f.body},
      "sound": "default",
      "content-available": 1,
      "mutable-content": 1,
    };
  const payload: VibezApnsPayload = {aps};
  if (f.event !== undefined) payload.event = f.event;
  if (f.shield !== undefined) payload.shield = f.shield;
  if (f.session !== undefined) payload.session = f.session;
  if (f.agent !== undefined) payload.agent = f.agent;
  if (f.reason !== undefined) payload.reason = f.reason;
  if (f.seq !== undefined && Number.isFinite(f.seq)) payload.seq = f.seq;
  return payload;
}
