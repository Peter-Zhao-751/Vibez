# Backend Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved spec `docs/superpowers/specs/2026-06-04-backend-hardening-design.md` — lazy-escalation rate limiting, payload caps/validation, APNs payload dedup, registration hardening, and cost levers for the Vibez Firebase backend.

**Architecture:** Two new pure TS modules (`ratelimit.ts`, `validation.ts`) hold all unit-testable logic, mirroring the existing `scheduling.ts` pattern; `index.ts` only wires them to Firestore/FCM. iOS changes are two parse-site swaps (NSE → `request.content`, NotifyClient → `aps.alert` with a permanent flat-key fallback for the App Group drain path). Plugin changes are one defensive clamp helper each.

**Tech Stack:** Firebase Functions v2 (Node 24, TS, eslint-config-google — 2-space indent, double quotes, max-len 80, JSDoc on exports), vitest, Swift (MainActor default), bash.

**Working rules for every task:**
- Work at the repo root `/Users/peter/Desktop/Vibez` on `main` (per CLAUDE.md worktree note — real changes belong here).
- The repo has unrelated uncommitted changes. `git add` **explicit file paths only** — never `git add -A` or `.`.
- Backend commands run from `Backend/functions/` unless noted.

---

### Task 1: `ratelimit.ts` — pure token-bucket + lazy-escalation math

**Files:**
- Create: `Backend/functions/src/ratelimit.ts`
- Test: `Backend/functions/test/ratelimit.test.ts`

- [ ] **Step 1: Write the failing test**

Create `Backend/functions/test/ratelimit.test.ts`:

```ts
import {describe, it, expect} from "vitest";
import {
  ID_BUCKET,
  IP_BUCKET,
  GLOBAL_BUCKET,
  ESCALATION_WINDOW_MS,
  refill,
  tryTake,
  decideLocally,
  recordGlobalDeny,
  BoundedMap,
} from "../src/ratelimit";

const T0 = 1_700_000_000_000;

describe("bucket configs", () => {
  it("match the spec: id 5/1s, ip 20/5s, global 200/100s", () => {
    expect(ID_BUCKET).toEqual({capacity: 5, refillPerSec: 1});
    expect(IP_BUCKET).toEqual({capacity: 20, refillPerSec: 5});
    expect(GLOBAL_BUCKET).toEqual({capacity: 200, refillPerSec: 100});
  });
});

describe("refill", () => {
  it("grows tokens by elapsed time, capped at capacity", () => {
    const s = {tokens: 0, lastRefillMs: T0};
    expect(refill(s, T0 + 2500, ID_BUCKET).tokens).toBeCloseTo(2.5);
    expect(refill(s, T0 + 60_000, ID_BUCKET).tokens).toBe(5);
  });
  it("never goes backwards on clock skew", () => {
    const s = {tokens: 3, lastRefillMs: T0};
    expect(refill(s, T0 - 5000, ID_BUCKET).tokens).toBe(3);
  });
});

describe("tryTake", () => {
  it("treats absent state as a full bucket (first sight)", () => {
    const r = tryTake(undefined, T0, ID_BUCKET);
    expect(r.allowed).toBe(true);
    expect(r.next.tokens).toBe(4);
  });
  it("drains the burst then denies with retryAfterMs <= 1s", () => {
    let s;
    for (let i = 0; i < 5; i++) {
      const r = tryTake(s, T0, ID_BUCKET);
      expect(r.allowed).toBe(true);
      s = r.next;
    }
    const denied = tryTake(s, T0, ID_BUCKET);
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfterMs).toBeGreaterThan(0);
    expect(denied.retryAfterMs).toBeLessThanOrEqual(1000);
  });
  it("allows again after one refill interval", () => {
    let s;
    for (let i = 0; i < 5; i++) s = tryTake(s, T0, ID_BUCKET).next;
    const r = tryTake(s, T0 + 1000, ID_BUCKET);
    expect(r.allowed).toBe(true);
  });
});

describe("decideLocally (lazy escalation)", () => {
  it("allows from the local bucket without escalation", () => {
    const d = decideLocally(undefined, T0, ID_BUCKET);
    expect(d.kind).toBe("allow");
  });
  it("escalates when the local bucket is dry", () => {
    let e;
    for (let i = 0; i < 5; i++) {
      const d = decideLocally(e, T0, ID_BUCKET);
      expect(d.kind).toBe("allow");
      e = d.next;
    }
    const d = decideLocally(e, T0, ID_BUCKET);
    expect(d.kind).toBe("escalate");
    expect(d.next.escalatedUntilMs).toBe(T0 + ESCALATION_WINDOW_MS);
  });
  it("keeps escalating inside the window even with local tokens", () => {
    let e;
    for (let i = 0; i < 6; i++) e = decideLocally(e, T0, ID_BUCKET).next;
    // 30s later the local bucket has refilled, but the window is open.
    const d = decideLocally(e, T0 + 30_000, ID_BUCKET);
    expect(d.kind).toBe("escalate");
  });
  it("returns to the local fast path after the window closes", () => {
    let e;
    for (let i = 0; i < 6; i++) e = decideLocally(e, T0, ID_BUCKET).next;
    const d = decideLocally(e, T0 + ESCALATION_WINDOW_MS + 5000, ID_BUCKET);
    expect(d.kind).toBe("allow");
  });
  it("denies from the negative cache without I/O", () => {
    let e;
    for (let i = 0; i < 6; i++) e = decideLocally(e, T0, ID_BUCKET).next;
    e = recordGlobalDeny(e, T0, 800);
    const d = decideLocally(e, T0 + 100, ID_BUCKET);
    expect(d.kind).toBe("deny");
    if (d.kind === "deny") expect(d.retryAfterMs).toBe(700);
    const after = decideLocally(e, T0 + 900, ID_BUCKET);
    expect(after.kind).not.toBe("deny");
  });
});

describe("BoundedMap", () => {
  it("evicts the oldest key at capacity", () => {
    const m = new BoundedMap<number>(2);
    m.set("a", 1);
    m.set("b", 2);
    m.set("c", 3);
    expect(m.get("a")).toBeUndefined();
    expect(m.get("b")).toBe(2);
    expect(m.get("c")).toBe(3);
  });
  it("re-setting an existing key refreshes it instead of evicting", () => {
    const m = new BoundedMap<number>(2);
    m.set("a", 1);
    m.set("b", 2);
    m.set("a", 9);
    m.set("c", 3);
    expect(m.get("a")).toBe(9);
    expect(m.get("b")).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Backend/functions && npx vitest run test/ratelimit.test.ts`
