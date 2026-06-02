// Firebase Web config + shared constants.
//
// The apiKey/projectId below are taken from the iOS GoogleService-Info.plist.
// Firebase API keys are NOT secret (they ship in every client); they only
// identify the project. Firestore reads are gated by security rules, not the
// key. If reads ever fail with an api-key/app error, register a *Web* app in
// the Firebase console (Project settings → Your apps → Web) and paste its
// config object here — Firestore only actually needs apiKey + projectId.

export const firebaseConfig = {
  apiKey: "AIzaSyAGhYqKjZt5NlrJa5Cqx4PFSP_wVL6hMkI",
  authDomain: "vibez-backend.firebaseapp.com",
  projectId: "vibez-backend",
  storageBucket: "vibez-backend.firebasestorage.app",
  messagingSenderId: "985970258404",
  // iOS app id — fine for Firestore. Swap for a Web app id if you register one.
  appId: "1:985970258404:ios:a21df0e9faa539441c57f1",
};

/// Non-default Firestore database (matches the backend's getFirestore("tokens")).
export const DATABASE_ID = "tokens";

/// Cloud Functions region (functions deploy to us-central1 by default).
export const FUNCTIONS_REGION = "us-central1";

/// 4 hyphen-separated 3–5 letter lowercase words. Same regex as the iOS app
/// (PushTokenRegistrar.vibezIdPattern) and the backend (VIBEZ_ID_PATTERN).
export const VIBEZ_ID_PATTERN = /^[a-z]{3,5}(-[a-z]{3,5}){3}$/;

/// Keepalive alarm so the MV3 service worker periodically wakes to re-attach
/// the Firestore listener, replay anything missed, and re-evaluate timers.
export const KEEPALIVE_ALARM = "vibez-keepalive";
export const KEEPALIVE_PERIOD_MIN = 0.5; // 30s — the minimum chrome.alarms allows.

/// Platform tag stored on the device doc so `notify` can gate fan-out.
export const PLATFORM = "web";

/// Discrete block-duration stops for the settings slider (seconds → hours),
/// matching the iOS SettingsView. Non-linear so one slider spans 5s … 1h.
export const DURATION_STOPS = [
  5, 15, 30, 60, 120, 180, 240, 300, 600, 900, 1800, 2700, 3600,
];
