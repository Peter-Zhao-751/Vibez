import {setGlobalOptions} from "firebase-functions";
import {onCall, onRequest, HttpsError} from "firebase-functions/https";
import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {getMessaging, BatchResponse} from "firebase-admin/messaging";
import * as logger from "firebase-functions/logger";
import {
  clampDuration,
  delayForEvent,
  shouldScheduleUnblock,
  buildApnsPayload,
  APNS_HEADERS,
} from "./scheduling.js";
import {getFunctions} from "firebase-admin/functions";
import {onTaskDispatched} from "firebase-functions/tasks";
import {
  validateNotifyBody,
  VIBEZ_ID_PATTERN,
  MAX_CONTENT_LENGTH_BYTES,
  MIN_FCM_TOKEN_LENGTH,
  normalizePlatform,
  MAX_FCM_TOKEN_LENGTH,
  MAX_DEVICES_PER_VIBEZ_ID,
} from "./validation.js";
import {
  ID_BUCKET,
  IP_BUCKET,
  GLOBAL_BUCKET,
  BucketState,
  BoundedMap,
  LazyLimiter,
  type TakeResult,
  sanitizeBucketState,
  tryTake,
} from "./ratelimit.js";

initializeApp();
// 3 instances × concurrency 80 is generous for ~1,000 users (~3.5
// req/s average). This is the hard cap on the worst-case compute bill
// AND the in-memory limiter leak factor (design spec §1, §7).
setGlobalOptions({maxInstances: 3});

// Vibez push state lives in a non-default Firestore database named
// "tokens" (Standard edition), in a single collection `devices`. Each
// document is keyed by the FCM registration token and carries the
// user's chosen Vibez ID — a 4-word slug that pairs a phone with a Mac.
const tokensDb = getFirestore("tokens");
const DEVICES = "devices";

// FCM's sendEachForMulticast caps at 500 tokens per call. Above that we
// chunk and accumulate. Vibez is personal-scale; defensive ceiling.
const MULTICAST_CHUNK = 500;

// ---- Rate limiting (design spec §1) ----------------------------------
// Three layers, all in cost order: per-IP and per-instance-global are
// in-memory only; the per-Vibez-ID bucket is lazy — in-memory fast
// path, Firestore-coordinated only while a key is over-rate locally.

const RATE_LIMITS = "rateLimits";

/** Idle limiter docs self-delete via the TTL policy on expireAt. */
const LIMITER_DOC_TTL_MS = 24 * 60 * 60 * 1000;

/** Bound for every attacker-keyed in-memory map (~5 MB worst case). */
const MAX_TRACKED_KEYS = 50_000;

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
 * One token-take against the shared Firestore bucket for this key.
 * Reads are sanitized so a corrupted doc degrades to a fresh bucket
 * (self-heals on the next allow-write) instead of a permanent deny.
 * @param {string} key Rate-limit key.
 * @param {number} nowMs Current epoch millis.
 * @return {Promise<TakeResult>} The take outcome.
 */
async function takeFromSharedBucket(
  key: string, nowMs: number,
): Promise<TakeResult> {
  const ref = tokensDb.collection(RATE_LIMITS).doc(key);
  return tokensDb.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const state = sanitizeBucketState(snap.data());
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
}

const keyLimiter = new LazyLimiter(
  MAX_TRACKED_KEYS,
  ID_BUCKET,
  takeFromSharedBucket,
  (key, err) => logger.warn("rate limiter unavailable — failing open", {
    key, err: String(err),
  }),
);

/**
 * Real client IP for direct Cloud Functions invocations. The
 * functions framework leaves Express "trust proxy" false, so req.ip
 * is the internal proxy — the SAME for every caller — which would
 * turn a per-IP bucket into a global choke point. On this topology
 * (direct cloudfunctions.net, no external LB) the GFE appends the
 * actual TCP peer as the LAST X-Forwarded-For entry; earlier entries
 * are client-forgeable. Re-derive if an external LB is ever added.
 * @param {object} req Express-style request.
 * @return {string} Best-effort client IP.
 */
function clientIp(req: {
  headers: Record<string, string | string[] | undefined>;
  ip?: string;
}): string {
  const xff = req.headers["x-forwarded-for"];
  const raw = Array.isArray(xff) ? xff[xff.length - 1] : xff;
  const last = raw?.split(",").pop()?.trim();
  return last || req.ip || "unknown";
}

/**
 * Shared 429 shaping: logged layer + finite second-granular
 * Retry-After (non-finite input clamps to 1s).
 * @param {object} res Express-style response.
 * @param {number} retryAfterMs Suggested wait in millis.
 * @param {string} layer Which guard fired ("memory" | "id").
 * @param {string} key Limited key (ip or vibezId), for the log line.
 */