Expected: FAIL — `Cannot find module '../src/ratelimit'` (or equivalent resolve error).

- [ ] **Step 3: Write the implementation**

Create `Backend/functions/src/ratelimit.ts`:

```ts
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Backend/functions && npx vitest run test/ratelimit.test.ts`
Expected: PASS (all describe blocks green).

- [ ] **Step 5: Lint and commit**

```bash
cd Backend/functions && npm run lint
cd /Users/peter/Desktop/Vibez
git add Backend/functions/src/ratelimit.ts Backend/functions/test/ratelimit.test.ts
git commit -m "feat(backend): pure token-bucket + lazy-escalation rate-limit math"
```

---

### Task 2: `validation.ts` — pure request validation + clamps

**Files:**
- Create: `Backend/functions/src/validation.ts`
- Test: `Backend/functions/test/validation.test.ts`

- [ ] **Step 1: Write the failing test**

Create `Backend/functions/test/validation.test.ts`:

```ts
import {describe, it, expect} from "vitest";
import {
  VIBEZ_ID_PATTERN,
  MAX_TITLE_CHARS,
  MAX_BODY_CHARS,
  MAX_CONTENT_LENGTH_BYTES,
  MIN_FCM_TOKEN_LENGTH,
  MAX_FCM_TOKEN_LENGTH,
  MAX_DEVICES_PER_VIBEZ_ID,
  clampText,
  normalizePlatform,
  validateNotifyBody,
} from "../src/validation";

const VALID = {
  vibezId: "moss-pine-fox-jazz",
  title: "Fix login bug",
  body: "Should I commit this?",
};

describe("constants", () => {
  it("match the spec", () => {
    expect(MAX_TITLE_CHARS).toBe(100);
    expect(MAX_BODY_CHARS).toBe(200);
    expect(MAX_CONTENT_LENGTH_BYTES).toBe(8192);
    expect(MIN_FCM_TOKEN_LENGTH).toBe(20);
    expect(MAX_FCM_TOKEN_LENGTH).toBe(512);
    expect(MAX_DEVICES_PER_VIBEZ_ID).toBe(10);
  });
});

describe("VIBEZ_ID_PATTERN", () => {
  it("accepts 4 hyphenated 3-5 letter words", () => {
    expect(VIBEZ_ID_PATTERN.test("moss-pine-fox-jazz")).toBe(true);
  });
  it("rejects wrong shapes", () => {
    expect(VIBEZ_ID_PATTERN.test("moss-pine-fox")).toBe(false);
    expect(VIBEZ_ID_PATTERN.test("Moss-pine-fox-jazz")).toBe(false);
    expect(VIBEZ_ID_PATTERN.test("toolong-pine-fox-jazz")).toBe(false);
  });
});

describe("clampText", () => {
  it("passes short text through untouched", () => {
    expect(clampText("hello", 100)).toBe("hello");
  });
  it("truncates at max chars with a trailing ellipsis", () => {
    const long = "x".repeat(150);
    const out = clampText(long, 100);
    expect(out.length).toBe(100);
    expect(out.endsWith("…")).toBe(true);
  });
  it("keeps text exactly at max untouched", () => {
    const exact = "x".repeat(100);
    expect(clampText(exact, 100)).toBe(exact);
  });
});

describe("normalizePlatform", () => {
  it("passes known platforms through", () => {
    expect(normalizePlatform("ios")).toBe("ios");
    expect(normalizePlatform("web")).toBe("web");
  });
  it("coerces everything else to unknown", () => {
    expect(normalizePlatform("android")).toBe("unknown");
    expect(normalizePlatform(42)).toBe("unknown");
    expect(normalizePlatform(undefined)).toBe("unknown");
    expect(normalizePlatform("x".repeat(5000))).toBe("unknown");
  });
});

describe("validateNotifyBody", () => {
  it("accepts a minimal valid body", () => {
    const r = validateNotifyBody(VALID);
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.fields.vibezId).toBe(VALID.vibezId);
      expect(r.fields.event).toBeUndefined();
    }
  });
  it("accepts all optional fields with valid values", () => {
    const r = validateNotifyBody({
      ...VALID,
      event: "needs-input",
      shield: "on",
      session: "abc-123_DEF.x:9",
      agent: "cc",
    });
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.fields.session).toBe("abc-123_DEF.x:9");
  });
  it("rejects bad vibezId / missing title / missing body", () => {
    expect(validateNotifyBody({...VALID, vibezId: "nope"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, title: ""}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, body: ""}).ok).toBe(false);
    expect(validateNotifyBody(null).ok).toBe(false);
    expect(validateNotifyBody("string").ok).toBe(false);
  });
  it("rejects unknown enum values (400, not clamp)", () => {
    expect(validateNotifyBody({...VALID, event: "explode"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, shield: "maybe"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, agent: "gpt"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, event: 7}).ok).toBe(false);
  });
  it("rejects bad sessions: too long, bad chars, empty", () => {
    expect(validateNotifyBody(
      {...VALID, session: "x".repeat(129)}).ok).toBe(false);
    expect(validateNotifyBody(
      {...VALID, session: "has space"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, session: ""}).ok).toBe(false);
  });
  it("clamps oversized title/body instead of rejecting", () => {
    const r = validateNotifyBody({
      ...VALID,
      title: "t".repeat(300),
      body: "b".repeat(900),
    });
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.fields.title.length).toBe(MAX_TITLE_CHARS);
      expect(r.fields.body.length).toBe(MAX_BODY_CHARS);
      expect(r.fields.body.endsWith("…")).toBe(true);
    }
  });
  it("drops unknown fields by construction", () => {
    const r = validateNotifyBody({...VALID, reason: "timeout", evil: "x"});
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect("reason" in r.fields).toBe(false);
      expect("evil" in r.fields).toBe(false);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Backend/functions && npx vitest run test/validation.test.ts`
