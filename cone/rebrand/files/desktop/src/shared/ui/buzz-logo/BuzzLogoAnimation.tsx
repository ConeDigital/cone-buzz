import type { CSSProperties } from "react";

import { BuzzMark } from "./BuzzMark";
import "./buzz-logo-animation.css";

/**
 * The loading mark (cone-buzz-infra Slice 36, #240: "mark with a pulse").
 * Upstream morphs a bee out of noise here; Cone shows its mark with a soft
 * pulse. The props are upstream's so every caller compiles unchanged: the
 * morph-only ones (`loop`, `loopRestSeconds`, `reverse`, `textured`,
 * `variant`) are accepted and ignored; `fullScreen` and `showBackground`
 * keep their layout meaning. A caller that passes its own pulse class
 * (`buzz-logo--scale-pulse`) gets that instead of the opacity pulse.
 */
export type BuzzLogoAnimationProps = {
  ariaLabel?: string;
  className?: string;
  fullScreen?: boolean;
  loop?: boolean;
  loopRestSeconds?: number;
  reverse?: boolean;
  showBackground?: boolean;
  style?: CSSProperties;
  textured?: boolean;
  variant?: string;
};

export default function BuzzLogoAnimation({
  ariaLabel = "Cone logo",
  className = "",
  fullScreen = true,
  showBackground = true,
  style,
}: BuzzLogoAnimationProps) {
  const ownPulse = /\bbuzz-logo--(scale-pulse|pulse|still)\b/.test(className) ? "" : "buzz-logo--pulse";
  const mark = (
    <div
      aria-label={ariaLabel}
      className={["buzz-logo", ownPulse, className].filter(Boolean).join(" ")}
      role="img"
      style={style}
    >
      <BuzzMark className="block h-auto w-full" />
    </div>
  );
  if (!fullScreen) return mark;
  return (
    <div
      className={[
        "fixed inset-0 flex items-center justify-center",
        showBackground ? "bg-background" : "",
      ]
        .filter(Boolean)
        .join(" ")}
    >
      <div style={{ width: "7rem" }}>{mark}</div>
    </div>
  );
}
