/* eslint-disable @typescript-eslint/no-explicit-any */
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

/**
 * Build the apns.payload for a Vibez push. `shield:"off"` → passive
 * (silent) alert; otherwise a standard alert with sound. Custom fields
 * sit at the top level (siblings of `aps`) so iOS surfaces them in
 * userInfo, matching what NotifyClient + the NSE parse.
 * @param {object} f Push fields: title, body, event, shield, session,
 *   agent, reason.
 * @return {any} The apns.payload object (aps + top-level custom fields).
 */
export function buildApnsPayload(f: {
  title: string;
  body: string;
  event?: string;
  shield?: string;
  session?: string;
  agent?: string;
  reason?: string;
}): any {
  const isSilent = f.shield === "off";
  const aps: any = isSilent ?
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
  const payload: any = {aps, title: f.title, body: f.body};
  if (f.event !== undefined) payload.event = f.event;
  if (f.shield !== undefined) payload.shield = f.shield;
  if (f.session !== undefined) payload.session = f.session;
  if (f.agent !== undefined) payload.agent = f.agent;
  if (f.reason !== undefined) payload.reason = f.reason;
  return payload;
}