Expected: FAIL — cannot find module `../src/validation`.

- [ ] **Step 3: Write the implementation**

Create `Backend/functions/src/validation.ts`:

```ts
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
const AGENTS = new Set(["cc", "cx"]);
const PLATFORMS = new Set(["ios", "web"]);

/**
 * Truncate to max chars with a trailing ellipsis, mirroring the
 * plugins' clip_body. Text at or under max passes through untouched.
 * @param {string} raw Input text.
 * @param {number} max Maximum length in chars.
 * @return {string} Clamped text.
 */
export function clampText(raw: string, max: number): string {
  if (raw.length <= max) return raw;
  return raw.slice(0, max - 1) + "…";
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
  return {ok: true, fields};
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Backend/functions && npx vitest run test/validation.test.ts`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

```bash
cd Backend/functions && npm run lint
cd /Users/peter/Desktop/Vibez
git add Backend/functions/src/validation.ts Backend/functions/test/validation.test.ts
git commit -m "feat(backend): pure /notify + register validation with caps and whitelists"
```

---

### Task 3: `scheduling.ts` — stop duplicating title/body in the APNs payload

**Files:**
- Modify: `Backend/functions/src/scheduling.ts:90-132`
- Test: `Backend/functions/test/scheduling.test.ts:84-91`

- [ ] **Step 1: Update the test to assert NO top-level title/body**

In `Backend/functions/test/scheduling.test.ts`, replace the test
`"omits unset optional fields and mirrors title/body at top level"` (lines 84-91) with:

```ts
  it("keeps title/body ONLY inside aps.alert — no top-level copy", () => {
    const p = buildApnsPayload({title: "T", body: "B"});
    expect(p.aps.alert).toEqual({title: "T", body: "B"});
    expect("title" in p).toBe(false);
    expect("body" in p).toBe(false);
    expect(p.event).toBeUndefined();
    expect(p.reason).toBeUndefined();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Backend/functions && npx vitest run test/scheduling.test.ts`
Expected: FAIL — `"title" in p` is `true` (payload still mirrors title at top level).

- [ ] **Step 3: Update the implementation**

In `Backend/functions/src/scheduling.ts`:

Replace the `VibezApnsPayload` interface (lines 85-99) with:

```ts
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
}
```

In `buildApnsPayload` (lines 110-132), replace the line

```ts
  const payload: VibezApnsPayload = {aps, title: f.title, body: f.body};
```

with

```ts
  const payload: VibezApnsPayload = {aps};
```

and update the function's doc comment first paragraph to:

```ts
/**
 * Build the apns.payload for a Vibez push. `shield:"off"` → passive
 * (silent) alert; otherwise a standard alert with sound. Custom fields
 * sit at the top level (siblings of `aps`); title/body ride ONLY in
 * aps.alert — each piece of information exactly once.
 * @param {VibezPushFields} f Push fields: title, body, event, shield,
 *   session, agent, reason.
 * @return {VibezApnsPayload} The apns.payload (aps + custom fields).
 */
```

- [ ] **Step 4: Run all backend tests**

Run: `cd Backend/functions && npm test`
Expected: PASS — scheduling, ratelimit, validation all green.

- [ ] **Step 5: Commit**

```bash
cd /Users/peter/Desktop/Vibez
git add Backend/functions/src/scheduling.ts Backend/functions/test/scheduling.test.ts
git commit -m "feat(backend): send title/body once — aps.alert only, no top-level copy"
```

---

### Task 4: `index.ts` — wire caps, validation, uniform response, maxInstances

**Files:**
- Modify: `Backend/functions/src/index.ts`

No new unit tests in this task — all decision logic was tested pure in Tasks 1-2; the handler is covered by the curl matrix in Task 11. (This matches the repo pattern: only pure helpers get vitest coverage.)

- [ ] **Step 1: Update imports and global options**

In `Backend/functions/src/index.ts`:

Replace `setGlobalOptions({maxInstances: 10});` (line 18) with:

```ts
// 3 instances × concurrency 80 is generous for ~1,000 users (~3.5
// req/s average). This is the hard cap on the worst-case compute bill
// AND the in-memory limiter leak factor (design spec §1, §7).
setGlobalOptions({maxInstances: 3});
```

Add to the import block (after the `./scheduling.js` import):

```ts
import {
  ID_BUCKET,
  IP_BUCKET,
  GLOBAL_BUCKET,
  BucketState,
  LimiterEntry,
  BoundedMap,
  decideLocally,
  recordGlobalDeny,
  tryTake,
} from "./ratelimit.js";
import {
  validateNotifyBody,
  normalizePlatform,
  VIBEZ_ID_PATTERN,
  MAX_CONTENT_LENGTH_BYTES,
  MIN_FCM_TOKEN_LENGTH,
  MAX_FCM_TOKEN_LENGTH,
  MAX_DEVICES_PER_VIBEZ_ID,
} from "./validation.js";
```

Delete the now-duplicated local declarations: `MIN_FCM_TOKEN_LENGTH` (lines 31-33) and `VIBEZ_ID_PATTERN` (lines 35-37) and their comments.

- [ ] **Step 2: Replace the top of the notify handler**

Replace the body-parsing + validation section of `notify` (the lines from `const body = (req.body ?? {})...` through the `if (!title || !bodyText) {...}` block, currently lines 139-155) with:

```ts
    // Cheapest checks first; Firestore is touched only after all pass
    // (design spec §2). Content-Length bounds parse-side garbage; the
    // framework's own JSON parser limit is the layer below this.
    const contentLength = Number(req.headers["content-length"] ?? 0);
    if (contentLength > MAX_CONTENT_LENGTH_BYTES) {
      res.status(413).json({error: "payload too large"});
      return;
    }

    const validation = validateNotifyBody(req.body);
    if (!validation.ok) {
      res.status(400).json({error: validation.error});
      return;
    }
    const {vibezId, title, body: bodyText, event, shield, session, agent} =
      validation.fields;
```

- [ ] **Step 3: Make every success response uniform**

