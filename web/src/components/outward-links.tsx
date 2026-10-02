import Link from "next/link";

import { buttonVariants } from "@/components/ui/button";
import { FACTORY_URL, REPO_URL, VIDEO_URL } from "@/config/links";
import { cn } from "@/lib/utils";

/** Outward links: source, the live deployment (and its factory on Arbiscan), and the demo video once it exists. */
export function OutwardLinks({ variant = "buttons", className }: { variant?: "buttons" | "inline"; className?: string }) {
  const base = variant === "buttons" ? cn(buttonVariants({ variant: "outline", size: "sm" })) : "underline underline-offset-4 hover:text-foreground";
  return (
    <ul className={cn("flex flex-wrap items-center gap-2", variant === "inline" && "gap-x-5 gap-y-2", className)} data-testid="outward-links">
      <li>
        <a className={base} href={REPO_URL} rel="noopener noreferrer" target="_blank">
          View source
        </a>
      </li>
      <li>
        <Link className={base} href="/deployment" prefetch={false}>
          Live on Arbitrum Sepolia
        </Link>
      </li>
      <li>
        <a className={base} href={FACTORY_URL} rel="noopener noreferrer" target="_blank">
          Factory on Arbiscan
        </a>
      </li>
      {VIDEO_URL ? (
        <li>
          <a className={base} href={VIDEO_URL} rel="noopener noreferrer" target="_blank">
            Demo video
          </a>
        </li>
      ) : null}
    </ul>
  );
}
