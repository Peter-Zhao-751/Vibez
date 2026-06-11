import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";

// All layout values were approved in the brainstorm preview at 280×608
// "preview units"; u() scales them to the 1320×2868 export. The spread
// scene is 574 preview units wide (two panes + a 14-unit App Store
// gutter that swallows scene content between them) → 2706 px comp,
// split into two 1320 px halves at render time (ffmpeg), skipping the
// 66 px gutter band.
const SCALE = 1320 / 280;
const u = (n: number) => n * SCALE;

const INK = "#1a1410";
const CREAM = "#faf4ea";
const ORANGE = "#d97757";
const PERIWINKLE = "#7287e0";
const SUB_INK = "rgba(26,20,16,0.6)";
const SYSTEM_FONT =
  "-apple-system, 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif";

const Canvas: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <AbsoluteFill style={{ background: CREAM, fontFamily: SYSTEM_FONT }}>
    {children}
  </AbsoluteFill>
);

const Headline: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      position: "absolute",
      top: u(46),
      left: 0,
      right: 0,
      padding: `0 ${u(24)}px`,
      color: INK,
      fontSize: u(32),
      fontWeight: 900,
      letterSpacing: -u(1.25),
      lineHeight: 1.1,
    }}
  >
    {children}
  </div>
);

const Sub: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      position: "absolute",
      top: u(138),
      left: 0,
      right: 0,
      padding: `0 ${u(24)}px`,
      color: SUB_INK,
      fontSize: u(12.5),
      fontWeight: 500,
      lineHeight: 1.45,
    }}
  >
    {children}
  </div>
);

const Bezel: React.FC<{
  src: string;
  width: number; // preview units
  style?: React.CSSProperties;
  shadow?: string;
}> = ({ src, width, style, shadow }) => (
  <div
    style={{
      position: "absolute",
      width: u(width),
      border: `${u(6)}px solid #1d1d1f`,
      borderRadius: u(32),
      overflow: "hidden",
      background: "#000",
      lineHeight: 0,
      boxShadow: shadow ?? `0 ${u(16)}px ${u(32)}px rgba(26,20,16,0.26)`,
      ...style,
    }}
  >
    <Img
      src={staticFile(src)}
      style={{ width: "100%", borderRadius: u(26), display: "block" }}
    />
  </div>
);

export const Slide1Pitch: React.FC = () => (
  <Canvas>
    <Headline>
      Claude's done.
      <br />
      <span style={{ color: ORANGE }}>Stop scrolling.</span>
    </Headline>
    <Sub>Blocks distracting apps when Claude Code or Codex needs you.</Sub>
    <Bezel
      src="shot-home-armed-light4.png"
      width={204}
      style={{ bottom: -u(30), left: "50%", transform: "translateX(-50%)" }}
    />
  </Canvas>
);

export const Slide2Ping: React.FC = () => (
  <Canvas>
    <Headline>
      Agent pings.
      <br />
      <span style={{ color: ORANGE }}>Phone locks.</span>
    </Headline>
    <Sub>A question — or a finished task — blocks your feeds until you reply.</Sub>
    <Bezel
      src="shot-overlay-cc-done-dark.png"
      width={212}
      style={{ bottom: -u(45), left: "50%", transform: "translateX(-50%)" }}
    />
  </Canvas>
);

