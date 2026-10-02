import Link from "next/link";

import { NavLinks } from "@/components/nav-links";
import { WalletButton } from "@/components/wallet-button";

function SunMark() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" aria-hidden="true" className="shrink-0">
      <defs>
        <linearGradient id="sm" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#ffd9a1" />
          <stop offset="1" stopColor="#ff7a2f" />
        </linearGradient>
        <clipPath id="smc">
          <rect x="0" y="0" width="24" height="14.5" />
        </clipPath>
      </defs>
      <circle cx="12" cy="14.5" r="8" fill="url(#sm)" clipPath="url(#smc)" />
      <path d="M2 17.5h20M5 21h14" stroke="#86a9dc" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-50 px-3 pt-3 sm:px-6">
      <div className="glass glass-strong mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-x-4 gap-y-1 px-3 py-1.5 sm:px-4">
        <Link
          href="/"
          prefetch={false}
          className="inline-flex min-h-11 items-center gap-2 font-display text-[1.35rem] tracking-tight sm:min-h-10"
        >
          <SunMark />
          Sundown
        </Link>
        <div className="order-3 -mx-1 w-full overflow-x-auto sm:order-none sm:mx-0 sm:w-auto sm:overflow-visible [scrollbar-width:none]">
          <NavLinks />
        </div>
        <div className="flex items-center gap-1">
          <WalletButton />
        </div>
      </div>
    </header>
  );
}
