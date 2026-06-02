// The background SW is the only Firebase client. It listens to
// events/{vibezId}/items in the named "tokens" database and registers this
// client via the existing registerPushToken callable.

import { initializeApp, type FirebaseApp } from "firebase/app";
import {
  initializeFirestore,
  collection,
  onSnapshot,
  query,
  orderBy,
  limit,
  type Firestore,
  type DocumentData,
} from "firebase/firestore";
import { getFunctions, httpsCallable, type Functions } from "firebase/functions";
import { firebaseConfig, DATABASE_ID, FUNCTIONS_REGION, PLATFORM } from "../config";
import type { VibezAgent, VibezEvent, VibezEventDoc, VibezShield } from "../types";

let app: FirebaseApp | null = null;
let db: Firestore | null = null;
let functions: Functions | null = null;

function ensureFirebase() {
  if (!app) {
    app = initializeApp(firebaseConfig);
    // Force long-polling: WebChannel streaming is unreliable inside an MV3
    // service worker; long-polling is the robust transport there.
    db = initializeFirestore(
      app,
      { experimentalForceLongPolling: true },
      DATABASE_ID,
    );
    functions = getFunctions(app, FUNCTIONS_REGION);
  }
  return { db: db!, functions: functions! };
}

function parseDoc(id: string, d: DocumentData): VibezEventDoc {
  const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
  return {
    id,
    title: str(d.title) ?? "Vibez",
    body: str(d.body) ?? "",
    event: (str(d.event) as VibezEvent | null) ?? null,
    shield: (str(d.shield) as VibezShield | null) ?? null,
    session: str(d.session),
    agent: (str(d.agent) as VibezAgent | null) ?? null,
    createdAt: typeof d.createdAtMs === "number" ? d.createdAtMs : Date.now(),
  };
}

/// Live-listen to the most recent events for this Vibez ID. `onDoc` fires once
/// per newly-added document (oldest-first within a batch); dedupe is the
/// caller's job. Returns an unsubscribe fn.
export function listenEvents(
  vibezId: string,
  onDoc: (doc: VibezEventDoc) => void,
): () => void {
  const { db } = ensureFirebase();
  const q = query(
    collection(db, "events", vibezId, "items"),
    orderBy("createdAtMs", "desc"),
    limit(50),
  );
  return onSnapshot(
    q,
    (snap) => {
      const added = snap
        .docChanges()
        .filter((c) => c.type === "added")
        .reverse(); // oldest-first so side effects apply in arrival order
      for (const change of added) {
        onDoc(parseDoc(change.doc.id, change.doc.data()));
      }
    },
    (err) => console.error("[vibez] events listener error:", err),
  );
}

/// Register this extension as a `web` device for the Vibez ID, reusing the
/// existing callable. The client id doubles as the device doc id (the
/// extension listens to Firestore, so it needs no FCM token).
export async function callRegister(
  clientId: string,
  vibezId: string,
): Promise<void> {
  const { functions } = ensureFirebase();
  const fn = httpsCallable(functions, "registerPushToken");
  await fn({ fcmToken: clientId, vibezId, platform: PLATFORM });
}
