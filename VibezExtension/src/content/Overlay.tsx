// The full-screen blocking overlay — port of the iOS BlockedOverlay.

import { useEffect, useRef, useState } from "react";
import type { AgentTheme, OverlayInfo } from "../types";
import { type Theme, withAlpha } from "../theme";
import { Mascot } from "../popup/components/Mascot";
import { formatRemaining } from "../format";

const EVENT_LABEL: Record<string, string> = {
  done: "Done",
  "needs-input": "Needs you",
  replied: "Replied",
};

interface OverlayProps {
  theme: Theme;
  dark: boolean;
  agent: AgentTheme;
  latest: OverlayInfo;
  allowDismiss: boolean;
  onDismiss: () => void;
}

export function Overlay({ theme, dark, agent, latest, allowDismiss, onDismiss }: OverlayProps) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const remaining =
    latest.expiresAt != null ? Math.max(0, Math.round((latest.expiresAt - now) / 1000)) : null;
  const prefix = latest.event ? EVENT_LABEL[latest.event] : null;
  const title =
    prefix && latest.title ? `${prefix} — ${latest.title}` : latest.title || prefix || "Vibez";
  const base = dark ? "#0c0d12" : "#fbf8f4";

  return (
    <div className="vz-ov-root" style={{ background: base }}>
      <div
        className="vz-ov-glow"
        style={{
          background: `radial-gradient(circle at 50% 30%, ${withAlpha(
            theme.accent,
            dark ? 0.28 : 0.2,
          )}, transparent 62%)`,
        }}
      />
      <div className="vz-ov-content">
        <Mascot agent={agent} listening size={120} />
        <div className="vz-ov-tag" style={{ color: theme.accent }}>
          BLOCKING IN PROGRESS
        </div>
        <div className="vz-ov-title" style={{ color: theme.fg }}>
          {title}
        </div>
        {latest.body && (
          <div className="vz-ov-body" style={{ color: theme.fgMute }}>
            {latest.body}
          </div>
        )}
        {remaining != null && (
          <div className="vz-ov-count" style={{ color: theme.fg }}>
            <RollingNumber value={formatRemaining(remaining)} />
          </div>
        )}
        {allowDismiss && (
          <button
            className="vz-ov-dismiss"
            style={{ color: theme.fgMute, borderColor: withAlpha(theme.fgMute, dark ? 0.35 : 0.3) }}
            onClick={onDismiss}
          >
            Dismiss
          </button>
        )}
      </div>
    </div>
  );
}

/// Per-digit rolling countdown — mirrors the iOS overlay's
/// `.contentTransition(.numericText(countsDown: true))`: when a character
/// changes, the new one slides in from the top and the old one slides out the
/// bottom (everything moves down). Unchanged characters stay put.
function RollingNumber({ value }: { value: string }) {
  return (
    <span className="vz-roll-row">
      {value.split("").map((ch, i) => (
        <RollingChar key={i} ch={ch} />
      ))}
    </span>
  );
}

function RollingChar({ ch }: { ch: string }) {
  const [gen, setGen] = useState(0);
  const [prev, setPrev] = useState<string | null>(null);
  const chRef = useRef(ch);

  useEffect(() => {
    if (chRef.current !== ch) {
      setPrev(chRef.current);
      chRef.current = ch;
      setGen((g) => g + 1);
    }
  }, [ch]);

  return (
    <span className="vz-roll">
      {prev != null && (
        <span key={`o${gen}`} className="vz-roll-out" onAnimationEnd={() => setPrev(null)}>
          {prev}
        </span>
      )}
      <span key={`i${gen}`} className="vz-roll-in">
        {ch}
      </span>
    </span>
  );
}