function respondRateLimited(
  res: {
    set: (k: string, v: string) => unknown;
    status: (n: number) => {json: (b: unknown) => void};
  },
  retryAfterMs: number,
  layer: string,
  key: string,
): void {
  const ms = Number.isFinite(retryAfterMs) ? retryAfterMs : 1000;
  logger.info("rate limited", {layer, key});
  res.set("Retry-After", String(Math.max(1, Math.ceil(ms / 1000))));
  res.status(429).json({error: "rate limited"});
}

// ---- Device-list cache (design spec §4) ------------------------------

/** A device doc, trimmed to what /notify fan-out needs. */
interface CachedDevice {
  token: string;
  platform: string;
  blockSecondsDone?: unknown;
  blockSecondsNeedsInput?: unknown;
}

const DEVICE_CACHE_TTL_MS = 60_000;
// Per-value: CachedDevice[] is bounded by the 10-device cap on
// registerPushToken; worst-case per-instance footprint is
// MAX_TRACKED_KEYS × 10 × ~200 B ≈ 100 MB before BoundedMap eviction.
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
  // Two concurrent misses for the same ID both query Firestore — last
  // write wins on set(); harmless, costs one extra read at warm-up.
  const snapshot = await tokensDb
    .collection(DEVICES)
    .where("vibezId", "==", vibezId)
    .get();
  const devices: CachedDevice[] = [];
  snapshot.forEach((doc) => {
    const token = doc.get("fcmToken");
    if (typeof token !== "string" || token.length === 0) return;
    const rawPlatform = doc.get("platform");
    devices.push({
      token,
      platform: typeof rawPlatform === "string" ? rawPlatform : "unknown",
      blockSecondsDone: doc.get("blockSecondsDone"),
      blockSecondsNeedsInput: doc.get("blockSecondsNeedsInput"),
    });
  });
  deviceCache.set(vibezId, {devices, fetchedAtMs: nowMs});
  return devices;
}

/**
 * Callable: invoked by the iOS app on every fresh FCM token AND every
 * time the user enters/changes their Vibez ID. Persists both to
 * Firestore so the /notify HTTP function can fan a push out to the
 * device(s) that match a given ID.
 *
 * Idempotent — re-registering the same fcmToken just refreshes
 * lastSeen and overwrites vibezId. Multiple devices can share a
 * Vibez ID (e.g., iPhone + iPad).
 *
 * Open / unauthenticated by design — the Vibez ID itself is the
 * shared secret in the same way an ntfy topic name was. App Check
 * is the natural next layer when we ship. Hardened per design spec §3:
 * token length caps, per-ID device cap, FCM dry-run validation for new
 * non-web tokens, and the shared rate limiter.
 */
