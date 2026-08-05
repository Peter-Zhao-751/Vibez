// Pure request-validation helpers shared by /notify and
// registerPushToken. No firebase imports — unit-tested directly.
// Policy (design spec §2): enum/format violations REJECT (buggy or
// malicious caller — tell them); oversized title/body CLAMP with an
// ellipsis (a legit client with different limits degrades gracefully,
// matching the plugins' own clip behavior).

/**
 * 4 hyphen-separated words, each 3-5 lowercase ASCII letters.
 * Mirrored in PushTokenRegistrar.swift, VibezExtension/src/config.ts,
 * and the plugins' setup.sh — keep in sync (see CLAUDE.md).
 */
export const VIBEZ_ID_PATTERN = /^[a-z]{3,5}(-[a-z]{3,5}){3}$/;

/** CLI session ids (UUIDs and similar) — bounded charset + length. */
export const SESSION_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

/**
 * Source-Mac label for the HUD's cross-device rows (design spec
 * 2026-08-05). Advisory metadata: an invalid value is DROPPED, never a
 * rejection — a weird hostname must not kill the push it rides on.
 */
export const MACHINE_PATTERN = /^[A-Za-z0-9.-]{1,64}$/;

/** Server cap sits above the plugins' 72-char title clip. */
export const MAX_TITLE_CHARS = 100;

/** Server cap sits above the plugins' 160-char body clip. */
export const MAX_BODY_CHARS = 200;

/** Legit /notify requests are ~600 bytes; 8 KB is generous headroom. */
export const MAX_CONTENT_LENGTH_BYTES = 8192;

/** Real FCM registration tokens are 150+ chars. */
export const MIN_FCM_TOKEN_LENGTH = 20;

/** Real FCM registration tokens are ~163 chars; 512 is headroom. */
export const MAX_FCM_TOKEN_LENGTH = 512;

/** Junk-registration bound; the stale-token sweep frees slots. */
export const MAX_DEVICES_PER_VIBEZ_ID = 10;

const EVENTS = new Set(["needs-input", "done", "replied"]);
const SHIELDS = new Set(["on", "off"]);
const AGENTS = new Set(["cc", "cx", "cu"]);
const PLATFORMS = new Set(["ios", "web"]);

/**
 * Truncate to max chars with a trailing ellipsis, mirroring the
 * plugins' clip_body. Text at or under max passes through untouched.
 * The cut never splits a surrogate pair — the result is an upper
 * bound of max chars.
 * @param {string} raw Input text.
 * @param {number} max Maximum length in chars.
 * @return {string} Clamped text.
 */
export function clampText(raw: string, max: number): string {
  if (raw.length <= max) return raw;
  // Back up one code unit if the cut would land inside a surrogate
  // pair (astral chars like emoji are two UTF-16 units).
  let cut = max - 1;
  const cc = raw.charCodeAt(cut - 1);
  if (cc >= 0xD800 && cc <= 0xDBFF) cut -= 1;
  return raw.slice(0, cut) + "…";
}

/**
 * Coerce platform to the known set; everything else stores as
 * "unknown" so no arbitrary attacker string reaches Firestore.
 * @param {unknown} value Raw platform field.
 * @return {string} "ios" | "web" | "unknown".
 */
export function normalizePlatform(value: unknown): string {
  return typeof value === "string" && PLATFORMS.has(value) ?
    value : "unknown";
}

/** The validated, clamped fields of a /notify request. */
export interface NotifyFields {
  vibezId: string;
  title: string;
  body: string;
  event?: string;
  shield?: string;
  session?: string;
  agent?: string;
  machine?: string;
}

/** Validation outcome: fields on success, an error string on failure. */
export type NotifyValidation =
  | {ok: true; fields: NotifyFields}
  | {ok: false; error: string};

/**
 * Validate + clamp a /notify request body. Unknown fields are dropped
 * by construction (only known keys are copied out); `reason` is never
 * accepted from clients — only dispatchUnblock sets it, internally.
 * @param {unknown} raw Parsed request body.
 * @return {NotifyValidation} Validated fields or an error.
 */
export function validateNotifyBody(raw: unknown): NotifyValidation {
  const body = (
    typeof raw === "object" && raw !== null ? raw : {}
  ) as Record<string, unknown>;

  const vibezId = typeof body.vibezId === "string" ? body.vibezId : "";
  if (!VIBEZ_ID_PATTERN.test(vibezId)) {
    return {ok: false, error: "invalid vibezId"};
  }
  const title = typeof body.title === "string" ? body.title : "";
  const bodyText = typeof body.body === "string" ? body.body : "";
  if (!title || !bodyText) {
    return {ok: false, error: "title and body are required"};
  }

  const fields: NotifyFields = {
    vibezId,
    title: clampText(title, MAX_TITLE_CHARS),
    body: clampText(bodyText, MAX_BODY_CHARS),
  };

  if (body.event !== undefined) {
    if (typeof body.event !== "string" || !EVENTS.has(body.event)) {
      return {ok: false, error: "invalid event"};
    }
    fields.event = body.event;
  }
  if (body.shield !== undefined) {
    if (typeof body.shield !== "string" || !SHIELDS.has(body.shield)) {
      return {ok: false, error: "invalid shield"};
    }
    fields.shield = body.shield;
  }
  if (body.session !== undefined) {
    if (typeof body.session !== "string" ||
        !SESSION_PATTERN.test(body.session)) {
      return {ok: false, error: "invalid session"};
    }
    fields.session = body.session;
  }
  if (body.agent !== undefined) {
    if (typeof body.agent !== "string" || !AGENTS.has(body.agent)) {
      return {ok: false, error: "invalid agent"};
    }
    fields.agent = body.agent;
  }
  if (typeof body.machine === "string" && MACHINE_PATTERN.test(body.machine)) {
    fields.machine = body.machine;
  }
  return {ok: true, fields};
}
