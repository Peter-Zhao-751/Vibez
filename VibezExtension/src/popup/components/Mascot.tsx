// Claude pixel-critter and Codex cloud-bot, ported from the iOS Mascots.swift
// (which came from the reference design's inline SVG). Breathes when listening,
// sleeps with floating z's when not. Character colors are fixed per agent —
// they don't follow the theme accent (matches the iOS mascots).

import type { AgentTheme } from "../../types";
import {
  CLAUDE_ORANGE,
  CLAUDE_DEEP,
  CODEX_BLUE,
  CODEX_DEEP,
} from "../../theme";

const CLAUDE_INK = "#1a0e08";

interface MascotProps {
  agent: AgentTheme;
  listening: boolean;
  size: number;
}

export function Mascot({ agent, listening, size }: MascotProps) {
  if (agent === "both") {
    return (
      <div style={{ display: "flex", alignItems: "flex-end", gap: 6 }}>
        <ClaudeMascot listening={listening} size={size * 0.78} />
        <CodexMascot listening={listening} size={size * 0.78} />
      </div>
    );
  }
  return agent === "codex" ? (
    <CodexMascot listening={listening} size={size} />
  ) : (
    <ClaudeMascot listening={listening} size={size} />
  );
}

function shell(listening: boolean) {
  return `vz-mascot${listening ? " vz-listening" : ""}`;
}

function ClaudeMascot({ listening, size }: { listening: boolean; size: number }) {
  const h = (size * 92) / 112;
  return (
    <svg className={shell(listening)} width={size} height={h} viewBox="-6 0 112 92">
      <g className="vz-breathe">
        {/* body + wings */}
        <rect x={8} y={8} width={84} height={56} fill={CLAUDE_ORANGE} />
        <rect x={-4} y={36} width={12} height={15} fill={CLAUDE_ORANGE} />
        <rect x={92} y={36} width={12} height={15} fill={CLAUDE_ORANGE} />
        {/* legs */}
        {[18, 32, 60, 74].map((x) => (
          <rect key={x} x={x} y={64} width={10} height={18} fill={CLAUDE_ORANGE} />
        ))}
        {/* eyes */}
        <rect x={22} y={28} width={12} height={14} fill={CLAUDE_INK} />
        <rect x={66} y={28} width={12} height={14} fill={CLAUDE_INK} />
      </g>
      <g className="vz-zzz">
        <text x={86} y={20} fontFamily="monospace" fontWeight="800" fontSize={13} fill={CLAUDE_DEEP}>
          z
        </text>
      </g>
    </svg>
  );
}

function CodexMascot({ listening, size }: { listening: boolean; size: number }) {
  const h = (size * 130) / 110;
  return (
    <svg className={shell(listening)} width={size} height={h} viewBox="0 0 110 130">
      <defs>
        <linearGradient id="vz-codex-head" x1="0.4" y1="0.35" x2="0.9" y2="1">
          <stop offset="0" stopColor="#aab8ee" />
          <stop offset="1" stopColor={CODEX_BLUE} />
        </linearGradient>
      </defs>
      <g className="vz-breathe">
        {/* head */}
        <path
          d="M8 70 L8 42 A18 18 0 0 1 28 24 A22 22 0 0 1 55 8 A22 22 0 0 1 82 24 A18 18 0 0 1 102 42 L102 70 Z"
          fill="url(#vz-codex-head)"
          stroke={CODEX_DEEP}
          strokeWidth={1.2}
        />
        {/* face screen */}
        <rect x={26} y={34} width={58} height={32} rx={8} fill="#272a4a" stroke="#1c1f3d" strokeWidth={1.4} />
        {/* arch eyes */}
        <path d="M33 50 Q40 44 47 50" fill="none" stroke="#9af0d8" strokeWidth={3} strokeLinecap="round" />
        <path d="M63 50 Q70 44 77 50" fill="none" stroke="#9af0d8" strokeWidth={3} strokeLinecap="round" />
        {/* neck + body */}
        <rect x={44} y={68} width={22} height={6} fill={CODEX_BLUE} />
        <rect x={30} y={74} width={50} height={38} rx={9} fill={CODEX_BLUE} stroke={CODEX_DEEP} strokeWidth={1} />
        <text x={43} y={99} fontFamily="monospace" fontWeight="800" fontSize={14} fill="#ffffff">
          {">_"}
        </text>
        {/* arms */}
        <rect x={14} y={84} width={18} height={9} rx={4.5} fill={CODEX_BLUE} stroke={CODEX_DEEP} strokeWidth={1} />
        <rect x={78} y={84} width={18} height={9} rx={4.5} fill={CODEX_BLUE} stroke={CODEX_DEEP} strokeWidth={1} />
        {/* feet */}
        <rect x={38} y={112} width={13} height={9} rx={3} fill={CODEX_BLUE} />
        <rect x={59} y={112} width={13} height={9} rx={3} fill={CODEX_BLUE} />
        {/* ground shadow */}
        <ellipse cx={55} cy={124} rx={24} ry={2.5} fill="rgba(0,0,0,0.15)" />
      </g>
      <g className="vz-zzz">
        <text x={94} y={16} fontFamily="monospace" fontWeight="800" fontSize={12} fill={CODEX_DEEP}>
          z
        </text>
      </g>
    </svg>
  );
}