Still in `notify`:

Replace the zero-device early return (`res.status(200).json({total: 0, success: 0, failure: 0, web: false});`) with:

```ts
      // Uniform body — a claimed/unclaimed distinction here would be a
      // free enumeration oracle (design spec §2). Counts live in logs.
      res.status(200).json({ok: true});
```

Replace the final response (`res.status(200).json({total: apnsTokens.length, success, failure, errors, web: hasWeb});`) with:

```ts
    res.status(200).json({ok: true});
```

Delete the `const errors: {code?: string; message?: string}[] = [];` declaration and the `errors.push({code, message: errMessage});` line — the per-token warn log directly above it already records code + message server-side.

- [ ] **Step 4: Build, lint, commit**

```bash
cd Backend/functions && npm run build && npm run lint && npm test
cd /Users/peter/Desktop/Vibez
git add Backend/functions/src/index.ts
git commit -m "feat(backend): payload caps + field validation + uniform /notify responses"
```

Expected: build clean, lint clean, tests green.

---

### Task 5: `index.ts` — wire the three-layer rate limiter into `/notify`

**Files:**
- Modify: `Backend/functions/src/index.ts`

- [ ] **Step 1: Add module-scope limiter state + helpers**

After the `MULTICAST_CHUNK` constant in `index.ts`, add:

```ts
// ---- Rate limiting (design spec §1) ----------------------------------
// Three layers, all in cost order: per-IP and per-instance-global are
// in-memory only; the per-Vibez-ID bucket is lazy — in-memory fast
// path, Firestore-coordinated only while a key is over-rate locally.

const RATE_LIMITS = "rateLimits";

/** Idle limiter docs self-delete via the TTL policy on expireAt. */
const LIMITER_DOC_TTL_MS = 24 * 60 * 60 * 1000;

/** Bound for every attacker-keyed in-memory map (~5 MB worst case). */
const MAX_TRACKED_KEYS = 50_000;

const limiterEntries = new BoundedMap<LimiterEntry>(MAX_TRACKED_KEYS);
const ipBuckets = new BoundedMap<BucketState>(MAX_TRACKED_KEYS);
let globalBucket: BucketState | undefined;

/**
 * In-memory guards shared by both endpoints: per-source-IP bucket,
 * then the per-instance all-traffic bucket. No Firestore.
 * @param {string} ip Caller IP ("unknown" if the runtime omits it).
 * @param {number} nowMs Current epoch millis.
 * @return {boolean} True when the request may proceed.
 */
function passesMemoryGuards(ip: string, nowMs: number): boolean {
  const ipTake = tryTake(ipBuckets.get(ip), nowMs, IP_BUCKET);
  ipBuckets.set(ip, ipTake.next);
  if (!ipTake.allowed) return false;
  const g = tryTake(globalBucket, nowMs, GLOBAL_BUCKET);
  globalBucket = g.next;
  return g.allowed;
}

/**
 * Lazy per-key limiter: local bucket first; Firestore transaction on
 * rateLimits/{key} only while this instance sees over-rate traffic;
 * global denies negative-cache in memory. Fails OPEN — delivery
 * matters more than strictness, and attackers can't induce Firestore
 * errors on demand.
 * @param {string} key e.g. "notify:moss-pine-fox-jazz".
 * @param {number} nowMs Current epoch millis.
 * @return {Promise<{allowed: boolean, retryAfterMs: number}>} Verdict.
 */
async function checkKeyRateLimit(
  key: string, nowMs: number,
): Promise<{allowed: boolean; retryAfterMs: number}> {
  const decision = decideLocally(limiterEntries.get(key), nowMs, ID_BUCKET);
  limiterEntries.set(key, decision.next);
  if (decision.kind === "allow") return {allowed: true, retryAfterMs: 0};
  if (decision.kind === "deny") {
    return {allowed: false, retryAfterMs: decision.retryAfterMs};
  }
  try {
    const ref = tokensDb.collection(RATE_LIMITS).doc(key);
    const verdict = await tokensDb.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const state = snap.exists ?
        (snap.data() as unknown as BucketState) : undefined;
      const take = tryTake(state, nowMs, ID_BUCKET);
      if (take.allowed) {
        tx.set(ref, {
          tokens: take.next.tokens,
          lastRefillMs: take.next.lastRefillMs,
          expireAt: Timestamp.fromMillis(nowMs + LIMITER_DOC_TTL_MS),
        });
      }
      return take;
    });
    if (!verdict.allowed) {
      limiterEntries.set(
        key, recordGlobalDeny(decision.next, nowMs, verdict.retryAfterMs));
    }
    return {allowed: verdict.allowed, retryAfterMs: verdict.retryAfterMs};
  } catch (e) {
    logger.warn("rate limiter unavailable — failing open", {
      key, err: String(e),
    });
    return {allowed: true, retryAfterMs: 0};
  }
}

/**
 * 429 helper for /notify.
 * @param {object} res Express response.
 * @param {number} retryAfterMs Dry window, rounded up to seconds.
 */
function respondRateLimited(
  res: {set: (k: string, v: string) => void;
        status: (n: number) => {json: (b: unknown) => void}},
  retryAfterMs: number,
): void {
  res.set("Retry-After",
    String(Math.max(1, Math.ceil(retryAfterMs / 1000))));
  res.status(429).json({error: "rate limited"});
}
```

(If the eslint generics/type gymnastics on `respondRateLimited` fight the
`Response` type, simply inline the two lines at both call sites instead —
the helper is convenience, not architecture.)

- [ ] **Step 2: Call the guards from the notify handler**

In `notify`, immediately after the `validation.fields` destructuring added in Task 4, insert:

```ts
    const nowMs = Date.now();
    if (!passesMemoryGuards(req.ip ?? "unknown", nowMs)) {
      respondRateLimited(res, 1000);
      return;
    }
    const limit = await checkKeyRateLimit(`notify:${vibezId}`, nowMs);
    if (!limit.allowed) {
      logger.info("notify rate limited", {vibezId});
      respondRateLimited(res, limit.retryAfterMs);
      return;
    }
```

- [ ] **Step 3: Build, lint, test, commit**

