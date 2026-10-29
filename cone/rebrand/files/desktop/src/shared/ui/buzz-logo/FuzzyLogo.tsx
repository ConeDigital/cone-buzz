import { cn } from "@/shared/lib/cn";
import BuzzLogoAnimation, {
  type BuzzLogoAnimationProps,
} from "./BuzzLogoAnimation";

/**
 * Upstream's "fuzzy" mark (a noise-textured bee). Cone shows the mark with a
 * pulse (cone-buzz-infra Slice 36, #240); the props are upstream's so every
 * caller compiles unchanged — `fuzz`, `loop`, `loopRestSeconds`, `reverse`
 * and `variant` are accepted and ignored, `pulse={false}` turns the pulse off
 * for a parent that animates the mark itself.
 */
export type FuzzyLogoProps = {
  fuzz?: boolean;
  className?: string;
  ariaLabel?: string;
  loop?: boolean;
  loopRestSeconds?: number;
  pulse?: boolean;
  reverse?: boolean;
  variant?: BuzzLogoAnimationProps["variant"];
};

export function FuzzyLogo({
  className,
  ariaLabel = "Cone logo",
  pulse = true,
}: FuzzyLogoProps) {
  return (
    <BuzzLogoAnimation
      ariaLabel={ariaLabel}
      className={cn(pulse ? "buzz-logo--pulse" : "buzz-logo--still", className)}
      fullScreen={false}
      showBackground={false}
    />
  );
}
