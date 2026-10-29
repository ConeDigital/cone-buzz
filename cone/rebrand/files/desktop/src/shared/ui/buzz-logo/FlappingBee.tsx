import { BuzzMark } from "./BuzzMark";

/**
 * The start-up splash mark (cone-buzz-infra Slice 36, #240: "mark with a
 * pulse"): the Cone mark with a soft opacity pulse instead of upstream's
 * flapping bee. Plain SVG + CSS, so it paints on the first frame and keeps
 * pulsing on the compositor while the app boots; reduced motion stops the
 * pulse (buzz-logo-animation.css). Keeps upstream's export and props.
 */
export function FlappingBee({ className }: { className?: string }) {
  return (
    <div
      aria-hidden="true"
      className={["buzz-logo", "buzz-logo--pulse", "relative", "aspect-square", className]
        .filter(Boolean)
        .join(" ")}
    >
      <BuzzMark className="block h-full w-full" />
    </div>
  );
}
