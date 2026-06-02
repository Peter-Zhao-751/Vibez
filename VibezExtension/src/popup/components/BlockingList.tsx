// The blocked-sites list — analog of the iOS BlockingPanel, but the user
// types domains (Apple's opaque app tokens have no web equivalent).

import { useState } from "react";
import type { Theme } from "../../theme";
import { normalizeDomain } from "../../sites";

interface BlockingListProps {
  theme: Theme;
  sites: string[];
  enabled: boolean;
  onAdd: (domain: string) => void;
  onRemove: (domain: string) => void;
}

export function BlockingList({ theme, sites, enabled, onAdd, onRemove }: BlockingListProps) {
  const [draft, setDraft] = useState("");

  const add = () => {
    const d = normalizeDomain(draft);
    if (d && !sites.includes(d)) onAdd(d);
    setDraft("");
  };

  const count =
    sites.length === 0 ? "nothing yet" : sites.length === 1 ? "1 site" : `${sites.length} sites`;

  return (
    <div
      className="vz-card"
      style={{ background: theme.bgPanel, opacity: enabled ? 1 : 0.55 }}
    >
      <div className="vz-card-head">
        <span className="vz-card-title" style={{ color: theme.fg }}>
          Blocking
        </span>
        <span className="vz-count" style={{ color: theme.fgMute }}>
          {count}
        </span>
      </div>

      <div className="vz-chips">
        {sites.map((d) => (
          <span key={d} className="vz-chip" style={{ background: theme.bgWidget, color: theme.fg }}>
            {d}
            <button
              className="vz-chip-x"
              style={{ color: theme.fgMute }}
              onClick={() => onRemove(d)}
              aria-label={`Remove ${d}`}
            >
              ×
            </button>
          </span>
        ))}
      </div>

      <div className="vz-setup-row">
        <input
          className="vz-input"
          style={{ background: theme.bgWidget, color: theme.fg }}
          placeholder="add a site (e.g. news.ycombinator.com)"
          value={draft}
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && add()}
        />
        <button
          className="vz-save-btn"
          disabled={!normalizeDomain(draft)}
          onClick={add}
          style={{
            background: normalizeDomain(draft) ? theme.accent : theme.bgWidget,
            color: normalizeDomain(draft) ? theme.onAccent : theme.fgMute,
          }}
        >
          ADD
        </button>
      </div>
    </div>
  );
}