export const registerPushToken = onCall(
  {invoker: "public"},
  async (request) => {
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
    const ip = clientIp(request.rawRequest);
    if (!passesMemoryGuards(ip, nowMs)) {
      throw new HttpsError("resource-exhausted", "rate limited");
    }
    const limit = await keyLimiter.check(`register:${vibezId}`, nowMs);
    if (!limit.allowed) {
      logger.info("rate limited", {layer: "id", key: vibezId});
      throw new HttpsError("resource-exhausted", "rate limited");
    }

    const deviceRef = tokensDb.collection(DEVICES).doc(fcmToken);
    const existing = await deviceRef.get();
    if (!existing.exists) {
      // New device: bound growth per ID, then prove the token is real.
      // The cap is best-effort under concurrency (existence + count +
      // write are non-transactional); the register: bucket bounds the
      // overshoot to ~burst size, which is fine for an abuse bound.
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
          const code = (e as {code?: string})?.code;
          logger.info("dry-run token validation failed", {
            tokenPrefix: fcmToken.slice(0, 12),
            code,
          });
          // Reject only when FCM says the TOKEN is bad. Transient or
          // project-level errors fail OPEN — a first pairing must not
          // break on an FCM blip; the rate limiter + device cap still
          // bound junk docs, and /notify's sweep reclaims dead tokens.
          const tokenInvalid =
            code === "messaging/registration-token-not-registered" ||
            code === "messaging/invalid-registration-token" ||
            code === "messaging/invalid-argument";
          if (tokenInvalid) {
            throw new HttpsError(
              "invalid-argument", "fcmToken failed FCM validation");
          }
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
  }
);

/**
 * HTTP: the plugin's hook script POSTs lifecycle events here. Body:
 *
 *   {
 *     "vibezId": "moss-pine-fox-jazz",  // required, identifies recipient
 *     "title":   "...",                  // required, conversation title
 *     "body":    "...",                  // required, excerpt or question
 *     "event":   "needs-input" | "done" | "replied",   // optional
 *     "shield":  "on" | "off",                          // optional
 *     "session": "<cli session id>",                    // optional
 *     "agent":   "cc" | "cx"                            // optional
 *   }
 *
 * We look up every device registered to that Vibez ID and fan an FCM
 * push out to each. Visibility is controlled by the shield axis,
 * matching the user-facing expectation from the ntfy era — only agent
 * events surface as banners, user replies are silent:
 *
 *   shield:on / shield:nil → alert + content-available push. iOS
 *     auto-banner shows in foreground (via willPresent) and background.
 *   shield:off → background push only. App is woken to lift the
 *     shield via handleIncoming, but iOS displays no banner.
 */
export const notify = onRequest(
  {invoker: "public"},
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({error: "method not allowed"});
      return;
    }

    // Cheapest checks first; Firestore is touched only after all pass
    // (design spec §2). NOTE: the body is already parsed by the time
    // this handler runs, and the functions-framework's own parser cap
    // is ~1 GB — so this 413 is a courtesy gate for honest oversized
    // clients, NOT the security bound. The real bounds are the field
    // clamps below, the rate limiter, and maxInstances. A missing or
    // unparseable Content-Length deliberately falls through to field
    // validation.
    const rawLength = req.headers["content-length"];
    const contentLength = Number.parseInt(
      Array.isArray(rawLength) ? rawLength[0] : rawLength ?? "", 10);
    if (Number.isFinite(contentLength) &&
        contentLength > MAX_CONTENT_LENGTH_BYTES) {
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

    const nowMs = Date.now();
    const ip = clientIp(req);
    if (!passesMemoryGuards(ip, nowMs)) {
      respondRateLimited(res, 1000, "memory", ip);
      return;
    }
    const limit = await keyLimiter.check(`notify:${vibezId}`, nowMs);
    if (!limit.allowed) {
      respondRateLimited(res, limit.retryAfterMs, "id", vibezId);
      return;
    }

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

    if (apnsTokens.length === 0 && !hasWeb) {
      // 200, not 404 — a Mac firing into an unclaimed Vibez ID isn't an
      // error condition. The user might just not have set up their phone
      // or browser yet. The plugin doesn't need to log a failure for this.
      // Uniform body — a claimed/unclaimed distinction here would be a
      // free enumeration oracle (design spec §2). Counts live in logs.
      res.status(200).json({ok: true});
      return;
    }

    // Custom fields go at the top level of apns.payload (siblings of
    // aps). That's how iOS surfaces them in userInfo, matching the
    // shape NotifyClient.acceptPushUserInfo and the NSE's didReceive
    // both expect.
    //
    // Shield axis controls visibility:
    //   shield:off (user just replied) → alert push with
    //     interruption-level=passive. No banner, no sound, no screen
    //     wake — the entry slips silently into notification center —
    //     BUT the NSE still fires (it only fires for alert-type
    //     pushes), which is what actually drops the shield for that
    //     session while Vibez is suspended.
    //   shield:on / shield:nil (agent event) → standard alert push,
    //     banner is auto-displayed after the NSE rewrites title/body.
    //
    // mutable-content:1 on EVERY push is what makes the Notification
    // Service Extension (VibezPushService) run before iOS shows the
    // banner. That extension is the only reliable way to engage (or
    // lift) the shield while Vibez is suspended — iOS 26 stopped firing
    // the host app's didReceiveRemoteNotification for background-delivered
    // pushes, even with content-available:1. Silent (apns-push-type:
    // background) pushes also do NOT invoke the NSE, which is why
    // shield:off has to ride on an alert push.
    const apnsPayload = buildApnsPayload({
      title,
      body: bodyText,
      event,
      shield,
      session,
      agent,
    });
    const apnsHeaders = APNS_HEADERS;

    let success = 0;
    let failure = 0;
    const invalidTokens: string[] = [];

    for (let i = 0; i < apnsTokens.length; i += MULTICAST_CHUNK) {
      const chunk = apnsTokens.slice(i, i + MULTICAST_CHUNK);
      const response: BatchResponse =
        await getMessaging().sendEachForMulticast({
          tokens: chunk,
          apns: {headers: apnsHeaders, payload: apnsPayload},
        });
      success += response.successCount;
      failure += response.failureCount;

      response.responses.forEach((resp, idx) => {
        if (!resp.success) {
          const code = resp.error?.code;
          const errMessage = resp.error?.message;
          logger.warn("FCM send failed", {
            tokenPrefix: chunk[idx].slice(0, 12),
            code,
            errMessage,
          });
          if (
            code === "messaging/registration-token-not-registered" ||
            code === "messaging/invalid-argument"
          ) {
            invalidTokens.push(chunk[idx]);
          }
        }
      });
    }

    logger.info("notify fan-out", {
      vibezId,
      event,
      total: apnsTokens.length,
      success,
      failure,
      web: hasWeb,
    });

    // Sweep stale tokens out of Firestore so /notify doesn't keep
    // retrying them on every push. Cheap because we already have the
    // doc IDs (they ARE the tokens).
    if (invalidTokens.length > 0) {
      logger.warn("Sweeping stale FCM tokens", {count: invalidTokens.length});
      const batch = tokensDb.batch();
      invalidTokens.forEach((tok) => {
        batch.delete(tokensDb.collection(DEVICES).doc(tok));
      });
      await batch.commit();
      // The cached list still holds the swept tokens — drop it so the
      // next push re-queries instead of re-failing for up to 60s.
      // (An in-flight getDevices may re-set a stale list; it self-heals
      // on the next push and the 60s TTL caps the window.)
      deviceCache.delete(vibezId);
    }

    // Schedule the per-session timeout unblock (backup layer): one Cloud
    // Task per device, each at that device's own duration + buffer. Best-
    // effort — a failed enqueue just falls back to the on-device prune,
    // so we never fail the /notify response on it.
    if (scheduleUnblock && unblockTargets.length > 0) {
      // taskQueue("dispatchUnblock") resolves the queue for the function
      // in the default region (us-central1). If a deploy ever moves the
      // function, use "locations/<region>/functions/dispatchUnblock".
      const queue = getFunctions().taskQueue("dispatchUnblock");
      await Promise.all(unblockTargets.map((t) =>
        queue.enqueue(
          {
            fcmToken: t.token,
            vibezId,
            session,
            event,
            agent,
            title,
            body: bodyText,
          },
          {scheduleDelaySeconds: t.delaySeconds}
        ).catch((err) => logger.warn("enqueue unblock failed", {
          session,
          err: String(err),
        }))
      ));
    }

    // Browser extension(s) registered to this Vibez ID read events from a
    // Firestore log rather than APNs — Firestore can't wake a suspended iOS
    // app, so the phone stays on APNs and this write is purely additive. The
    // path is keyed by the Vibez ID (which is the shared secret); a TTL
    // policy on `expireAt` auto-expires old events.
    if (hasWeb) {
      const now = Date.now();
      const item: Record<string, unknown> = {
        title,
        body: bodyText,
        createdAtMs: now,
        createdAt: FieldValue.serverTimestamp(),
        expireAt: Timestamp.fromMillis(now + 24 * 60 * 60 * 1000),
      };
      if (event !== undefined) item.event = event;
      if (shield !== undefined) item.shield = shield;
      if (session !== undefined) item.session = session;
      if (agent !== undefined) item.agent = agent;
      await tokensDb
        .collection("events").doc(vibezId)
        .collection("items").add(item);
    }

    res.status(200).json({ok: true});
  }
);

