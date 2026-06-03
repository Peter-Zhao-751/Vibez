// Background service worker — the single source of truth.
//
// Responsibilities:
//   • own the Firestore events listener (when armed + paired)
//   • turn events into a per-session block map + Recent Triggers + analytics
//   • publish block state to chrome.storage (content scripts react to it)
//   • register this client with the backend
//   • keepalive + expiry alarms so blocks lift on time even if the SW napped
//
// Listeners are registered at module top level (MV3 requirement) so the SW
// can be woken by them; boot() only does async initialization.

import { getState, patchState, onStateChanged, DEFAULTS } from "../storage";
import { KEEPALIVE_ALARM, KEEPALIVE_PERIOD_MIN } from "../config";
import { errorMessage } from "../messaging";
import { listenEvents, callRegister } from "./firestore";
import {
  durationSecondsFor,
  overlayFor,
  prune,
  sessionKeyFor,
  soonestExpiry,
} from "./blockState";
import { recordEvent, rollover } from "./analytics";
import type {
  AnalyticsToday,
  OverlayInfo,
  PendingSessions,
  StoredState,
  TriggerRecord,
  VibezEventDoc,
} from "../types";

const EXPIRY_ALARM = "vibez-expiry";
const PROCESSED_KEY = "_processedIds";
const MAX_PROCESSED = 200;
const MAX_RECENTS = 50;
// Synthetic session key for the "Test overlay" preview (see previewBlock).
const PREVIEW_KEY = "__preview__";
// "Test overlay" preview length (see previewBlock).
const PREVIEW_DURATION_MS = 30_000;
// Nudge the expiry alarm just past the block's end so it has truly lapsed.
const EXPIRY_ALARM_JITTER_MS = 250;

let unsub: (() => void) | null = null;
let listeningFor: string | null = null;
let processed: Set<string> | null = null;

// ---------------------------------------------------------------- dedupe ----

async function loadProcessed(): Promise<Set<string>> {
  if (processed) return processed;
  const raw = (await chrome.storage.local.get(PROCESSED_KEY))[PROCESSED_KEY] as
    | string[]
    | undefined;
  processed = new Set(raw ?? []);
  return processed;
}

async function markProcessed(id: string): Promise<void> {
  const set = await loadProcessed();
  set.add(id);
  if (set.size > MAX_PROCESSED) processed = new Set([...set].slice(-MAX_PROCESSED));
  await chrome.storage.local.set({ [PROCESSED_KEY]: [...processed!] });
}

// ----------------------------------------------------------- client + reg ----

async function ensureClientId(state: StoredState): Promise<string> {
  if (state.clientId) return state.clientId;
  const id = crypto.randomUUID().replace(/-/g, "");
  await patchState({ clientId: id });
  return id;
}

async function maybeRegister(): Promise<void> {
  const state = await getState();
  if (!state.vibezId) return;
  const clientId = await ensureClientId(state);
  if (state.registration.phase === "registering") return;
  await patchState({ registration: { phase: "registering", error: null } });
  try {
    await callRegister(clientId, state.vibezId);
    await patchState({ registration: { phase: "registered", error: null } });
  } catch (e) {
    await patchState({
      registration: {
        phase: "error",
        error: errorMessage(e),
      },
    });
  }
}

// ------------------------------------------------------- listener lifecycle ----

async function syncListener(): Promise<void> {
  const state = await getState();
  const shouldListen = state.armed && !!state.vibezId;
  if (shouldListen && listeningFor !== state.vibezId) {
    unsub?.();
    listeningFor = state.vibezId;
    unsub = listenEvents(state.vibezId, (doc) =>
      applyEvent(doc).catch((e) => console.error("[vibez] applyEvent", e)),
    );
  } else if (!shouldListen && unsub) {
    unsub();
    unsub = null;
    listeningFor = null;
  }
}

// ----------------------------------------------------------- event → state ----

async function applyEvent(doc: VibezEventDoc): Promise<void> {
  const seen = await loadProcessed();
  if (seen.has(doc.id)) return;
  await markProcessed(doc.id);

  const state = await getState();
  const analytics = recordEvent(state.analytics, doc); // passive count

  // shield:off → user replied; lift that session (even when disarmed).
  if (doc.shield === "off") {
    const sessions = { ...state.blockState.sessions };
    if (doc.session) delete sessions[doc.session];
    await commitBlock(state, sessions, analytics);
    return;
  }

  // Disarmed → analytics only; no block, no Recent Triggers row.
  if (!state.armed) {
    await patchState({ analytics });
    return;
  }

  const seconds = durationSecondsFor(doc.event, state.settings);
  const expiresAt = doc.createdAt + seconds * 1000;
  const sessions = { ...state.blockState.sessions };
  // Replaying an already-expired event records history but starts no block.
  if (expiresAt > Date.now()) sessions[sessionKeyFor(doc)] = expiresAt;

  const trigger: TriggerRecord = {
    id: doc.id,
    receivedAt: doc.createdAt,
    agent: doc.agent,
    title: doc.title,
    body: doc.body,
    event: doc.event,
    blockSeconds: seconds,
    sessionId: doc.session,
  };
  const recents = [trigger, ...state.recentTriggers].slice(0, MAX_RECENTS);

  await commitBlock(state, sessions, analytics, recents);
}

function previewOverlay(expiresAt: number): OverlayInfo {
  return {
    title: "Needs you — Plan plugin distribution",
    body: "Preview of the Vibez blocking overlay — this is what a real block looks like.",
    agent: "cc",
    event: "needs-input",
    expiresAt,
  };
}

