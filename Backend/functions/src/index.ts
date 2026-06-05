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
} from "./validation.js";

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
 * is the natural next layer when we ship.
 */
export const registerPushToken = onCall(
  {invoker: "public"},
  async (request) => {
    const data = request.data ?? {};
    const fcmToken = data.fcmToken;
    const vibezId = data.vibezId;
    const platform =
      typeof data.platform === "string" ? data.platform : "unknown";

    if (
      typeof fcmToken !== "string" ||
      fcmToken.length < MIN_FCM_TOKEN_LENGTH
    ) {
      throw new HttpsError(
        "invalid-argument",
        "fcmToken must be a non-empty string"
      );
    }
    if (typeof vibezId !== "string" || !VIBEZ_ID_PATTERN.test(vibezId)) {
      throw new HttpsError(
        "invalid-argument",
        "vibezId must be 4 hyphenated 3-5 letter lowercase words"
      );
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

    await tokensDb.collection(DEVICES).doc(fcmToken).set(
      deviceDoc,
      {merge: true}
    );

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

    const snapshot = await tokensDb
      .collection(DEVICES)
      .where("vibezId", "==", vibezId)
      .get();
    // Partition registered devices by platform so each delivery path only
    // runs when it has a consumer ("nothing wasted"): APNs for iOS tokens,
    // a Firestore event-log write for the browser extension. A web client id
    // is never sent to FCM (it isn't an APNs token).
    const apnsTokens: string[] = [];
    let hasWeb = false;
    const scheduleUnblock = shouldScheduleUnblock({shield, session, event});
    const unblockTargets: {token: string; delaySeconds: number}[] = [];
    snapshot.forEach((doc) => {
      const token = doc.get("fcmToken");
      const platform = typeof doc.get("platform") === "string" ?
        doc.get("platform") : "unknown";
      if (platform === "web") {
        hasWeb = true;
      } else if (typeof token === "string" && token.length > 0) {
        apnsTokens.push(token);
        if (scheduleUnblock) {
          const durations = {
            done: clampDuration(doc.get("blockSecondsDone"), 30),
            needsInput: clampDuration(doc.get("blockSecondsNeedsInput"), 900),
          };
          unblockTargets.push({
            token,
            delaySeconds: delayForEvent(event, durations),
          });
        }
      }
    });

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
