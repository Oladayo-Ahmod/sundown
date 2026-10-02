import type { Metadata, Viewport } from "next";
import { Fraunces, Geist, Geist_Mono } from "next/font/google";

import { PointerGlow } from "@/components/motion";
import { SiteFooter } from "@/components/site-footer";
import { SiteHeader } from "@/components/site-header";

import "./globals.css";

/**
 * Display serif: Fraunces. An "old-style soft" variable serif with an optical-size axis, so large headlines get
 * high-contrast, tightly drawn letterforms while small sizes stay sturdy, and its italic is genuinely expressive
 * (the SOFT and WONK axes) rather than a slanted roman. That italic is used for the one phrase in a headline that
 * carries the argument. Instrument Serif was the alternative: elegant, but a single weight and no optical sizes.
 * UI text: Geist (a precise, neutral grotesk). Numbers, addresses and hashes: Geist Mono with tabular, slashed zeros.
 */
const display = Fraunces({
  subsets: ["latin"],
  axes: ["opsz", "SOFT", "WONK"],
  style: ["normal", "italic"],
  variable: "--font-fraunces",
  display: "swap",
});
const sans = Geist({ subsets: ["latin"], variable: "--font-geist-sans", display: "swap" });
const mono = Geist_Mono({ subsets: ["latin"], variable: "--font-geist-mono", display: "swap" });

export const metadata: Metadata = {
  title: { default: "Sundown: session-aware credit risk for tokenized stocks", template: "%s | Sundown" },
  description:
    "Research evidence for a session-aware risk layer for tokenized-stock collateral: weekend and holiday gap risk, calibrated limits, and replay of real historical gaps.",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#07060f",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`dark ${display.variable} ${sans.variable} ${mono.variable}`}>
      <body className="min-h-screen antialiased">
        <div className="sky-backdrop" aria-hidden="true" />
        <div className="sky-noise" aria-hidden="true" />
        <a
          href="#main"
          className="sr-only z-[60] rounded-lg bg-primary px-3 py-2 text-primary-foreground focus:not-sr-only focus:fixed focus:top-2 focus:left-2"
        >
          Skip to content
        </a>
        <PointerGlow />
        <SiteHeader />
        <main id="main" className="mx-auto max-w-6xl px-4 pb-16 pt-8 sm:px-6">
          {children}
        </main>
        <SiteFooter />
      </body>
    </html>
  );
}