/**
 * Cloud Tasks target. Fires at a block's expiry + buffer and sends a
 * per-session `shield:off` carrying `reason:"timeout"` to one device.
 * The NSE applies it ONLY if that session is actually due (design spec
 * §3), so a stale or duplicate dispatch is a harmless no-op. Best-
 * effort backup under the on-device prune.
 */
export const dispatchUnblock = onTaskDispatched(
  {
    retryConfig: {maxAttempts: 3, minBackoffSeconds: 5},
    rateLimits: {maxConcurrentDispatches: 20},
  },
  async (req) => {
    const d = (req.data ?? {}) as Record<string, unknown>;
    const fcmToken = typeof d.fcmToken === "string" ? d.fcmToken : "";
    if (!fcmToken) return;

    const payload = buildApnsPayload({
      title: typeof d.title === "string" ? d.title : "Vibez",
      body: typeof d.body === "string" ? d.body : "",
      event: typeof d.event === "string" ? d.event : undefined,
      shield: "off",
      session: typeof d.session === "string" ? d.session : undefined,
      agent: typeof d.agent === "string" ? d.agent : undefined,
      reason: "timeout",
    });

    try {
      await getMessaging().send({
        token: fcmToken,
        apns: {headers: APNS_HEADERS, payload},
      });
      logger.info("dispatchUnblock sent", {
        session: d.session,
        tokenPrefix: fcmToken.slice(0, 12),
      });
    } catch (e) {
      const code = (e as {code?: string})?.code;
      logger.warn("dispatchUnblock failed", {code, session: d.session});
      if (code === "messaging/registration-token-not-registered") {
        await tokensDb.collection(DEVICES).doc(fcmToken).delete()
          .catch(() => undefined);
      }
    }
  }
);
