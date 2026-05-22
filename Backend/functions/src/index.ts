import {setGlobalOptions} from "firebase-functions";
import {onCall, onRequest, HttpsError} from "firebase-functions/https";
import {initializeApp} from "firebase-admin/app";
import {getFirestore, FieldValue} from "firebase-admin/firestore";
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
 * push out to each. Pushes are SILENT (content-available:1, no aps.alert,
 * apns-push-type:background) — iOS doesn't auto-display a banner. The
 * iOS app's NotifyClient.acceptPushUserInfo parses the userInfo, then
 * ContentView.handleIncoming applies the same armed / shield / ignored
 * gating the old ntfy WebSocket path used. The app calls
 * scheduleLocalNotification only when it decides a notification should
 * actually be shown — matching the pre-FCM behavior exactly.
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
    const tokens: string[] = [];
    snapshot.forEach((doc) => {
      const token = doc.get("fcmToken");
      if (typeof token === "string" && token.length > 0) {
        tokens.push(token);
      }
    });

    if (tokens.length === 0) {
      // 200, not 404 — a Mac firing into an unclaimed Vibez ID isn't an
      // error condition. The user might just not have set up their phone
      // yet. The plugin doesn't need to log a failure for this.
      res.status(200).json({total: 0, success: 0, failure: 0});
      return;
    }

    // Custom fields go at the top level of apns.payload (siblings of
    // aps). That's how iOS surfaces them in userInfo, matching the
    // shape NotifyClient.acceptPushUserInfo expects.
    //
    // `content-available: 1` makes this a silent push — iOS wakes the
    // app to process the payload but doesn't display a banner on its
    // own. The app then runs handleIncoming and may call
    // scheduleLocalNotification if armed + shield rules say to.
    const apnsPayload: {
      aps: {"content-available": number};
      title: string;
      body: string;
      event?: string;
      shield?: string;
      session?: string;
      agent?: string;
    } = {
      aps: {"content-available": 1},
      title,
      body: bodyText,
    };
    if (event !== undefined) apnsPayload.event = event;
    if (shield !== undefined) apnsPayload.shield = shield;
    if (session !== undefined) apnsPayload.session = session;
    if (agent !== undefined) apnsPayload.agent = agent;

    let success = 0;
    let failure = 0;
    const invalidTokens: string[] = [];
    const errors: {code?: string; message?: string}[] = [];

    for (let i = 0; i < tokens.length; i += MULTICAST_CHUNK) {
      const chunk = tokens.slice(i, i + MULTICAST_CHUNK);
      const response: BatchResponse =
        await getMessaging().sendEachForMulticast({
          tokens: chunk,
          apns: {
            headers: {
              // Required by iOS 13+. `background` matches the silent
              // payload (content-available:1, no alert). `priority: 5`
              // is the only priority Apple accepts for background
              // pushes — `10` would be rejected with BadPriority.
              "apns-push-type": "background",
              "apns-priority": "5",
            },
            payload: apnsPayload,
          },
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
      total: tokens.length,
      success,
      failure,
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

    res.status(200).json({
      total: tokens.length, success, failure, errors,
    });
  }
);
