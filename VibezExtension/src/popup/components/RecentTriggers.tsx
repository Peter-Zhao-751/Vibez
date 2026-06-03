// Recent Triggers list — analog of the iOS RecentTriggersSection rows.

import type { Theme } from "../../theme";
import type { TriggerRecord } from "../../types";
import { CLAUDE_ORANGE, CODEX_BLUE } from "../../theme";
import { relativeTime, EVENT_LABEL } from "../../format";
import { useNow } from "../hooks";

export function RecentTriggers({ theme, triggers }: { theme: Theme; triggers: TriggerRecord[] }) {
  const now = useNow(30_000);

  return (
    <div className="vz-recents">
      <div className="vz-recents-title" style={{ color: theme.fg }}>
        Recent Triggers
      </div>
      {triggers.length === 0 ? (
        <div className="vz-empty" style={{ background: theme.bgWidget, color: theme.fgMute }}>
          No triggers yet — pings from Claude or Codex will land here.
        </div>
      ) : (
        <div className="vz-recents-list">
          {triggers.map((t) => (
            <Row key={t.id} theme={theme} t={t} now={now} />
          ))}
        </div>
      )}
    </div>
  );
}

function Row({ theme, t, now }: { theme: Theme; t: TriggerRecord; now: number }) {
  const isCodex = t.agent === "cx";
  const prefix = t.event ? EVENT_LABEL[t.event] : null;
  const top = prefix && t.title ? `${prefix} — ${t.title}` : t.title || prefix || "Vibez";

  return (
    <div className="vz-row" style={{ background: theme.bgWidget }}>
      <div
        className="vz-row-badge"
        style={{ background: isCodex ? CODEX_BLUE : CLAUDE_ORANGE }}
      >
        {isCodex ? "cx" : "cc"}
      </div>
      <div className="vz-row-body">
        <div className="vz-row-title" style={{ color: theme.fg }}>
          {top}
        </div>
        {t.body && (
          <div className="vz-row-sub" style={{ color: theme.fgMute }}>
            {t.body}
          </div>
        )}
        <div className="vz-row-time" style={{ color: theme.fgFaint }}>
          {relativeTime(t.receivedAt, now)}
        </div>
      </div>
    </div>
  );
}
