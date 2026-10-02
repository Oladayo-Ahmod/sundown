"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { cn } from "@/lib/utils";

const LINKS = [
  { href: "/", label: "Overview" },
  { href: "/risk", label: "Risk" },
  { href: "/replay", label: "Replay" },
  { href: "/deployment", label: "Deployment" },
  { href: "/markets", label: "Markets" },
  { href: "/preflight", label: "Preflight" },
] as const;

export function NavLinks() {
  const pathname = usePathname();
  return (
    <nav aria-label="Primary">
      <ul className="flex items-center gap-0.5">
        {LINKS.map((l) => {
          const active = pathname === l.href;
          return (
            <li key={l.href}>
              <Link
                prefetch={false}
                href={l.href}
                aria-current={active ? "page" : undefined}
                className={cn(
                  "inline-flex min-h-11 items-center rounded-full px-3 text-[0.82rem] font-medium whitespace-nowrap transition-colors sm:min-h-9",
                  active
                    ? "bg-white/[0.12] text-foreground shadow-[inset_0_1px_0_rgb(255_255_255/0.12)]"
                    : "text-muted-foreground hover:bg-white/[0.07] hover:text-foreground",
                )}
              >
                {l.label}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
