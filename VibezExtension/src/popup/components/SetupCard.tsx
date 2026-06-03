// Pairing card — port of VibezSetupCard.swift. Enter the 4-word Vibez ID from
// /vibez:setup on the Mac; the SW registers this client with the backend.

import { useState } from "react";
import type { Theme } from "../../theme";
import { STATUS_REGISTERING, STATUS_PAIRED, STATUS_ERROR, STATUS_IDLE } from "../../theme";
import type { RegistrationState } from "../../types";
import { VIBEZ_ID_PATTERN } from "../../config";

interface SetupCardProps {
  theme: Theme;
  vibezId: string;
  registration: RegistrationState;
  onSave: (id: string) => void;
  onRetry: () => void;
}

export function SetupCard({ theme, vibezId, registration, onSave, onRetry }: SetupCardProps) {
  const [draft, setDraft] = useState(vibezId);
  const [error, setError] = useState<string | null>(null);

  const trimmed = draft.trim().toLowerCase();
  const saveable = VIBEZ_ID_PATTERN.test(trimmed) && trimmed !== vibezId;

  const commit = () => {
    if (!VIBEZ_ID_PATTERN.test(trimmed)) {
      setError("Format: 4 hyphenated words, each 3–5 letters (e.g. moss-pine-fox-jazz).");
      return;
    }
    setError(null);
    onSave(trimmed);
  };

  const status = statusFor(registration, vibezId);

  return (
    <div className="vz-card" style={{ background: theme.bgPanel }}>
      <div className="vz-card-title" style={{ color: theme.fg }}>
        Set up notifications
      </div>
      <p className="vz-card-sub" style={{ color: theme.fgMute }}>
        Run <code>/vibez:setup</code> in Claude Code or Codex on your Mac, then enter
        the 4-word Vibez ID it gave you here.
      </p>

      <div className="vz-setup-row">
        <input
          className="vz-input"
          style={{ background: theme.bgWidget, color: theme.fg }}
          placeholder="moss-pine-fox-jazz"
          value={draft}
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          onChange={(e) => {
            setDraft(e.target.value);
            if (error) setError(null);
          }}
          onKeyDown={(e) => e.key === "Enter" && commit()}
        />
        <button
          className="vz-save-btn"
          disabled={!saveable}
          onClick={commit}
          style={{
            background: saveable
              ? `linear-gradient(135deg, ${theme.pillStops[0]}, ${theme.pillStops[1]})`
              : theme.bgWidget,
            color: saveable ? theme.onAccent : theme.fgMute,
          }}
        >
          {registration.phase === "registering" ? "…" : "SAVE"}
        </button>
      </div>

      <div className="vz-status-row">
        <span className="vz-status-dot" style={{ background: status.color }} />
        <span className="vz-status-label" style={{ color: theme.fgMute }}>
          {status.label}
        </span>
        {registration.phase === "error" && (
          <button className="vz-retry" style={{ color: theme.fg }} onClick={onRetry}>
            retry
          </button>
        )}
      </div>

      {error && <div className="vz-field-error">{error}</div>}
    </div>
  );
}

function statusFor(reg: RegistrationState, vibezId: string): { color: string; label: string } {
  switch (reg.phase) {
    case "registering":
      return { color: STATUS_REGISTERING, label: "registering…" };
    case "registered":
      return { color: STATUS_PAIRED, label: "paired" };
    case "error":
      return { color: STATUS_ERROR, label: `error: ${(reg.error ?? "").slice(0, 60)}` };
    default:
      return { color: STATUS_IDLE, label: vibezId ? "waiting…" : "no Vibez ID yet" };
  }
}