/// Recompute derived block state (active?, overlay, focus accrual) and persist.
async function commitBlock(
  prev: StoredState,
  sessionsRaw: PendingSessions,
  analytics0: AnalyticsToday,
  recents?: TriggerRecord[],
): Promise<void> {
  const now = Date.now();
  const sessions = prune(sessionsRaw, now);
  const previewActive = (sessions[PREVIEW_KEY] ?? 0) > now;
  // Focus time counts real blocks only — the preview shouldn't pad the stat.
  const realActive = Object.entries(sessions).some(
    ([k, exp]) => k !== PREVIEW_KEY && exp > now,
  );

  let analytics = analytics0;
  if (realActive && analytics.blockStartedAt == null) {
    analytics = { ...analytics, blockStartedAt: now };
  } else if (!realActive && analytics.blockStartedAt != null) {
    const add = Math.round((now - analytics.blockStartedAt) / 1000);
    analytics = {
      ...analytics,
      focusSeconds: analytics.focusSeconds + Math.max(0, add),
      blockStartedAt: null,
    };
  }

  const effectiveRecents = recents ?? prev.recentTriggers;
  const latest = previewActive
    ? previewOverlay(sessions[PREVIEW_KEY])
    : realActive
      ? overlayFor(effectiveRecents, sessions, prev.settings.overlayOrder)
      : null;

  const patch: Partial<StoredState> = {
    blockState: { sessions, latest, preview: previewActive, updatedAt: now },
    analytics,
  };
  if (recents) patch.recentTriggers = recents;
  await patchState(patch);

  scheduleExpiry(sessions);
}

function scheduleExpiry(sessions: PendingSessions): void {
  const soon = soonestExpiry(sessions);
  chrome.alarms.clear(EXPIRY_ALARM);
  if (soon) chrome.alarms.create(EXPIRY_ALARM, { when: soon + EXPIRY_ALARM_JITTER_MS });
}

// ------------------------------------------------------------- commands ----

async function dismissAll(): Promise<void> {
  const state = await getState();
  await commitBlock(state, {}, state.analytics);
}

async function recordImpression(domain: string): Promise<void> {
  const state = await getState();
  const a = rollover(state.analytics);
  await patchState({
    analytics: {
      ...a,
      perDomainBlocks: {
        ...a.perDomainBlocks,
        [domain]: (a.perDomainBlocks[domain] ?? 0) + 1,
      },
    },
  });
}

/// "Test overlay" → a 30s preview that shows on the user's *current* tab
/// regardless of pairing, the armed toggle, or the site list. A real block
/// (applyEvent) still requires armed + a site-list match.
async function previewBlock(): Promise<void> {
  const now = Date.now();
  const state = await getState();
  const sessions = {
    ...prune(state.blockState.sessions, now),
    [PREVIEW_KEY]: now + PREVIEW_DURATION_MS,
  };
  await commitBlock(state, sessions, state.analytics);
}

// ------------------------------------------------------------- boot ----

async function ensureAlarms(): Promise<void> {
  const existing = await chrome.alarms.get(KEEPALIVE_ALARM);
  if (!existing) {
    chrome.alarms.create(KEEPALIVE_ALARM, { periodInMinutes: KEEPALIVE_PERIOD_MIN });
  }
}

/// Persist the seed site list + default settings to raw storage so the
/// content loader (which reads chrome.storage directly, not getState's merged
/// view) can decide whether to mount the overlay on a given host.
async function ensureSeeded(): Promise<void> {
  const raw = await chrome.storage.local.get(["sites", "settings"]);
  const seed: Record<string, unknown> = {};
  if (raw.sites === undefined) seed.sites = DEFAULTS.sites;
  if (raw.settings === undefined) seed.settings = DEFAULTS.settings;
  if (Object.keys(seed).length) await chrome.storage.local.set(seed);
}

async function boot(): Promise<void> {
  await ensureAlarms();
  await ensureSeeded();
  const state = await getState();
  await ensureClientId(state);

  const rolled = rollover(state.analytics);
  if (rolled !== state.analytics) await patchState({ analytics: rolled });

  if (state.vibezId && state.registration.phase !== "registered") {
    await maybeRegister();
  }
  await syncListener();
  // Prune anything that expired while the SW was asleep.
  const fresh = await getState();
  await commitBlock(fresh, fresh.blockState.sessions, fresh.analytics);
}

// ----------------------------------------------------- top-level listeners ----

chrome.runtime.onInstalled.addListener(() => void boot().catch(console.error));
chrome.runtime.onStartup.addListener(() => void boot().catch(console.error));

chrome.alarms.onAlarm.addListener((alarm) => {
  void (async () => {
    if (alarm.name === KEEPALIVE_ALARM) await syncListener();
    const state = await getState();
    await commitBlock(state, state.blockState.sessions, state.analytics);
  })().catch(console.error);
});

onStateChanged((keys, state) => {
  void (async () => {
    if (keys.includes("armed") || keys.includes("vibezId")) await syncListener();
    if (keys.includes("vibezId")) await maybeRegister();
    // Disarming lifts any active block immediately (don't make the user wait
    // out a timer they just turned off).
    if (keys.includes("armed") && !state.armed) {
      await commitBlock(state, {}, state.analytics);
    }
  })().catch(console.error);
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  void (async () => {
    try {
      switch (msg?.kind) {
        case "register":
          await maybeRegister();
          break;
        case "test-block":
          await previewBlock();
          break;
        case "dismiss":
          await dismissAll();
          break;
        case "impression":
          await recordImpression(msg.domain);
          break;
        default:
          sendResponse({ ok: false, error: "unknown message" });
          return;
      }
      sendResponse({ ok: true });
    } catch (e) {
      sendResponse({ ok: false, error: errorMessage(e) });
    }
  })();
  return true; // async sendResponse
});

// Kick off init when the worker spins up.
void boot().catch(console.error);