```bash
cd Backend/functions && npm run build && npm run lint && npm test
cd /Users/peter/Desktop/Vibez
git add Backend/functions/src/index.ts
git commit -m "feat(backend): three-layer lazy rate limiter on /notify"
```

---

### Task 6: `index.ts` — 60s device-list cache

**Files:**
- Modify: `Backend/functions/src/index.ts`

- [ ] **Step 1: Add the cache + fetch helper**

After the limiter block from Task 5, add:

```ts
// ---- Device-list cache (design spec §4) ------------------------------

/** A device doc, trimmed to what /notify fan-out needs. */
interface CachedDevice {
  token: string;
  platform: string;
  blockSecondsDone?: unknown;
  blockSecondsNeedsInput?: unknown;
}

const DEVICE_CACHE_TTL_MS = 60_000;
const deviceCache = new BoundedMap<{
  devices: CachedDevice[]; fetchedAtMs: number;
}>(MAX_TRACKED_KEYS);

/**
 * Devices registered to a Vibez ID, cached per instance for 60s.
 * Empty results cache too — an unclaimed-ID spray costs ≤1 read per
 * minute per instance instead of 1 read per request. Accepted
 * staleness: a just-paired device or changed duration takes ≤60s to
 * be seen by an instance with a warm entry.
 * @param {string} vibezId The Vibez ID to look up.
 * @return {Promise<CachedDevice[]>} Registered devices (may be empty).
 */
async function getDevices(vibezId: string): Promise<CachedDevice[]> {
  const nowMs = Date.now();
  const cached = deviceCache.get(vibezId);
  if (cached && nowMs - cached.fetchedAtMs < DEVICE_CACHE_TTL_MS) {
    return cached.devices;
  }
  const snapshot = await tokensDb
    .collection(DEVICES)
    .where("vibezId", "==", vibezId)
    .get();
  const devices: CachedDevice[] = [];
  snapshot.forEach((doc) => {
    const token = doc.get("fcmToken");
    if (typeof token !== "string" || token.length === 0) return;
    devices.push({
      token,
      platform: typeof doc.get("platform") === "string" ?
        doc.get("platform") : "unknown",
      blockSecondsDone: doc.get("blockSecondsDone"),
      blockSecondsNeedsInput: doc.get("blockSecondsNeedsInput"),
    });
  });
  deviceCache.set(vibezId, {devices, fetchedAtMs: nowMs});
  return devices;
}
```

- [ ] **Step 2: Use it in the notify handler**

Replace the snapshot query + `snapshot.forEach` partitioning block (from `const snapshot = await tokensDb...` through the end of the `snapshot.forEach((doc) => {...});`) with:

```ts
    const devices = await getDevices(vibezId);
    // Partition by platform so each delivery path only runs when it
    // has a consumer: APNs for iOS tokens, a Firestore event-log write
    // for the browser extension. A web client id is never sent to FCM.
    const apnsTokens: string[] = [];
    let hasWeb = false;
    const scheduleUnblock = shouldScheduleUnblock({shield, session, event});
    const unblockTargets: {token: string; delaySeconds: number}[] = [];
    for (const device of devices) {
      if (device.platform === "web") {
        hasWeb = true;
      } else {
        apnsTokens.push(device.token);
        if (scheduleUnblock) {
          const durations = {
            done: clampDuration(device.blockSecondsDone, 30),
            needsInput: clampDuration(device.blockSecondsNeedsInput, 900),
          };
          unblockTargets.push({
            token: device.token,
            delaySeconds: delayForEvent(event, durations),
          });
        }
      }
    }
```

- [ ] **Step 3: Invalidate on sweep**

In the stale-token sweep block (`if (invalidTokens.length > 0) {...}`), after `await batch.commit();` add:

```ts
      // The cached list still holds the swept tokens — drop it so the
      // next push re-queries instead of re-failing for up to 60s.
      deviceCache.delete(vibezId);
```

- [ ] **Step 4: Build, lint, test, commit**

```bash
cd Backend/functions && npm run build && npm run lint && npm test
cd /Users/peter/Desktop/Vibez
git add Backend/functions/src/index.ts
git commit -m "feat(backend): per-instance 60s device-list cache, empty results included"
```

---

### Task 7: `registerPushToken` — caps, device cap, dry-run, rate limit

**Files:**
- Modify: `Backend/functions/src/index.ts` (the `registerPushToken` handler)

- [ ] **Step 1: Rewrite the handler body**

Replace the body of `registerPushToken` (everything inside `async (request) => {...}`, lines 55-105 in the current file) with:

