# Backend Hardening: Rate Limiting, Payload Caps, APNs Dedup

**Date:** 2026-06-04
**Status:** Approved (pending implementation plan)

## Goal

Make the Vibez backend safe to expose at real-user scale: a leaked or guessed
Vibez ID, a buggy hook loop, or a hostile `curl` user must not be able to spam
a phone, inflate Firestore storage, or run up the bill. Simultaneously, strip
the one genuine redundancy in the push pipeline (title/body sent twice per
push) and keep marginal cost per push near zero.

Out of scope: App Check on `registerPushToken` (already on the App Store
roadmap), any auth on `/notify` (a shell script has no device attestation —
the 44-bit Vibez ID + rate limiting *is* its defense), RTDB-backed limiting
(rejected: adds a second database product), Mac-side hardware/machine IDs
(rejected: unattestable from a shell script, so spoofable by definition —
pure privacy cost), edge WAF / Cloud Armor (the someday-tool if botnet abuse
ever materializes; billing alert is the tripwire until then).

## Decision log

| Decision | Choice | Why |
|---|---|---|
| Rate limit shape | Token bucket, **burst 5, refill 1/sec, per Vibez ID** | Strict 1/sec drops the 2nd of two simultaneous Stop hooks (parallel sessions share one ID); burst 5 absorbs that, sustained spam still dies |
| Limiter architecture | **Lazy escalation** (in-memory first, Firestore global bucket only under local over-rate) | Limiter as originally designed cost more Firestore ops than the work it protected; lazy = $0 for legit traffic, correct under floods |
| Oversized title/body | **Clamp** (truncate + ellipsis), don't reject | Matches plugin behavior; third-party clients degrade gracefully |
| Bad enum / bad session | **Reject 400** | Wrong enums = buggy or malicious caller; tell them |
| Limiter infra failure | **Fail open** (deliver push, log warn) | Peter's pushes matter more than strictness; attackers can't induce Firestore outages |
| APNs duplication | **Remove** (aps.alert is the single copy) | ~35% of every push was the same two strings twice — ntfy-era parse-shape leftover |
| `maxInstances` | 10 → **3** | One instance at concurrency 80 covers ~1,000 users; 3 is headroom. Caps worst-case compute bill and shrinks in-memory limiter leak from 10× to 3× |
| Unclaimed-ID probes | **Uniform `{ok: true}` response** for every valid-format request | `{total: 0}` vs `{total: 1}` was a free claimed/unclaimed oracle (and `errors` leaked FCM strings); nothing client-side parses the body — both plugins' curl discards it (verified) |
| Junk device docs | **FCM dry-run validation** before storing a new token | Spray-registered docs under unclaimed IDs are never swept (no notify ever targets them, so the stale-token sweep never runs); dry-run makes garbage tokens unstorable. Free |
| Botnet-scale spray | **Global per-instance load-shed bucket** + GCP billing alert | Per-IP guards can't see a thousand IPs each under 5/sec; this caps worst-case Firestore reads at ~$10/day |
| Mac hardware IDs | **Rejected** | A shell script can't attest — any self-reported machine ID is spoofable by definition, and it adds privacy surface pre-App-Store-review. App Check (roadmap) is the real attestation story, and only the iOS callable can have it |

## 1. Rate limiting (lazy escalation)

### Bucket math — new pure module `Backend/functions/src/ratelimit.ts`

No firebase imports (unit-testable like `scheduling.ts`):

```ts
export interface BucketState { tokens: number; lastRefillMs: number; }
export const BUCKET = { capacity: 5, refillPerSec: 1 };
export function refill(s: BucketState, nowMs: number): BucketState;
// take one token if available; returns the next state either way
export function tryTake(s: BucketState | undefined, nowMs: number):
  { allowed: boolean; next: BucketState; retryAfterMs: number };
```

### Keys and storage

