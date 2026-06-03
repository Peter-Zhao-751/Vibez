// Overlay content script — injected directly (classic) on every http/https
// page by the manifest. It stays dormant (no React mounted) until the
// background SW reports a block (or a preview) that applies to this tab, so
// idle pages pay almost nothing.

import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { getState, onStateChanged } from "../storage";
import { makeTheme, getSystemDark, agentThemeFor } from "../theme";
import { matchedDomain } from "../sites";
import { sendToBackground } from "../messaging";
import type { AgentTheme, StoredState } from "../types";
import { Overlay } from "./Overlay";
import { OVERLAY_CSS } from "./overlayStyles";

const HOST_ID = "vibez-overlay-host";

function resolveDark(state: StoredState): boolean {
  if (state.settings.appearance === "system") {
    return getSystemDark();
  }
  return state.settings.appearance === "dark";
}

/// Show when there's an active block AND either it's a preview (any tab) or
/// this host is on the blocked-site list.
function shouldShow(state: StoredState | null): boolean {
  if (!state || !state.blockState.latest) return false;
  if (state.blockState.preview) return true;
  return matchedDomain(location.hostname, state.sites) != null;
}

function ContentApp() {
  const [state, setState] = useState<StoredState | null>(null);

  useEffect(() => {
    let alive = true;
    void getState().then((s) => alive && setState(s));
    const off = onStateChanged((_keys, s) => setState(s));
    return () => {
      alive = false;
      off();
    };
  }, []);

  const show = shouldShow(state);
  const domain = state ? matchedDomain(location.hostname, state.sites) : null;
  const previewActive = state?.blockState.preview ?? false;
  const realImpression = show && !!domain && !previewActive;

  // Lock page scroll while the overlay is up.
  useEffect(() => {
    if (!show) return;
    const el = document.documentElement;
    const prev = el.style.overflow;
    el.style.overflow = "hidden";
    return () => {
      el.style.overflow = prev;
    };
  }, [show]);

  // Count one impression per real (non-preview) block on a listed site.
  useEffect(() => {
    if (realImpression && domain) void sendToBackground({ kind: "impression", domain });
  }, [realImpression, domain]);

  if (!show || !state) return null;
  const latest = state.blockState.latest!;
  const dark = resolveDark(state);
  const agent: AgentTheme = agentThemeFor(latest.agent, state.settings.agent);
  const theme = makeTheme(agent, dark);

  return (
    <Overlay
      theme={theme}
      dark={dark}
      agent={agent}
      latest={latest}
      allowDismiss={state.settings.allowDismiss}
      onDismiss={() => void sendToBackground({ kind: "dismiss" })}
    />
  );
}

let mounted = false;
function ensureMounted() {
  if (mounted || document.getElementById(HOST_ID)) return;
  mounted = true;
  const host = document.createElement("div");
  host.id = HOST_ID;
  host.style.cssText = "all: initial;";
  const shadow = host.attachShadow({ mode: "open" });
  const style = document.createElement("style");
  style.textContent = OVERLAY_CSS;
  shadow.appendChild(style);
  const point = document.createElement("div");
  shadow.appendChild(point);
  (document.documentElement || document.body).appendChild(host);
  createRoot(point).render(<ContentApp />);
}

// Only spin up React once a block (or preview) actually applies to this tab.
void getState().then((s) => {
  if (shouldShow(s)) ensureMounted();
});
onStateChanged((_keys, s) => {
  if (shouldShow(s)) ensureMounted();
});