```ts
    const data = request.data ?? {};
    const fcmToken = data.fcmToken;
    const vibezId = data.vibezId;
    const platform = normalizePlatform(data.platform);

    if (
      typeof fcmToken !== "string" ||
      fcmToken.length < MIN_FCM_TOKEN_LENGTH ||
      fcmToken.length > MAX_FCM_TOKEN_LENGTH
    ) {
      throw new HttpsError(
        "invalid-argument",
        "fcmToken must be a 20-512 char string"
      );
    }
    if (typeof vibezId !== "string" || !VIBEZ_ID_PATTERN.test(vibezId)) {
      throw new HttpsError(
        "invalid-argument",
        "vibezId must be 4 hyphenated 3-5 letter lowercase words"
      );
    }

    // Same three-layer limiter as /notify, separate per-ID bucket.
    const nowMs = Date.now();
    const ip = request.rawRequest?.ip ?? "unknown";
    if (!passesMemoryGuards(ip, nowMs)) {
      throw new HttpsError("resource-exhausted", "rate limited");
    }
    const limit = await checkKeyRateLimit(`register:${vibezId}`, nowMs);
    if (!limit.allowed) {
      throw new HttpsError("resource-exhausted", "rate limited");
    }

    const deviceRef = tokensDb.collection(DEVICES).doc(fcmToken);
    const existing = await deviceRef.get();
    if (!existing.exists) {
      // New device: bound growth per ID, then prove the token is real.
      const countSnap = await tokensDb
        .collection(DEVICES)
        .where("vibezId", "==", vibezId)
        .count()
        .get();
      if (countSnap.data().count >= MAX_DEVICES_PER_VIBEZ_ID) {
        throw new HttpsError(
          "resource-exhausted",
          "too many devices registered to this Vibez ID"
        );
      }
      // Dry-run FCM send: validates the token against THIS Firebase
      // project without delivering anything. Junk tokens can't create
      // docs at all — spray docs under unclaimed IDs would never be
      // swept (no /notify ever targets them). Web clients are exempt:
      // their "token" is an extension-generated id, not an FCM token
      // (never sent to FCM — see the /notify partitioning), so their
      // junk-doc bound is the rate limiter + device cap instead.
      if (platform !== "web") {
        try {
          await getMessaging().send({token: fcmToken, data: {v: "1"}}, true);
        } catch (e) {
          logger.info("dry-run token validation failed", {
            tokenPrefix: fcmToken.slice(0, 12),
            code: (e as {code?: string})?.code,
          });
          throw new HttpsError(
            "invalid-argument", "fcmToken failed FCM validation");
        }
      }
    }

    const deviceDoc: Record<string, unknown> = {
      fcmToken,
      vibezId,
      platform,
      createdAt: FieldValue.serverTimestamp(),
      lastSeen: FieldValue.serverTimestamp(),
    };
    if (data.blockSecondsDone !== undefined) {
      deviceDoc.blockSecondsDone = clampDuration(data.blockSecondsDone, 30);
    }
    if (data.blockSecondsNeedsInput !== undefined) {
      deviceDoc.blockSecondsNeedsInput =
        clampDuration(data.blockSecondsNeedsInput, 900);
    }

    await deviceRef.set(deviceDoc, {merge: true});
    // This instance's cached device list for the ID is now stale.
    deviceCache.delete(vibezId);

    logger.info("Registered push token", {
      platform,
      vibezId,
      tokenPrefix: fcmToken.slice(0, 12),
    });

    return {ok: true};
```

Note: `createdAt` is overwritten on re-registration by `set(..., {merge: true})` — that is the existing behavior, keep it (changing it is out of scope).

- [ ] **Step 2: Build, lint, test, commit**

```bash
cd Backend/functions && npm run build && npm run lint && npm test
cd /Users/peter/Desktop/Vibez
git add Backend/functions/src/index.ts
git commit -m "feat(backend): register caps, 10-device limit, FCM dry-run validation"
```

---

### Task 8: NSE — read title/body from `request.content`

**Files:**
- Modify: `VibezPushService/NotificationService.swift:91-92` and `:177-198`

- [ ] **Step 1: Switch the extraction site**

In `didReceive`, replace lines 91-92:

```swift
        let title = (userInfo["title"] as? String) ?? ""
        let body = (userInfo["body"] as? String) ?? ""
```

with:

```swift
        // title/body ride ONLY inside aps.alert on the wire (the
        // backend stopped duplicating them at the top level). iOS
        // pre-populates request.content from aps.alert before this
        // extension runs, so content IS the alert payload.
        let title = request.content.title
        let body = request.content.body
```

- [ ] **Step 2: Thread title/body into the App Group snapshot**

Replace the call site:

```swift
        if reason != "timeout" {
            writeLastMessageToAppGroup(
                userInfo: userInfo, identifier: request.identifier)
        }
```

with:

```swift
        if reason != "timeout" {
            writeLastMessageToAppGroup(
                userInfo: userInfo, title: title, body: body,
                identifier: request.identifier)
        }
```

and update `writeLastMessageToAppGroup` (lines 177-198): change the signature and the snapshot loop so the function reads:

```swift
    private func writeLastMessageToAppGroup(
        userInfo: [AnyHashable: Any],
        title: String,
        body: String,
        identifier: String
    ) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.vibezlol.Vibez"
        ) else { return }

        // The file keeps FLAT title/body keys on purpose: it is the
        // host drain contract (NotifyClient parses it with the same
        // top-level fallback it uses for legacy pushes). Only the
        // SOURCE changed — content (aps.alert) instead of userInfo.
        var dict: [String: Any] = [:]
        if !title.isEmpty { dict["title"] = title }
        if !body.isEmpty { dict["body"] = body }
        for key in ["event", "shield", "session", "agent"] {
            if let value = userInfo[key] as? String {
                dict[key] = value
            }
        }
        // `identifier` is the same value willPresent receives via
        // notification.request.identifier, so the host's processIfNew
        // dedup sees the same id whether the push lands via the
        // foreground willPresent path or via this file drain.
        dict["id"] = identifier
        dict["_writtenAt"] = Date().timeIntervalSince1970

        let url = containerURL.appendingPathComponent("last-message.json")
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: url, options: .atomic)
        }
    }
```

Also update the doc comment above the function (lines 171-176): replace "Snapshots only the top-level Vibez fields" with "Snapshots title/body from request.content plus the top-level Vibez routing fields".

- [ ] **Step 3: Commit** (build verified in Task 10)

```bash
cd /Users/peter/Desktop/Vibez
git add VibezPushService/NotificationService.swift
git commit -m "feat(nse): source title/body from request.content (aps.alert single copy)"
```

---

### Task 9: NotifyClient — parse `aps.alert`, keep flat fallback for the drain path

**Files:**
- Modify: `Vibez/NotifyClient.swift:114-149`

- [ ] **Step 1: Verify the drain path shape (read-only check)**

Run: `grep -n "drainPendingPushFromAppGroup\|acceptPushUserInfo" /Users/peter/Desktop/Vibez/Vibez/NotifyClient.swift /Users/peter/Desktop/Vibez/Vibez/VibezApp.swift`

Confirm the drain path feeds the `last-message.json` dict (flat `title`/`body` keys, no `aps`) back through `acceptPushUserInfo` (or an equivalent parse). This is why the top-level fallback below is **permanent**, not transitional. If the drain uses a separate parser, leave it untouched (it already reads flat keys) and note that in the commit message.

- [ ] **Step 2: Switch the parse + update the doc comment**

Replace lines 144-149:

```swift
        var msg = NtfyMessage(
            id: (userInfo["id"] as? String) ?? UUID().uuidString,
            title: (userInfo["title"] as? String) ?? "Vibez",
            body: (userInfo["body"] as? String) ?? "",
            receivedAt: Date()
        )
```

