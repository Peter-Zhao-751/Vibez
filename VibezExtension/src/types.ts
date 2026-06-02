// Shared domain types. Mirror the iOS app's NotifyClient.swift vocabulary so
// the same backend payload maps cleanly: event / shield / session / agent.

/// What lifecycle moment a push represents (FCM/Firestore `event` field).
export type VibezEvent = "done" | "needs-input" | "replied";

/// Whether the browser should be shielded right now (`shield` field).
export type VibezShield = "on" | "off";

/// Which agent produced the event ("cc" → Claude Code, "cx" → Codex).
export type VibezAgent = "cc" | "cx";

/// UI accent identity (mirrors the iOS `Agent` enum used by Theme.make).
export type AgentTheme = "claude" | "codex" | "both";

export type AppearancePref = "system" | "light" | "dark";

/// One event document read from Firestore `events/{vibezId}/items/{id}`.
export interface VibezEventDoc {
  id: string;
  title: string;
  body: string;
  event: VibezEvent | null;
  shield: VibezShield | null;
  session: string | null;
  agent: VibezAgent | null;
  /// Epoch millis (server createdAt, or arrival time as a fallback).
  createdAt: number;
}

/// Per-session pending block (analog of ScreenTimeManager.pendingTriggers).
/// Keyed by session id (untagged events get a synthetic key). Value is the
/// expiry in epoch millis.
export type PendingSessions = Record<string, number>;

/// What the overlay renders — the most recent blocking event.
export interface OverlayInfo {
  title: string;
  body: string;
  agent: VibezAgent | null;
  event: VibezEvent | null;
  /// Expiry of the session that produced this overlay (for the countdown).
  expiresAt: number | null;
}

/// The live block state the background SW publishes to chrome.storage. The
/// content script reads this to decide whether to show the overlay.
export interface BlockState {
  sessions: PendingSessions;
  latest: OverlayInfo | null;
  /// True while a "Test overlay" preview is active. Lets the content script
  /// show the overlay on the current tab regardless of the site list (a real
  /// block requires a site-list match).
  preview: boolean;
  updatedAt: number;
}

/// A row in the Recent Triggers list (analog of iOS TriggerEvent).
export interface TriggerRecord {
  id: string;
  receivedAt: number;
  agent: VibezAgent | null;
  title: string;
  body: string;
  event: VibezEvent | null;
  blockSeconds: number;
  sessionId: string | null;
}

/// Today-only analytics (resets at local midnight; analog of DailyStats).
export interface AnalyticsToday {
  date: string; // YYYY-MM-DD (local)
  sessionIds: string[]; // unique conversations seen today → "chats"
  replies: number; // shield:off events → "replies"
  pings: number; // total events seen
  focusSeconds: number; // accumulated block-active time today
  perDomainBlocks: Record<string, number>; // domain → times shielded
  /// Set while a block is currently active so focusSeconds can include the
  /// in-flight interval; null when nothing is blocked.
  blockStartedAt: number | null;
}

export type OverlayOrder = "newest" | "oldest";

export interface Settings {
  appearance: AppearancePref;
  agent: AgentTheme;
  allowDismiss: boolean;
  blockSecondsDone: number;
  blockSecondsNeedsInput: number;
  /// Which pending block the overlay shows when several are active at once.
  overlayOrder: OverlayOrder;
}

export type RegistrationPhase = "idle" | "registering" | "registered" | "error";

export interface RegistrationState {
  phase: RegistrationPhase;
  error: string | null;
}

/// The full chrome.storage.local shape.
export interface StoredState {
  vibezId: string;
  clientId: string;
  registration: RegistrationState;
  armed: boolean;
  sites: string[];
  settings: Settings;
  blockState: BlockState;
  analytics: AnalyticsToday;
  recentTriggers: TriggerRecord[];
}