- Bucket keys: `notify:{vibezId}` and `register:{vibezId}` (separate buckets).
- Global state: Firestore `tokens` db, new collection `rateLimits`, doc id =
  key, fields `{ tokens, lastRefillMs, expireAt }`. Server-only — already
  covered by the rules file's deny-all default. `expireAt = now + 24h`,
  refreshed on every write; a Firestore TTL policy on `rateLimits.expireAt`
  garbage-collects idle docs.
- Per-instance state per key (in-memory `Map`, insertion-order, capped at
  50,000 entries, evict-oldest): `{ local: BucketState, escalatedUntilMs,
  denyUntilMs }`.

### Decision flow per request

1. **Negative cache:** `now < denyUntilMs` → deny `429` (no I/O). The window
   is `retryAfterMs` from the last global deny (≤ 1s at these params) — after
   a global deny, no token can exist anywhere for that long, so this can
   never falsely deny.
2. **Local fast path:** if not escalated (`now ≥ escalatedUntilMs`): refill
   local bucket; if a token is available → take it, **allow, zero Firestore
   ops**. This is the path all legitimate traffic takes.
3. **Escalation:** local bucket empty, or escalation window active → set
   `escalatedUntilMs = now + 60s` (sliding) and run one Firestore
   transaction on `rateLimits/{key}`: read (absent doc = full bucket),
   `tryTake`, on allow write the new state, on deny write nothing and set
   `denyUntilMs = now + retryAfterMs`.
4. **Fail-open:** transaction error → allow, `logger.warn`.

Deny responses: `429 {error: "rate limited"}` + `Retry-After: 1` header
(`/notify`); `HttpsError("resource-exhausted")` for the callable.

### Documented worst cases (accepted)

- **Spread low-and-slow attacker** keeping each instance under 1/sec never
  escalates: leak ≤ `maxInstances × refill` = **~3/sec sustained**. Bounded,
  push-spam-only; any burst engages the global bucket.
- **Escalation-onset burst:** local 5 + global 5 ≈ 10 pushes through one
  instance before sustained 1/sec enforcement. Accepted.

### Secondary per-IP guard (in-memory only)

Random valid-format Vibez IDs bypass per-ID buckets (every ID is fresh), so
both endpoints also run a per-instance, per-IP token bucket (capacity 20,
refill 5/sec, same bounded-Map infrastructure; keyed on the LAST
X-Forwarded-For entry — `req.ip` is the internal proxy, constant across
callers, verified live). Bounds single-source floods and ID-spray to
~15 req/sec fleet-wide (≈ $1/day worst case); a real Mac's hooks never get
near it. In-memory only — no Firestore escalation for IPs (cardinality too
high, and `maxInstances: 3` already caps the absolute ceiling).

### Global load-shed bucket (in-memory only)

Last-resort ceiling over **all** traffic per instance, regardless of key:
capacity 200, refill 100/sec (≈ 300/sec fleet-wide, vs ~30/sec projected
legit peak at 1,000 users). Only botnet-scale sprays — many IPs, each under
the per-IP rate — can trip it; it bounds their worst-case Firestore read
bill at roughly $10/day instead of low hundreds. Same bucket code, key
`"global"`. Ops pair: the GCP billing alert in §7 is the human tripwire.

## 2. `/notify` request validation

Checks in cost order, cheapest first; Firestore is touched only after all
pass. Unknown body fields are ignored (never forwarded); `reason` is never
accepted from clients — only `dispatchUnblock` sets it, internally.

| # | Check | Rule | On violation |
|---|---|---|---|
| 1 | Method | `POST` | 405 (existing) |
| 2 | `Content-Length` | ≤ 8192 bytes | **413** |
| 3 | `vibezId` | `^[a-z]{3,5}(-[a-z]{3,5}){3}$` (existing) | 400 |
| 4 | `event` | `needs-input \| done \| replied` | **400** |
| 5 | `shield` | `on \| off` | **400** |
| 6 | `agent` | `cc \| cx` | **400** |
| 7 | `session` | `^[A-Za-z0-9._:-]{1,128}$` | **400** |
| 8 | `title` | required non-empty; **clamp to 100 chars** + `…` | 400 if missing; clamped if oversized |
| 9 | `body` | required non-empty; **clamp to 200 chars** + `…` | 400 if missing; clamped if oversized |
| 10 | Per-IP guard | §1 | 429 |
| 11 | Per-ID bucket | §1 | 429 |

