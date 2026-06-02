import {setGlobalOptions} from "firebase-functions";
import {onCall, onRequest, HttpsError} from "firebase-functions/https";
import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue, Timestamp} from "firebase-admin/firestore";
import {getMessaging, BatchResponse} from "firebase-admin/messaging";
import * as logger from "firebase-functions/logger";

initializeApp();
setGlobalOptions({maxInstances: 10});

// Vibez push state lives in a non-default Firestore database named
// "tokens" (Standard edition), in a single collection `devices`. Each
// document is keyed by the FCM registration token and carries the
// user's chosen Vibez ID — a 4-word slug that pairs a phone with a Mac.
const tokensDb = getFirestore("tokens");
const DEVICES = "devices";

// FCM's sendEachForMulticast caps at 500 tokens per call. Above that we
// chunk and accumulate. Vibez is personal-scale; defensive ceiling.
const MULTICAST_CHUNK = 500;

// 4 hyphen-separated words, each 3-5 lowercase ASCII letters. Generated
// by the plugin's setup.sh and typed into the iOS Vibez app.
const VIBEZ_ID_PATTERN = /^[a-z]{3,5}(-[a-z]{3,5}){3}$/;

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

    if (typeof fcmToken !== "string" || fcmToken.length < 20) {
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

    await tokensDb.collection(DEVICES).doc(fcmToken).set(
      {
        fcmToken,
        vibezId,
        platform,
        createdAt: FieldValue.serverTimestamp(),
        lastSeen: FieldValue.serverTimestamp(),
      },
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

    const body = (req.body ?? {}) as Record<string, unknown>;
    const vibezId = typeof body.vibezId === "string" ? body.vibezId : "";
    const title = typeof body.title === "string" ? body.title : "";
    const bodyText = typeof body.body === "string" ? body.body : "";
    const event = typeof body.event === "string" ? body.event : undefined;
    const shield = typeof body.shield === "string" ? body.shield : undefined;
    const session = typeof body.session === "string" ? body.session : undefined;
    const agent = typeof body.agent === "string" ? body.agent : undefined;

    if (!VIBEZ_ID_PATTERN.test(vibezId)) {
      res.status(400).json({error: "invalid vibezId"});
      return;
    }
    if (!title || !bodyText) {
      res.status(400).json({error: "title and body are required"});
      return;
    }

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
    snapshot.forEach((doc) => {
      const token = doc.get("fcmToken");
      const platform = typeof doc.get("platform") === "string" ?
        doc.get("platform") : "unknown";
      if (platform === "web") {
        hasWeb = true;
      } else if (typeof token === "string" && token.length > 0) {
        apnsTokens.push(token);
      }
    });

    if (apnsTokens.length === 0 && !hasWeb) {
      // 200, not 404 — a Mac firing into an unclaimed Vibez ID isn't an
      // error condition. The user might just not have set up their phone
      // or browser yet. The plugin doesn't need to log a failure for this.
      res.status(200).json({total: 0, success: 0, failure: 0, web: false});
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
    const isSilent = shield === "off";
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const aps: any = isSilent ?
      {
        "alert": {title, body: bodyText},
        "interruption-level": "passive",
        "content-available": 1,
        "mutable-content": 1,
      } :
      {
        "alert": {title, body: bodyText},
        "sound": "default",
        "content-available": 1,
        "mutable-content": 1,
      };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const apnsPayload: any = {aps, title, body: bodyText};
    if (event !== undefined) apnsPayload.event = event;
    if (shield !== undefined) apnsPayload.shield = shield;
    if (session !== undefined) apnsPayload.session = session;
    if (agent !== undefined) apnsPayload.agent = agent;
    // Both flavors are alert-type now (passive is just a display hint).
    // Priority 10 means "deliver immediately"; passive's interruption
    // level still suppresses the banner/sound, so this doesn't wake the
    // user — it just gets the shield down without lag.
    const apnsHeaders: Record<string, string> = {
      "apns-push-type": "alert",
      "apns-priority": "10",
    };

    let success = 0;
    let failure = 0;
    const invalidTokens: string[] = [];
    const errors: {code?: string; message?: string}[] = [];

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
          errors.push({code, message: errMessage});
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

    // Browser extension(s) registered to this Vibez ID read events from a
    // Firestore log rather than APNs — Firestore can't wake a suspended iOS
    // app, so the phone stays on APNs and this write is purely additive. The
    // path is keyed by the Vibez ID (which is the shared secret); a TTL
    // policy on `expireAt` auto-expires old events.
    if (hasWeb) {
      const now = Date.now();
      const item: Record<string, unknown> = {
        title,
        body,
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

    res.status(200).json({
      total: apnsTokens.length, success, failure, errors, web: hasWeb,
    });
  }
);
