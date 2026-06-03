import { useEffect, useState, type ReactNode } from "react";
import { makeTheme, STATUS_ERROR } from "../theme";
import { DURATION_STOPS } from "../config";
import { formatDuration } from "../format";
import type {
  AgentTheme,
  AppearancePref,
  OverlayOrder,
  Settings,
  StoredState,
} from "../types";
import { patchState } from "../storage";
import { sendToBackground } from "../messaging";
import { useStoredState, useSystemDark } from "./hooks";
import { TopBar } from "./components/TopBar";
import { Mascot } from "./components/Mascot";
import { BigToggle } from "./components/BigToggle";
import { SetupCard } from "./components/SetupCard";
import { BlockingList } from "./components/BlockingList";
import { AnalyticsPanel } from "./components/AnalyticsPanel";
import { RecentTriggers } from "./components/RecentTriggers";

export function App() {
  const state = useStoredState();
  const systemDark = useSystemDark();
  const [showSettings, setShowSettings] = useState(false);

  const dark = state
    ? state.settings.appearance === "system"
      ? systemDark
      : state.settings.appearance === "dark"
    : true;
  const theme = makeTheme(state?.settings.agent ?? "claude", dark);

  // Match the page background (the overscroll area) to the theme so
  // rubber-banding the popup never flashes white.
  useEffect(() => {
    document.documentElement.style.background = theme.bg;
    document.body.style.background = theme.bg;
  }, [theme.bg]);

  if (!state) {
    return <div className="vz-root vz-loading" style={{ background: theme.bg }} />;
  }

  const paired = state.registration.phase === "registered";
  const setupNeeded = !state.vibezId || !paired;

  const setSettings = (patch: Partial<StoredState["settings"]>) =>
    patchState({ settings: { ...state.settings, ...patch } });

  const onSave = (id: string) => {
    void patchState({ vibezId: id, registration: { phase: "idle", error: null } });
    void sendToBackground({ kind: "register" });
  };

  return (
    <div className="vz-root" style={{ background: theme.bg, color: theme.fg }}>
      <TopBar theme={theme} onSettings={() => setShowSettings((s) => !s)} />

      <div className="vz-mascot-wrap">
        <Mascot agent={state.settings.agent} listening={state.armed && paired} size={96} />
        <div className="vz-ground" style={{ background: `${theme.fgMute}73` }} />
      </div>

      <div className="vz-toggle-wrap">
        <BigToggle
          enabled={state.armed && paired}
          interactive={paired}
          theme={theme}
          onChange={(next) => patchState({ armed: next })}
          onLockedTap={() => setShowSettings(false)}
        />
      </div>

      {setupNeeded ? (
        <SetupCard
          theme={theme}
          vibezId={state.vibezId}
          registration={state.registration}
          onSave={onSave}
          onRetry={() => void sendToBackground({ kind: "register" })}
        />
      ) : (
        <BlockingList
          theme={theme}
          sites={state.sites}
          enabled={state.armed}
          onAdd={(d) => patchState({ sites: [...state.sites, d] })}
          onRemove={(d) => patchState({ sites: state.sites.filter((s) => s !== d) })}
        />
      )}

      <AnalyticsPanel theme={theme} analytics={state.analytics} />
      <RecentTriggers theme={theme} triggers={state.recentTriggers} />

      {showSettings && (
        <SettingsPanel
          theme={theme}
          settings={state.settings}
          vibezId={state.vibezId}
          paired={paired}
          onSettings={setSettings}
          onTest={() => void sendToBackground({ kind: "test-block" })}
          onUnpair={() =>
            patchState({
              vibezId: "",
              armed: false,
              registration: { phase: "idle", error: null },
            })
          }
          onClose={() => setShowSettings(false)}
        />
      )}
    </div>
  );
}