**Response shape:** every accepted request — claimed or unclaimed ID alike —
returns the same `200 {ok: true}`. Fan-out counts and FCM error details move
to server logs only. The old `{total, success, failure, errors}` body was a
claimed/unclaimed enumeration oracle and leaked FCM error strings; nothing
client-side ever parsed it (both plugins discard the response body —
verified). Residual timing oracle (claimed IDs do more work) accepted: 44-bit
space + per-IP caps make enumeration impractical.

Server caps (100/200) deliberately sit above plugin caps (72/160): the
plugins' own clipping stays operative; the server is the safety net for
non-plugin clients. Validation + clamp helpers go in a pure module
(`validation.ts`) with table-driven tests. If `Content-Length` is absent
(chunked), field clamps still bound everything stored or forwarded; during
implementation, verify what body-size limit the firebase-functions parser
itself enforces and note it in code.

## 3. `registerPushToken` validation

- `fcmToken`: existing min 20 → add **max 512** chars (real tokens ~163),
  else `invalid-argument`.
- `platform`: whitelist `ios | web`; anything else coerced to `"unknown"`
  (no arbitrary strings stored).
- `blockSeconds*`: existing `clampDuration` (unchanged).
- **Device cap:** when the `fcmToken` doc does *not* already exist, aggregate
  count of `devices where vibezId == X`; **≥ 10 → `resource-exhausted`**.
  Re-registering an existing token is always allowed (update, not growth).
  `/notify`'s stale-token sweep frees slots naturally.
- **FCM dry-run validation:** also only when the doc does not already exist —
  validate the token with a dry-run FCM send (no delivery, free, ~50ms)
  before storing; failure → `invalid-argument`. Closes the worst spray hole:
  junk docs under unclaimed Vibez IDs are never targeted by `/notify`, so
  the stale-token sweep would never reclaim them. With dry-run they can't
  be created at all; an attacker would need real FCM tokens minted against
  this Firebase project (App Check on the roadmap closes that too). Only
  token-invalidity codes reject; transient FCM/infra errors fail open (a
  first pairing must not break on an FCM blip — the limiter + device cap
  still bound junk). Web registrations are exempt — their 'token' is an
  extension-generated id, never sent to FCM; their junk-doc bound is the
  rate limiter + device cap instead.
- Rate limited via `register:{vibezId}` bucket + per-IP guard (§1).

## 4. Device-list cache (cost lever)

Per-instance `Map<vibezId, { devices: DeviceRecord[], fetchedAtMs }>`,
**TTL 60s**, same 50K-entry bound. `DeviceRecord` carries token, platform,
and both blockSeconds fields (needed for unblock targets). Empty results are
cached too — an unclaimed-ID spray costs ≤ 1 read/min/instance/ID instead of
1 read per request. The invalid-token sweep drops the entry for that vibezId
on the local instance. Accepted staleness: a just-paired device or a changed
block duration takes ≤ 60s to be seen by an instance with a warm entry.

## 5. APNs payload dedup

Today every push carries `title`/`body` twice: in `aps.alert` (required by
iOS to render the banner) and again as top-level custom fields — an ntfy-era
parse-shape leftover. After this change each field appears exactly once:

- **`scheduling.ts`** — `buildApnsPayload` stops emitting top-level
  `title`/`body`; `VibezApnsPayload` drops those properties. `event`,
  `shield`, `session`, `agent`, `reason` remain top-level (genuinely custom
  fields; APNs has nowhere else for them).
