// Pure, side-effect-free helpers for the lazy-escalation rate limiter.
// No firebase imports here, so they unit-test without the admin SDK.
// The Firestore-transaction glue lives in index.ts. Design spec:
// docs/superpowers/specs/2026-06-04-backend-hardening-design.md §1.

/** Token-bucket parameters. */
export interface BucketConfig {
  capacity: number;
  refillPerSec: number;
}

/** Per-Vibez-ID bucket: burst 5, sustained 1/sec. */
export const ID_BUCKET: BucketConfig = {capacity: 5, refillPerSec: 1};

/** Per-source-IP bucket: bounds single-source floods and ID sprays. */
export const IP_BUCKET: BucketConfig = {capacity: 20, refillPerSec: 5};

/**
 * Per-instance all-traffic bucket. Last-resort ceiling that only
 * botnet-scale sprays reach (~30/sec is the projected legit fleet
 * peak at 1,000 users; this allows 100/sec per instance).
 */
export const GLOBAL_BUCKET: BucketConfig = {capacity: 200, refillPerSec: 100};

/** How long an instance keeps consulting Firestore after going dry. */
export const ESCALATION_WINDOW_MS = 60_000;

/** A bucket's state — in memory or in a rateLimits/{key} doc. */
export interface BucketState {
  tokens: number;
  lastRefillMs: number;
}

/**
 * Continuous refill: tokens grow at cfg.refillPerSec since
 * lastRefillMs, capped at capacity. Clock skew (nowMs in the past)
 * refills nothing rather than draining.
 * @param {BucketState} s Current state.
 * @param {number} nowMs Current epoch millis.
 * @param {BucketConfig} cfg Bucket parameters.
 * @return {BucketState} Refilled state stamped at nowMs.
 */
export function refill(
  s: BucketState, nowMs: number, cfg: BucketConfig,
): BucketState {
  const elapsedSec = Math.max(0, nowMs - s.lastRefillMs) / 1000;
  return {
    tokens: Math.min(cfg.capacity, s.tokens + elapsedSec * cfg.refillPerSec),
    lastRefillMs: Math.max(nowMs, s.lastRefillMs),
  };
}

/** Outcome of a tryTake: the verdict plus the state to store back. */
export interface TakeResult {
  allowed: boolean;
  next: BucketState;
  retryAfterMs: number;
}

/**
 * Take one token if available. Absent state means a full bucket
 * (first sight of this key). On deny, retryAfterMs is the time until
 * one whole token exists — the provably-safe negative-cache window.
 * @param {BucketState|undefined} s Current state, if any.
 * @param {number} nowMs Current epoch millis.
 * @param {BucketConfig} cfg Bucket parameters.
 * @return {TakeResult} Verdict + next state.
 */
export function tryTake(
  s: BucketState | undefined, nowMs: number, cfg: BucketConfig,
): TakeResult {
  const cur = refill(
    s ?? {tokens: cfg.capacity, lastRefillMs: nowMs}, nowMs, cfg);
  if (cur.tokens >= 1) {
    return {
      allowed: true,
      next: {tokens: cur.tokens - 1, lastRefillMs: cur.lastRefillMs},
      retryAfterMs: 0,
    };
  }
  const retryAfterMs = Math.ceil(((1 - cur.tokens) / cfg.refillPerSec) * 1000);
  return {allowed: false, next: cur, retryAfterMs};
}

/** Per-instance lazy-escalation state for one rate-limit key. */
export interface LimiterEntry {
  local: BucketState;
  escalatedUntilMs: number;
  denyUntilMs: number;
}

/** What the in-memory step decided for this request. */
export type LocalDecision =
  | {kind: "allow"; next: LimiterEntry}
  | {kind: "deny"; retryAfterMs: number; next: LimiterEntry}
  | {kind: "escalate"; next: LimiterEntry};

/**
 * The in-memory step of the lazy limiter (design spec §1):
 *   1. inside a deny window → deny with no I/O (negative cache);
 *   2. not escalated + local token available → allow with no I/O —
 *      the path all legitimate traffic takes;
 *   3. otherwise → escalate (caller consults the shared Firestore
 *      bucket) and slide the escalation window.
 * @param {LimiterEntry|undefined} e Entry for this key, if any.
 * @param {number} nowMs Current epoch millis.
 * @param {BucketConfig} cfg Bucket parameters.
 * @return {LocalDecision} Decision + entry to store back.
 */
export function decideLocally(
  e: LimiterEntry | undefined, nowMs: number, cfg: BucketConfig,
): LocalDecision {
  const entry: LimiterEntry = e ?? {
    local: {tokens: cfg.capacity, lastRefillMs: nowMs},
    escalatedUntilMs: 0,
    denyUntilMs: 0,
  };
  if (nowMs < entry.denyUntilMs) {
    return {
      kind: "deny",
      retryAfterMs: entry.denyUntilMs - nowMs,
      next: entry,
    };
  }
  if (nowMs >= entry.escalatedUntilMs) {
    const take = tryTake(entry.local, nowMs, cfg);
    if (take.allowed) {
      return {kind: "allow", next: {...entry, local: take.next}};
    }
  }
  return {
    kind: "escalate",
    next: {
      ...entry,
      local: refill(entry.local, nowMs, cfg),
      escalatedUntilMs: nowMs + ESCALATION_WINDOW_MS,
    },
  };
}

/**
 * Record a global (Firestore) deny in the per-instance entry so
 * repeat hammering during the dry window never reaches Firestore.
 * @param {LimiterEntry} e Entry that just escalated.
 * @param {number} nowMs Current epoch millis.
 * @param {number} retryAfterMs Dry window from the global tryTake.
 * @return {LimiterEntry} Entry with the negative-cache window set.
 */
export function recordGlobalDeny(
  e: LimiterEntry, nowMs: number, retryAfterMs: number,
): LimiterEntry {
  return {...e, denyUntilMs: nowMs + retryAfterMs};
}

/**
 * Insertion-order-bounded Map: at maxEntries, inserting a new key
 * evicts the oldest; re-setting an existing key refreshes its
 * position. Defensive memory bound for attacker-controlled keys
 * (Vibez IDs, IPs).
 */
export class BoundedMap<V> {
  private map = new Map<string, V>();

  /**
   * @param {number} maxEntries Hard cap on stored keys.
   */
  constructor(private readonly maxEntries: number) {}

  /**
   * @param {string} key Lookup key.
   * @return {V|undefined} Stored value, if present.
   */
  get(key: string): V | undefined {
    return this.map.get(key);
  }

  /**
   * @param {string} key Key to set.
   * @param {V} value Value to store.
   */
  set(key: string, value: V): void {
    if (this.map.has(key)) {
      this.map.delete(key);
    } else if (this.map.size >= this.maxEntries) {
      const oldest = this.map.keys().next().value;
      if (oldest !== undefined) this.map.delete(oldest);
    }
    this.map.set(key, value);
  }

  /**
   * @param {string} key Key to remove.
   */
  delete(key: string): void {
    this.map.delete(key);
  }
}
