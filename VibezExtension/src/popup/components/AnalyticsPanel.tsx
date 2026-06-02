// Today-only usage summary — analog of the iOS AnalyticsPanel.

import type { Theme } from "../../theme";
import type { AnalyticsToday } from "../../types";
import { focusSecondsNow } from "../../background/analytics";
import { formatDuration } from "../../format";
import { useNow } from "../hooks";

export function AnalyticsPanel({ theme, analytics }: { theme: Theme; analytics: AnalyticsToday }) {
  useNow(30_000); // keep the live focus interval ticking

  const focus = focusSecondsNow(analytics);
  const topDomain =
    Object.entries(analytics.perDomainBlocks).sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;

  return (
    <div className="vz-card" style={{ background: theme.bgWidget }}>
      <div className="vz-card-head">
        <span className="vz-card-title" style={{ color: theme.fg }}>
          Today
        </span>
      </div>
      <div className="vz-stats">
        <Stat theme={theme} value={`${analytics.sessionIds.length}`} label="chats" />
        <Stat theme={theme} value={`${analytics.replies}`} label="replies" />
        <Stat theme={theme} value={focus > 0 ? formatDuration(focus) : "—"} label="focus" />
        <Stat
          theme={theme}
          value={topDomain ? shortDomain(topDomain) : "—"}
          label="most blocked"
          small={!!topDomain}
        />
      </div>
    </div>
  );
}

function Stat({
  theme,
  value,
  label,
  small,
}: {
  theme: Theme;
  value: string;
  label: string;
  small?: boolean;
}) {
  return (
    <div className="vz-stat" style={{ borderColor: `${theme.fgMute}38` }}>
      <div
        className="vz-stat-value"
        style={{ color: theme.fg, fontSize: small ? 13 : 26 }}
      >
        {value}
      </div>
      <div className="vz-stat-label" style={{ color: theme.fgMute }}>
        {label}
      </div>
    </div>
  );
}

function shortDomain(d: string): string {
  return d.replace(/\.[a-z]+$/, "");
}
