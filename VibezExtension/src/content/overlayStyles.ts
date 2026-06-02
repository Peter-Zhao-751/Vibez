// CSS injected into the overlay's shadow root. Self-contained (includes the
// mascot keyframes) so page styles never leak in and ours never leak out.

export const OVERLAY_CSS = `
:host { all: initial; }
* { box-sizing: border-box; margin: 0; padding: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased; }

.vz-ov-root {
  position: fixed; inset: 0; z-index: 2147483647;
  display: flex; align-items: flex-start; justify-content: center;
  overflow: hidden;
}
.vz-ov-glow { position: absolute; inset: 0; pointer-events: none; }
.vz-ov-content {
  position: relative; display: flex; flex-direction: column; align-items: center;
  text-align: center; padding: 0 40px; margin-top: 11vh; max-width: 560px;
}
.vz-ov-tag {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px; font-weight: 800; letter-spacing: 2.4px; margin: 18px 0 10px;
}
.vz-ov-title { font-size: 28px; font-weight: 700; letter-spacing: -0.4px; line-height: 1.2; margin-bottom: 8px; }
.vz-ov-body { font-size: 15px; line-height: 1.5; margin-bottom: 18px; max-width: 460px; }
.vz-ov-count {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 40px; font-weight: 700; margin-bottom: 16px; font-variant-numeric: tabular-nums;
  line-height: 1;
}

/* Rolling countdown digits — new digit slides down in from the top, old
   slides down out the bottom (matches iOS numericText countsDown). */
.vz-roll-row { display: inline-flex; }
.vz-roll { position: relative; display: inline-block; overflow: hidden; }
.vz-roll-in { display: inline-block; animation: vz-roll-in 0.2s ease; }
.vz-roll-out {
  position: absolute; left: 0; top: 0; display: inline-block;
  animation: vz-roll-out 0.2s ease forwards;
}
@keyframes vz-roll-in {
  from { transform: translateY(-100%); opacity: 0; }
  to { transform: translateY(0); opacity: 1; }
}
@keyframes vz-roll-out {
  from { transform: translateY(0); opacity: 1; }
  to { transform: translateY(100%); opacity: 0; }
}
.vz-ov-dismiss {
  background: none; border: 1.2px solid; border-radius: 999px;
  padding: 12px 28px; font-size: 14px; font-weight: 600; cursor: pointer;
}

.vz-mascot .vz-breathe { transform-box: fill-box; transform-origin: 50% 100%; }
.vz-mascot.vz-listening .vz-breathe { animation: vz-breathe 2.4s ease-in-out infinite; }
@keyframes vz-breathe { 0%,100% { transform: scale(1); } 50% { transform: scale(1.04) translateY(-1px); } }
.vz-mascot .vz-zzz { opacity: 0; }
`;