function SettingsPanel({
  theme,
  settings,
  vibezId,
  paired,
  onSettings,
  onTest,
  onUnpair,
  onClose,
}: {
  theme: ReturnType<typeof makeTheme>;
  settings: Settings;
  vibezId: string;
  paired: boolean;
  onSettings: (patch: Partial<Settings>) => void;
  onTest: () => void;
  onUnpair: () => void;
  onClose: () => void;
}) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    void navigator.clipboard?.writeText(vibezId);
    setCopied(true);
    setTimeout(() => setCopied(false), 1400);
  };

  return (
    <div className="vz-settings-scrim" onClick={onClose}>
      <div
        className="vz-settings"
        style={{ background: theme.bgPanel, color: theme.fg }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="vz-card-title" style={{ color: theme.fg, marginBottom: 10 }}>
          Settings
        </div>

        <Segment
          theme={theme}
          label="Appearance"
          value={settings.appearance}
          options={[
            ["system", "System"],
            ["light", "Light"],
            ["dark", "Dark"],
          ]}
          onChange={(v) => onSettings({ appearance: v as AppearancePref })}
        />
        <Segment
          theme={theme}
          label="Accent"
          value={settings.agent}
          options={[
            ["claude", "Claude"],
            ["both", "Both"],
            ["codex", "Codex"],
          ]}
          onChange={(v) => onSettings({ agent: v as AgentTheme })}
        />

        <div className="vz-segment-block">
          <div className="vz-segment-label" style={{ color: theme.fgMute }}>
            Block duration
          </div>
          <DurationControl
            theme={theme}
            label="Needs input"
            seconds={settings.blockSecondsNeedsInput}
            onChange={(s) => onSettings({ blockSecondsNeedsInput: s })}
          />
          <DurationControl
            theme={theme}
            label="Done"
            seconds={settings.blockSecondsDone}
            onChange={(s) => onSettings({ blockSecondsDone: s })}
          />
        </div>

        <Segment
          theme={theme}
          label="Show overlay for"
          value={settings.overlayOrder}
          options={[
            ["newest", "Newest"],
            ["oldest", "Oldest"],
          ]}
          onChange={(v) => onSettings({ overlayOrder: v as OverlayOrder })}
        />

        <Row theme={theme} label="Show dismiss button">
          <Switch
            theme={theme}
            on={settings.allowDismiss}
            onChange={(v) => onSettings({ allowDismiss: v })}
          />
        </Row>

        {vibezId && (
          <div className="vz-segment-block">
            <div className="vz-segment-label" style={{ color: theme.fgMute }}>
              Vibez ID
            </div>
            <div className="vz-id-row" style={{ background: theme.bgWidget }}>
              <span className="vz-id" style={{ color: theme.fg }}>
                {vibezId}
              </span>
              <button className="vz-id-copy" style={{ color: theme.accent }} onClick={copy}>
                {copied ? "Copied" : "Copy"}
              </button>
            </div>
          </div>
        )}

        <div className="vz-settings-actions">
          <button className="vz-ghost-btn" style={{ borderColor: `${theme.fgMute}59`, color: theme.fg }} onClick={onTest}>
            Test overlay
          </button>
          {paired && (
            <button className="vz-ghost-btn" style={{ borderColor: `${theme.fgMute}59`, color: STATUS_ERROR }} onClick={onUnpair}>
              Unpair
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function Row({
  theme,
  label,
  children,
}: {
  theme: ReturnType<typeof makeTheme>;
  label: string;
  children: ReactNode;
}) {
  return (
    <div className="vz-row-setting">
      <span style={{ color: theme.fg, fontSize: 13 }}>{label}</span>
      {children}
    </div>
  );
}

function Switch({
  theme,
  on,
  onChange,
}: {
  theme: ReturnType<typeof makeTheme>;
  on: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <button
      className={`vz-switch${on ? " on" : ""}`}
      style={{ background: on ? theme.accent : theme.bgWidget }}
      onClick={() => onChange(!on)}
      aria-pressed={on}
      aria-label="Toggle"
    >
      <span className="vz-switch-knob" />
    </button>
  );
}

function DurationControl({
  theme,
  label,
  seconds,
  onChange,
}: {
  theme: ReturnType<typeof makeTheme>;
  label: string;
  seconds: number;
  onChange: (s: number) => void;
}) {
  const idx = nearestStopIndex(seconds);
  return (
    <div className="vz-dur">
      <div className="vz-dur-head">
        <span style={{ color: theme.fg, fontSize: 12.5 }}>{label}</span>
        <span className="vz-dur-val" style={{ color: theme.fgMute }}>
          {formatDuration(seconds)}
        </span>
      </div>
      <input
        type="range"
        min={0}
        max={DURATION_STOPS.length - 1}
        step={1}
        value={idx}
        onChange={(e) => onChange(DURATION_STOPS[Number(e.target.value)])}
        className="vz-range"
        style={{ accentColor: theme.accent }}
      />
    </div>
  );
}

function nearestStopIndex(seconds: number): number {
  let best = 0;
  let bestDelta = Infinity;
  DURATION_STOPS.forEach((s, i) => {
    const d = Math.abs(s - seconds);
    if (d < bestDelta) {
      bestDelta = d;
      best = i;
    }
  });
  return best;
}

function Segment<T extends string>({
  theme,
  label,
  value,
  options,
  onChange,
}: {
  theme: ReturnType<typeof makeTheme>;
  label: string;
  value: T;
  options: [T, string][];
  onChange: (v: T) => void;
}) {
  return (
    <div className="vz-segment-block">
      <div className="vz-segment-label" style={{ color: theme.fgMute }}>
        {label}
      </div>
      <div className="vz-segment" style={{ background: theme.bgWidget }}>
        {options.map(([v, lbl]) => (
          <button
            key={v}
            className="vz-segment-btn"
            onClick={() => onChange(v)}
            style={{
              background: v === value ? theme.accent : "transparent",
              color: v === value ? theme.onAccent : theme.fgMute,
            }}
          >
            {lbl}
          </button>
        ))}
      </div>
    </div>
  );
}
