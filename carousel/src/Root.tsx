import "./index.css";
import { Still } from "remotion";
import { Slide1Pitch, Slide2Ping, Slide3Spread, Slide4Setup } from "./slides";

// App Store 6.9" screenshots: 1320×2868. The spread comp is 574 preview
// units wide (2706 px): two 1320 px halves + the 66 px band the App Store
// gallery gutter swallows. scripts/export.sh splits it after rendering.
export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Still id="Slide1Pitch" component={Slide1Pitch} width={1320} height={2868} />
      <Still id="Slide2Ping" component={Slide2Ping} width={1320} height={2868} />
      <Still id="Slide3Spread" component={Slide3Spread} width={2706} height={2868} />
      <Still id="Slide4Setup" component={Slide4Setup} width={1320} height={2868} />
    </>
  );
};
