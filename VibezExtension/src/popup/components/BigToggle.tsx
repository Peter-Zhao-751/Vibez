// The WARP-style pill toggle. ON shows a silent waveform baseline; OFF shows
// three chaotic audio-meter bars (nothing's blocking the doomscroll yet).
// Ported from Components.swift (BigToggle + BlockerKnob).

import { useEffect, useRef, useState } from "react";
import type { Theme } from "../../theme";

const PILL_W = 240;
const PILL_H = 120;
const KNOB = 104;
const PAD = 8;

interface BigToggleProps {
  enabled: boolean;
  interactive: boolean;
  theme: Theme;
  onChange: (next: boolean) => void;
  onLockedTap?: () => void;
}

export function BigToggle({
  enabled,
  interactive,
  theme,
  onChange,
  onLockedTap,
}: BigToggleProps) {
  const [shaking, setShaking] = useState(false);

  const knobX = enabled ? PILL_W - KNOB - PAD : PAD;
  const track = enabled
    ? `linear-gradient(135deg, ${theme.pillStops[0]}, ${theme.pillStops[1]})`
    : theme.bgWidget;

  const click = () => {
    if (!interactive) {
      setShaking(true);
      setTimeout(() => setShaking(false), 460);
      onLockedTap?.();
      return;
    }
    onChange(!enabled);
  };

  return (
    <button
      className={`vz-toggle${shaking ? " vz-shake" : ""}`}
      style={{ width: PILL_W, height: PILL_H, opacity: interactive ? 1 : 0.9 }}
      onClick={click}
      aria-label={enabled ? "Disable Vibez" : "Enable Vibez"}
    >
      <div
        className="vz-toggle-track"
        style={{ width: PILL_W, height: PILL_H, background: track }}
      />
      <span
        className="vz-toggle-label"
        style={{ right: 30, opacity: enabled ? 0 : 1, color: theme.fgFaint }}
      >
        OFF
      </span>
      <span
        className="vz-toggle-label"
        style={{ left: 30, opacity: enabled ? 1 : 0, color: "rgba(255,255,255,0.9)" }}
      >
        ON
      </span>
      <div
        className="vz-toggle-knob"
        style={{ left: knobX, width: KNOB, height: KNOB, background: theme.knobBg }}
      >
        {interactive && <WaveformKnob listening={enabled} size={84} stroke={theme.fg} />}
      </div>
    </button>
  );
}

function WaveformKnob({
  listening,
  size,
  stroke,
}: {
  listening: boolean;
  size: number;
  stroke: string;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;

    const dpr = globalThis.devicePixelRatio || 1;
    canvas.width = size * dpr;
    canvas.height = size * dpr;
    ctx.scale(dpr, dpr);
    ctx.lineCap = "round";
    ctx.strokeStyle = stroke;

    let raf = 0;
    const bars = [
      { cx: 0.3, period: 1.4, phase: 0.0, amp: 0.2 },
      { cx: 0.5, period: 1.6, phase: 0.7, amp: 0.28 },
      { cx: 0.7, period: 1.2, phase: 1.4, amp: 0.18 },
    ];

    const draw = () => {
      ctx.clearRect(0, 0, size, size);
      ctx.strokeStyle = stroke;
      if (listening) {
        ctx.lineWidth = size * 0.04;
        ctx.beginPath();
        ctx.moveTo(size * 0.22, size * 0.5);
        ctx.lineTo(size * 0.78, size * 0.5);
        ctx.stroke();
        return;
      }
      const t = performance.now() / 1000;
      ctx.lineWidth = size * 0.05;
      const mid = size * 0.5;
      for (const b of bars) {
        const p = (t / b.period + b.phase) * 2 * Math.PI;
        const amp = b.amp * size * (0.5 + 0.5 * Math.abs(Math.sin(p)));
        const x = b.cx * size;
        ctx.beginPath();
        ctx.moveTo(x, mid - amp);
        ctx.lineTo(x, mid + amp);
        ctx.stroke();
      }
      raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [listening, size, stroke]);

  return <canvas ref={ref} style={{ width: size, height: size }} />;
}
