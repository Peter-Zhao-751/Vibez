// Color palette, ported 1:1 from the iOS app's Theme.swift (which itself was
// translated from the original reference-design `themeFor(agent, dark)` JS).
// Values are CSS hex strings.

import type { AgentTheme } from "./types";

export interface Theme {
  bg: string;
  bgPanel: string;
  bgWidget: string;
  bgChip: string;
  fg: string;
  fgMute: string;
  fgFaint: string;
  hairline: string;
  accent: string;
  accentDeep: string;
  onAccent: string;
  knobBg: string;
  /// Stops for the "ON" pill gradient (top-leading → bottom-trailing).
  pillStops: [string, string];
  dark: boolean;
}

export const CLAUDE_ORANGE = "#dd7a52";
export const CLAUDE_DEEP = "#b85a36";
export const CODEX_BLUE = "#8c9ce8";
export const CODEX_DEEP = "#5d6fbc";

function hexToRgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16),
  ];
}

function rgbToHex(r: number, g: number, b: number): string {
  const c = (n: number) =>
    Math.round(Math.max(0, Math.min(255, n)))
      .toString(16)
      .padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

/// Linear interpolate two hex colors (matches SwiftUI Color.lerp).
export function lerp(a: string, b: string, t: number): string {
  const [ar, ag, ab] = hexToRgb(a);
  const [br, bg, bb] = hexToRgb(b);
  return rgbToHex(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t);
}

/// rgba() helper for opacity overlays (theme.fgMute.opacity(x) etc.).
export function withAlpha(hex: string, alpha: number): string {
  const [r, g, b] = hexToRgb(hex);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function accentFor(agent: AgentTheme): { accent: string; accentDeep: string } {
  switch (agent) {
    case "claude":
      return { accent: CLAUDE_ORANGE, accentDeep: CLAUDE_DEEP };
    case "codex":
      return { accent: CODEX_BLUE, accentDeep: CODEX_DEEP };
    case "both":
      return {
        accent: lerp(CLAUDE_ORANGE, CODEX_BLUE, 0.5),
        accentDeep: lerp(CLAUDE_DEEP, CODEX_DEEP, 0.5),
      };
  }
}

export function makeTheme(agent: AgentTheme, dark: boolean): Theme {
  const { accent, accentDeep } = accentFor(agent);
  const pillStops: [string, string] =
    agent === "both" ? [CLAUDE_ORANGE, CODEX_BLUE] : [accent, accentDeep];

  if (dark) {
    return {
      bg: "#0c0d12",
      bgPanel: "#16171d",
      bgWidget: "#1f2027",
      bgChip: "#16171d",
      fg: "#f5f1ec",
      fgMute: "#6f6c7a",
      fgFaint: "#56545e",
      hairline: "#272832",
      accent,
      accentDeep,
      onAccent: "#ffffff",
      knobBg: "#0e0f14",
      pillStops,
      dark: true,
    };
  }
  return {
    bg: "#fbf8f4",
    bgPanel: "#ffffff",
    bgWidget: "#e4dfd6",
    bgChip: "#f1ede5",
    fg: "#1a0e08",
    fgMute: "#6e655c",
    fgFaint: "#a8a097",
    hairline: "#ece4d8",
    accent,
    accentDeep,
    onAccent: "#ffffff",
    knobBg: "#ffffff",
    pillStops,
    dark: false,
  };
}

/// Map the wire agent tag ("cc"/"cx") to a UI accent identity.
export function agentThemeFor(
  agent: "cc" | "cx" | null,
  fallback: AgentTheme,
): AgentTheme {
  if (agent === "cc") return "claude";
  if (agent === "cx") return "codex";
  return fallback;
}
