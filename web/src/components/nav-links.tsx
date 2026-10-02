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
      <ul className="flex items-center gap-1">
        {LINKS.map((l) => {
          const active = pathname === l.href;
          return (
            <li key={l.href}>
              <Link
                prefetch={false}
                href={l.href}
                aria-current={active ? "page" : undefined}
                className={cn(
                  "inline-flex min-h-11 items-center rounded-md px-3 text-sm font-medium hover:bg-accent sm:min-h-9",
                  active ? "bg-accent underline decoration-2 underline-offset-4" : "",
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