with:

```swift
        // Live pushes carry title/body ONLY inside aps.alert (the
        // backend stopped duplicating them at the top level). The flat
        // fallback is permanent, not transitional: the NSE's
        // last-message.json drain replays through this same parser
        // with flat keys (and pre-dedup pushes parse the same way).
        let alert = ((userInfo["aps"] as? [String: Any])?["alert"])
            as? [String: Any]
        var msg = NtfyMessage(
            id: (userInfo["id"] as? String) ?? UUID().uuidString,
            title: (alert?["title"] as? String)
                ?? (userInfo["title"] as? String) ?? "Vibez",
            body: (alert?["body"] as? String)
                ?? (userInfo["body"] as? String) ?? "",
            receivedAt: Date()
        )
```

And update the payload-shape doc comment (lines 118-131) to:

```swift
    /// Payload shape (sent by the Firebase /notify function — see
    /// Backend/functions/src/index.ts):
    /// ```json
    /// {
    ///   "aps": { "alert": { "title": "...", "body": "..." },
    ///            "sound": "default" },
    ///   "event":   "needs-input" | "done" | "replied",
    ///   "shield":  "on" | "off",
    ///   "session": "<session-id>",
    ///   "agent":   "cc" | "cx"
    /// }
    /// ```
    /// title/body live only in aps.alert; the NSE's App Group drain
    /// file uses flat top-level title/body keys instead (no aps), and
    /// this parser accepts both shapes.
```

- [ ] **Step 3: Commit** (build verified in Task 10)

```bash
cd /Users/peter/Desktop/Vibez
git add Vibez/NotifyClient.swift
git commit -m "feat(ios): parse push title/body from aps.alert with flat drain fallback"
```

---

### Task 10: iOS compile check

- [ ] **Step 1: Build for simulator**

Run from `/Users/peter/Desktop/Vibez`:

```bash
xcodebuild -project Vibez.xcodeproj -scheme Vibez \
  -sdk iphonesimulator -configuration Debug build -quiet
```

Expected: `BUILD SUCCEEDED` (the Vibez scheme builds the NSE + shield extension targets as dependencies). If the scheme name differs, list with `xcodebuild -list -project Vibez.xcodeproj`. Fix any compile errors in the two edited Swift files before proceeding — no commit for this task unless fixes were needed (then: `git add <fixed files> && git commit -m "fix(ios): compile fixes for aps.alert parse"`).

---

### Task 11: Plugins — defensive `clamp_field` in both `notify.sh`

**Files:**
- Modify: `ClaudePlugin/scripts/notify.sh` (post_vibez, ~line 74; selftest, ~line 624)
- Modify: `CodexPlugin/scripts/notify.sh` (post_vibez, ~line 72; selftest, ~line 498)

- [ ] **Step 1: Add the helper + wire into post_vibez (Claude plugin)**

In `ClaudePlugin/scripts/notify.sh`, directly above the `post_vibez()` function, add:

```bash
# Hard-cap a payload field at N chars with a trailing ellipsis. Call
# sites already clip for display (72/160); this is the defensive floor
# inside post_vibez itself so no future call site can bypass clipping.
# Server mirrors these caps (title 100 / body 200) and clamps too.
clamp_field() {
    local raw="$1" max="$2"
    if [ "${#raw}" -gt "${max}" ]; then
        printf '%s…' "${raw:0:$((max - 1))}"
    else
        printf '%s' "${raw}"
    fi
}
```

Inside `post_vibez()`, immediately after the six `local` declarations, add:

```bash
    title="$(clamp_field "${title}" 100)"
    body="$(clamp_field "${body}" 200)"
    session="${session:0:128}"
```

- [ ] **Step 2: Extend the Claude plugin selftest**

In the `_selftest` case arm, after the existing `clip-body-caps-at-160` check, add:

```bash
        long_field="$(printf 'a%.0s' $(seq 1 150))"
        check_eq "clamp-field-caps"     "$(clamp_field "${long_field}" 100)" "${long_field:0:99}…"
        check_eq "clamp-field-passes"   "$(clamp_field "short" 100)" "short"
```

- [ ] **Step 3: Run the Claude plugin selftest**

Run: `bash ClaudePlugin/scripts/notify.sh _selftest`
Expected: all PASS, exit 0 (now including `clamp-field-caps`, `clamp-field-passes`).

- [ ] **Step 4: Mirror in the Codex plugin**

In `CodexPlugin/scripts/notify.sh`: add the **same** `clamp_field()` function above `post_vibez()`, and the same three clamp lines at the top of `post_vibez()` after the `local` declarations.

The Codex `_selftest` has no `check_eq` helper — add it alongside `check` inside the `_selftest` arm:

```bash
        check_eq() {
            local name="$1" got="$2" expected="$3"
            if [ "${got}" = "${expected}" ]; then
                pass=$((pass+1))
                printf 'PASS %s\n' "$name"
            else
                fail=$((fail+1))
                printf 'FAIL %s (expected=[%s] got=[%s])\n' "$name" "$expected" "$got"
            fi
        }
        long_field="$(printf 'a%.0s' $(seq 1 150))"
        check_eq "clamp-field-caps"     "$(clamp_field "${long_field}" 100)" "${long_field:0:99}…"
        check_eq "clamp-field-passes"   "$(clamp_field "short" 100)" "short"
```

(Place the two `check_eq` calls after the existing `check` calls, before the final `printf '%d passed...'`.)

- [ ] **Step 5: Run the Codex plugin selftest**

Run: `bash CodexPlugin/scripts/notify.sh _selftest`
Expected: all PASS, exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/peter/Desktop/Vibez
git add ClaudePlugin/scripts/notify.sh CodexPlugin/scripts/notify.sh
git commit -m "feat(plugins): defensive clamp_field inside post_vibez, both plugins"
```

---

### Task 12: Deploy + TTL policy + curl verification matrix

**Prereqs:** Tasks 1-11 committed; Peter's machine is authed for `firebase`/`gcloud` on project `vibez-backend`.

