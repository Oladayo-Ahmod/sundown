import Link from "next/link";

import { NavLinks } from "@/components/nav-links";
import { ThemeToggle } from "@/components/theme-toggle";
import { WalletButton } from "@/components/wallet-button";

export function SiteHeader() {
  return (
    <header className="border-b border-border">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-x-4 gap-y-1 px-4 py-2">
        <Link href="/" prefetch={false} className="inline-flex min-h-11 items-center text-lg font-bold tracking-tight">
          Sundown
        </Link>
        <div className="flex flex-wrap items-center gap-1">
          <NavLinks />
          <ThemeToggle />
          <WalletButton />
        </div>
      </div>
    </header>
  );
}
