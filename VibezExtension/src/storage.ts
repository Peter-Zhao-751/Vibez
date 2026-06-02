// Typed wrapper over chrome.storage.local — the single shared state surface
// between the background SW, the popup, and the content script.

import type { StoredState } from "./types";
import { DEFAULT_SITES } from "./sites";

export function todayLocal(d = new Date()): string {
  const y = d.getFullYear();
  const m = `${d.getMonth() + 1}`.padStart(2, "0");
  const day = `${d.getDate()}`.padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export function freshAnalytics(date = todayLocal()): StoredState["analytics"] {
  return {
    date,
    sessionIds: [],
    replies: 0,
    pings: 0,
    focusSeconds: 0,
    perDomainBlocks: {},
    blockStartedAt: null,
  };
}

export const DEFAULTS: StoredState = {
  vibezId: "",
  clientId: "",
  registration: { phase: "idle", error: null },
  armed: false,
  sites: [...DEFAULT_SITES],
  settings: {
    appearance: "dark",
    agent: "claude",
    allowDismiss: true,
    blockSecondsDone: 30,
    blockSecondsNeedsInput: 900,
    overlayOrder: "newest",
  },
  blockState: { sessions: {}, latest: null, preview: false, updatedAt: 0 },
  analytics: freshAnalytics(),
  recentTriggers: [],
};

const KEYS = Object.keys(DEFAULTS) as (keyof StoredState)[];

/// Read the whole state, filling any missing keys with defaults.
export async function getState(): Promise<StoredState> {
  const raw = (await chrome.storage.local.get(KEYS)) as Partial<StoredState>;
  const merged = { ...DEFAULTS };
  for (const k of KEYS) {
    if (raw[k] !== undefined) (merged as Record<string, unknown>)[k] = raw[k];
  }
  // Deep-merge settings so a stored object from an older build still picks up
  // newly-added keys (e.g. overlayOrder) instead of leaving them undefined.
  merged.settings = { ...DEFAULTS.settings, ...(raw.settings ?? {}) };
  return merged;
}

/// Write a subset of keys.
export async function patchState(patch: Partial<StoredState>): Promise<void> {
  await chrome.storage.local.set(patch);
}

/// Subscribe to changes. The callback receives the keys that changed and the
/// (already-merged) full state.
export function onStateChanged(
  cb: (changedKeys: (keyof StoredState)[], state: StoredState) => void,
): () => void {
  const listener = async (
    changes: { [k: string]: chrome.storage.StorageChange },
    area: string,
  ) => {
    if (area !== "local") return;
    const changedKeys = Object.keys(changes).filter((k) =>
      KEYS.includes(k as keyof StoredState),
    ) as (keyof StoredState)[];
    if (changedKeys.length === 0) return;
    cb(changedKeys, await getState());
  };
  chrome.storage.onChanged.addListener(listener);
  return () => chrome.storage.onChanged.removeListener(listener);
}