- [ ] **Step 1: Deploy functions**

```bash
cd /Users/peter/Desktop/Vibez/Backend && npx firebase deploy --only functions
```

Expected: `notify`, `registerPushToken`, `dispatchUnblock` deploy green.

- [ ] **Step 2: Enable the rateLimits TTL policy**

```bash
gcloud firestore fields ttls update expireAt \
  --collection-group=rateLimits --database=tokens \
  --enable-ttl --project=vibez-backend
```

Expected: operation finishes with `ttlConfig.state: ACTIVE` (may take a few minutes; `--async` + later check is fine).

- [ ] **Step 3: Run the curl matrix** (replace `$URL` with `https://us-central1-vibez-backend.cloudfunctions.net/notify`, `$ID` with Peter's real Vibez ID, `$FAKE` with `aaaa-bbbb-cccc-dddd`)

| # | Command | Expected |
|---|---|---|
| 1 | `curl -si -X POST -H 'content-type: application/json' -d '{"vibezId":"'$ID'","title":"t","body":"b"}' $URL` | `200` `{"ok":true}` — and push lands on the phone |
| 2 | Same but `-d '{"vibezId":"'$FAKE'","title":"t","body":"b"}'` | `200` `{"ok":true}` — body byte-identical to #1 |
| 3 | Same as #1 but `"event":"explode"` | `400` `{"error":"invalid event"}` |
| 4 | Same as #1 but `"session":"has space"` | `400` `{"error":"invalid session"}` |
| 5 | `python3 -c "print('{\"vibezId\":\"'+'$ID'+'\",\"title\":\"t\",\"body\":\"'+'x'*9000+'\"}')" \| curl -si -X POST -H 'content-type: application/json' -d @- $URL` | `413` `{"error":"payload too large"}` |
| 6 | `for i in 1 2 3 4 5 6 7; do curl -s -o /dev/null -w '%{http_code} ' -X POST -H 'content-type: application/json' -d '{"vibezId":"'$FAKE'","title":"t","body":"b"}' $URL; done` | five `200`s then `429`s (allow ±1 for refill timing); a 429 response carries `Retry-After` |
| 7 | `curl -si -X POST -H 'content-type: application/json' -d '{"data":{"fcmToken":"garbage-token-aaaaaaaaaaaa","vibezId":"'$FAKE'","platform":"ios"}}' https://us-central1-vibez-backend.cloudfunctions.net/registerPushToken` | `400` callable error `INVALID_ARGUMENT` (dry-run reject) |
| 8 | Re-run #1 within 60s twice | both `200`; Cloud Logging shows one `notify fan-out` per request but only one Firestore device query (cache hit — optional log check) |

- [ ] **Step 4: On-device smoke (Peter)**

With the deployed backend and the new app build on the phone: trigger a real hook (or curl #1), confirm (a) banner shows correct title/body, (b) shield card shows correct title/body, (c) a `replied` push still lifts the shield. This proves the dedup'd payload end-to-end.

- [ ] **Step 5: Billing alert (manual, Peter)**

Console → Billing → Budgets & alerts → create budget on the project (e.g. $10/month, email alert). No CLI step — one-time console action.

---

### Task 13: Docs — CLAUDE.md + spec touch-up

**Files:**
- Modify: `CLAUDE.md` (Conventions + file map + pipeline section)
- Modify: `docs/superpowers/specs/2026-06-04-backend-hardening-design.md` (§3)

- [ ] **Step 1: CLAUDE.md**

In the file map under `Backend/functions/src/`, add lines for `ratelimit.ts` ("pure token-bucket + lazy-escalation math; in-memory maps + Firestore `rateLimits` glue live in index.ts") and `validation.ts` ("pure request validation: caps, whitelists, clamps; owns VIBEZ_ID_PATTERN server-side").

In **Conventions**, update the Vibez ID pattern mirror list (`Backend/functions/src/index.ts` → `Backend/functions/src/validation.ts`) and add a convention bullet:

```markdown
- **Backend abuse limits (design spec 2026-06-04):** /notify and
  registerPushToken are rate limited per Vibez ID (token bucket, burst 5,
  refill 1/sec, lazy Firestore escalation in the `rateLimits` collection,
  24h TTL), per IP (20/5s, in-memory), and per instance (200/100s,
  in-memory). Caps: title 100 / body 200 chars (clamped), 8 KB request,
  event/shield/agent whitelisted, session `^[A-Za-z0-9._:-]{1,128}$`,
  ≤10 devices per ID, FCM dry-run validates new non-web tokens.
  /notify always answers `{ok: true}` (no claimed/unclaimed oracle).
  `maxInstances: 3` is the compute ceiling. APNs payloads carry
  title/body ONLY in aps.alert; the NSE App Group drain file keeps flat
  keys (NotifyClient parses both shapes).
```

- [ ] **Step 2: Spec touch-up (web carve-out)**

In the spec's §3 dry-run bullet, after "failure → `invalid-argument`.", insert: "Web registrations are exempt — their 'token' is an extension-generated id, never sent to FCM; their junk-doc bound is the rate limiter + device cap instead."

- [ ] **Step 3: Commit**

```bash
cd /Users/peter/Desktop/Vibez
git add CLAUDE.md docs/superpowers/specs/2026-06-04-backend-hardening-design.md
git commit -m "docs: record backend abuse limits + payload shape in CLAUDE.md"
```

---

## Self-review (run after writing, fixed inline)

**Spec coverage:** §1 limiter → Tasks 1, 5 (+ register in 7); §2 caps/validation/uniform response → Tasks 2, 4; §3 register caps/dry-run/device cap → Task 7; §4 device cache → Task 6; §5 dedup → Tasks 3, 8, 9; §6 plugins → Task 11; §7 config (maxInstances → Task 4, TTL + billing alert → Task 12); §8 testing → Tasks 1-3 (unit), 10 (compile), 11 (selftest), 12 (curl + smoke); §9/§10 → Task 13. No gaps.

**Known intentional deviations from current code:** `errors` array removed from /notify response (uniform response supersedes it); `VIBEZ_ID_PATTERN`/`MIN_FCM_TOKEN_LENGTH` move to validation.ts.
