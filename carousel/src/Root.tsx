import "./index.css";
import { Still } from "remotion";
import {
  Slide1Pitch,
  Slide2Ping,
  Slide3Spread,
  Slide4Setup,
  Slide1Pitch65,
  Slide2Ping65,
  Slide3Spread65,
  Slide4Setup65,
} from "./slides";

// App Store screenshots in both accepted iPhone sizes:
//   6.9" → 1320×2868   ·   6.5" → 1242×2688
// The spread comps are double-wide (two panes + the band the App Store
// gallery gutter swallows); scripts/export.sh splits them after rendering.
// 6.5" spread: 2706 × (1242/1320) = 2546.4 → 2546 (the 0.4px falls off the
// far right edge); pane width scales to exactly 1242, gutter band 62px.
export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Still id="Slide1Pitch" component={Slide1Pitch} width={1320} height={2868} />
      <Still id="Slide2Ping" component={Slide2Ping} width={1320} height={2868} />
      <Still id="Slide3Spread" component={Slide3Spread} width={2706} height={2868} />
      <Still id="Slide4Setup" component={Slide4Setup} width={1320} height={2868} />

      <Still id="Slide1Pitch65" component={Slide1Pitch65} width={1242} height={2688} />
      <Still id="Slide2Ping65" component={Slide2Ping65} width={1242} height={2688} />
      <Still id="Slide3Spread65" component={Slide3Spread65} width={2546} height={2688} />
      <Still id="Slide4Setup65" component={Slide4Setup65} width={1242} height={2688} />
    </>
  );
};