// One poster, 574 preview units wide; exported as two screenshots.
export const Slide3Spread: React.FC = () => (
  <Canvas>
    <div
      style={{
        position: "absolute",
        inset: 0,
        background: `linear-gradient(105deg, ${CREAM} 0%, rgba(217,119,87,0.13) 38%, rgba(140,156,232,0.17) 72%, #f2f1f7 100%)`,
      }}
    />
    <div
      style={{
        position: "absolute",
        top: u(120),
        left: u(122),
        width: u(330),
        height: u(330),
        borderRadius: "50%",
        background:
          "radial-gradient(circle, rgba(217,119,87,0.20) 0%, transparent 68%)",
      }}
    />
    <div
      style={{
        position: "absolute",
        top: u(170),
        left: u(230),
        width: u(300),
        height: u(300),
        borderRadius: "50%",
        background:
          "radial-gradient(circle, rgba(140,156,232,0.24) 0%, transparent 68%)",
      }}
    />

    <div
      style={{
        position: "absolute",
        top: u(50),
        left: u(26),
        width: u(250),
        textAlign: "right",
        fontSize: u(32),
        fontWeight: 900,
        letterSpacing: -u(1.2),
        lineHeight: 1.1,
        whiteSpace: "nowrap",
        color: ORANGE,
      }}
    >
      Claude Code
    </div>
    <div
      style={{
        position: "absolute",
        top: u(50),
        left: u(298),
        width: u(250),
        textAlign: "left",
        fontSize: u(32),
        fontWeight: 900,
        letterSpacing: -u(1.2),
        lineHeight: 1.1,
        whiteSpace: "nowrap",
        color: PERIWINKLE,
      }}
    >
      Codex.
    </div>
    <div
      style={{
        position: "absolute",
        top: u(108),
        left: u(46),
        width: u(230),
        textAlign: "right",
        color: SUB_INK,
        fontSize: u(12.5),
        fontWeight: 500,
        lineHeight: 1.45,
      }}
    >
      All your agents, one&nbsp;app
    </div>
    <div
      style={{
        position: "absolute",
        top: u(108),
        left: u(298),
        width: u(230),
        textAlign: "left",
        color: SUB_INK,
        fontSize: u(12.5),
        fontWeight: 500,
        lineHeight: 1.45,
      }}
    >
      orange pings from Claude, blue&nbsp;from&nbsp;Codex.
    </div>

    <Bezel
      src="shot-overlay-cc-light3.png"
      width={229}
      style={{
        top: u(244),
        left: u(140),
        transform: "rotate(-16deg)",
        transformOrigin: "50% 100%",
        zIndex: 1,
      }}
    />
    <Bezel
      src="shot-overlay-cx-dark2.png"
      width={236}
      style={{
        top: u(254),
        left: u(202),
        transform: "rotate(16deg)",
        transformOrigin: "50% 100%",
        zIndex: 2,
      }}
      shadow={`0 ${u(18)}px ${u(40)}px rgba(26,20,16,0.38)`}
    />
  </Canvas>
);

const TERMINAL_TEXT = "#e8e3da";

export const Slide4Setup: React.FC = () => (
  <Canvas>
    <Headline>
      One command.
      <br />
      <span style={{ color: ORANGE }}>You're paired.</span>
    </Headline>
    <Sub>Free, no accounts — a private 4-word ID pairs your Mac to your phone.</Sub>

    <div
      style={{
        position: "absolute",
        top: u(204),
        left: u(20),
        right: u(20),
        background: "#1d1d1f",
        borderRadius: u(12),
        boxShadow: `0 ${u(12)}px ${u(26)}px rgba(26,20,16,0.3)`,
        padding: `${u(9)}px ${u(12)}px ${u(10)}px`,
        zIndex: 2,
      }}
    >
      <div style={{ display: "flex", gap: u(5), marginBottom: u(7) }}>
        <span style={{ width: u(8), height: u(8), borderRadius: "50%", background: "#ff5f57" }} />
        <span style={{ width: u(8), height: u(8), borderRadius: "50%", background: "#febc2e" }} />
        <span style={{ width: u(8), height: u(8), borderRadius: "50%", background: "#28c840" }} />
      </div>
      <div
        style={{
          fontFamily: "'SF Mono', Menlo, monospace",
          fontSize: u(9.5),
          lineHeight: 1.55,
          color: TERMINAL_TEXT,
        }}
      >
        <span style={{ color: "#8c9ce8" }}>$</span> npx getvibez
        <br />
        Detected: Claude Code, Codex
        <br />
        Installing Vibez plugin… done <span style={{ color: "#28c840" }}>✓</span>
        <br />
        Your Vibez ID:{" "}
        <span style={{ color: ORANGE, fontWeight: 700 }}>moss-pine-fox-jazz</span>
      </div>
    </div>

    <Bezel
      src="shot-setup-light2.png"
      width={198}
      style={{ bottom: -u(132), left: "50%", transform: "translateX(-50%)" }}
    />
  </Canvas>
);

// ---- 6.5" (1242×2688) variants -------------------------------------------
// App Store Connect's 6.5-inch slot. Same approved comps, uniformly scaled
// by 1242/1320; the ~10.6px of lost height comes out of the bottom bleed
// (phones already overflow the bottom edge), nothing visible changes.
const SCALE_65 = 1242 / 1320;

const ScaleWrap: React.FC<{ wide?: boolean; children: React.ReactNode }> = ({
  wide,
  children,
}) => (
  <div
    style={{
      position: "absolute",
      width: wide ? 2706 : 1320,
      height: 2868,
      transform: `scale(${SCALE_65})`,
      transformOrigin: "top left",
    }}
  >
    {children}
  </div>
);

export const Slide1Pitch65: React.FC = () => (
  <ScaleWrap>
    <Slide1Pitch />
  </ScaleWrap>
);
export const Slide2Ping65: React.FC = () => (
  <ScaleWrap>
    <Slide2Ping />
  </ScaleWrap>
);
export const Slide3Spread65: React.FC = () => (
  <ScaleWrap wide>
    <Slide3Spread />
  </ScaleWrap>
);
export const Slide4Setup65: React.FC = () => (
  <ScaleWrap>
    <Slide4Setup />
  </ScaleWrap>
);