- **NSE** (`VibezPushService/NotificationService.swift`) — both reads of
  `userInfo["title"/"body"]` (banner-rewrite path ~line 91 and the App Group
  snapshot path ~line 183) switch to `request.content.title/.body`, which
  iOS pre-populates from `aps.alert` before the extension runs. The App
  Group dict **schema is unchanged** — `"title"`/`"body"` keys are still
  written; only their source changes (the 3-site shieldState contract in
  CLAUDE.md is untouched).
- **`Vibez/NotifyClient.swift:146`** — parse
  `userInfo["aps"]["alert"]["title"/"body"]` via safe casts, with a one-line
  fallback to the old top-level keys so deploy order can't strand a stale
  build.
- Web path unaffected: the Firestore `events` docs already carry their own
  single copy.

Net: push payload shrinks ~35% (~250 bytes), nothing in the pipeline is sent
twice.

## 6. Plugin-side

Audit result: every existing call site already clips (title 72, body 160,
prompt 80) — no live gap. One defensive change in **both** plugins' `notify.sh`:
clamp inside `post_vibez` itself (title 100, body 200, session 128 chars,
ellipsis on title/body) so no future call site can bypass clipping. The
existing 5s curl timeout + swallow-all-failures behavior already handles 429
correctly (log, never block the agent). Extend `_selftest` with clamp cases.

## 7. Config changes

- `setGlobalOptions({maxInstances: 3})` (was 10).
- Firestore TTL policy on collection group `rateLimits`, field `expireAt`,
  database `tokens` (gcloud one-liner; `events.items` TTL already exists).
- GCP billing alert on the project (e.g. $10/month threshold) — the human
  tripwire for botnet-scale abuse that in-process guards can only bound,
  not block.

## 8. Testing

- **Pure unit tests** (`functions/test/`): `ratelimit.test.ts` (refill cap,
  burst drain, partial refill, deny window / retryAfterMs, escalation
  decision), `validation.test.ts` (table-driven field matrix, clamp
  boundaries incl. multi-byte chars), `scheduling.test.ts` updated to assert
  **no** top-level title/body in built payloads.
- **Curl matrix** against the deployed backend: 9KB body → 413; bad
  enum/session → 400; 6 rapid POSTs → five 200s + one 429 with
  `Retry-After`; valid push → 200 and lands on the phone; 11th device
  registration → resource-exhausted; garbage-token registration →
  invalid-argument (dry-run reject); claimed vs unclaimed ID →
  byte-identical `{ok: true}` bodies.
- **iOS**: `xcodebuild` compile against `iphonesimulator26.4`; on-device
  smoke (banner + shield card render correct title/body post-dedup — Peter
  taps through).
- **Plugins**: `bash notify.sh _selftest` green on both plugins.

## 9. Cost model (the "viable at thousands of users" answer)

At 1,000 heavy users (~300 pushes/day each): Cloud Run compute + invocations
**~$1–1.5/day** (dominant, exists under any design, capped by
`maxInstances: 3`); device lookups with 60s cache **~$0.05/day**; limiter
**~$0** for legit traffic (lazy); Cloud Tasks + web event writes ~$0.10/day.
At current scale every line is $0 (permanent free tiers). Storage bounded by:
device cap (≤10 docs/ID), `rateLimits` TTL (24h), `events` TTL (24h),
stale-token sweep.

## 10. Files touched

| File | Change |
|---|---|
| `Backend/functions/src/ratelimit.ts` | new — pure bucket math |
| `Backend/functions/src/validation.ts` | new — pure field validation/clamps |
| `Backend/functions/src/index.ts` | wire limiter + guards + caches + caps; maxInstances 3 |
| `Backend/functions/src/scheduling.ts` | drop top-level title/body |
| `Backend/functions/test/*` | new + updated tests |
| `VibezPushService/NotificationService.swift` | title/body from `request.content` |
| `Vibez/NotifyClient.swift` | parse `aps.alert`, fallback |
| `ClaudePlugin/scripts/notify.sh` | post_vibez clamp + selftest |
| `CodexPlugin/scripts/notify.sh` | post_vibez clamp + selftest |
| `CLAUDE.md` | conventions: limits, caps, payload shape |
