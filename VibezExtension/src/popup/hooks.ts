import { useEffect, useState } from "react";
import { getState, onStateChanged } from "../storage";
import type { StoredState } from "../types";
import { getSystemDark } from "../theme";

/// Live view of chrome.storage.local, kept in sync with the background SW.
export function useStoredState(): StoredState | null {
  const [state, setState] = useState<StoredState | null>(null);
  useEffect(() => {
    let alive = true;
    void getState().then((s) => {
      if (alive) setState(s);
    });
    const off = onStateChanged((_keys, s) => setState(s));
    return () => {
      alive = false;
      off();
    };
  }, []);
  return state;
}

export function useSystemDark(): boolean {
  const [dark, setDark] = useState(() => getSystemDark());
  useEffect(() => {
    const mq = globalThis.matchMedia?.("(prefers-color-scheme: dark)");
    if (!mq) return;
    const handler = () => setDark(mq.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, []);
  return dark;
}

/// A self-incrementing ticker for live countdowns / relative times.
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
