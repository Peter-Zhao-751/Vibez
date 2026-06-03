// Small shared formatters (shared by popup panels and the overlay).

export function formatDuration(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return m === 0 ? `${h}h` : `${h}h${m}m`;
}

export function relativeTime(fromMs: number, now: number): string {
  const d = Math.max(0, Math.floor((now - fromMs) / 1000));
  if (d < 60) return "just now";
  if (d < 3600) return `${Math.floor(d / 60)}m ago`;
  if (d < 86_400) return `${Math.floor(d / 3600)}h ago`;
  return `${Math.floor(d / 86_400)}d ago`;
}

/// mm:ss / Ns countdown for the overlay (matches BlockedOverlay.formatRemaining).
export function formatRemaining(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

/// Short status label for a lifecycle event, used as a prefix in the
/// Recent Triggers rows and the blocking overlay.
export const EVENT_LABEL: Record<string, string> = {
  done: "Done",
  "needs-input": "Needs you",
  replied: "Replied",
};
