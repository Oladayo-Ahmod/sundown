import path from "node:path";

import { test } from "@playwright/test";

// Writes screenshots to docs/figures/web/. Run explicitly: pnpm exec playwright test tests/screenshots.spec.ts
const OUT = process.env.SCREENSHOT_DIR ?? path.resolve(__dirname, "../../docs/figures/web");
const PAGES = [
  { name: "home", path: "/" },
  { name: "risk", path: "/risk" },
  { name: "replay", path: "/replay" },
  { name: "deployment", path: "/deployment" },
  { name: "markets", path: "/markets" },
  { name: "preflight", path: "/preflight" },
];
const WIDTHS = [1280, 390];

for (const p of PAGES) {
  for (const w of WIDTHS) {
    test(`screenshot ${p.name} ${w}px`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: "light" });
      await page.setViewportSize({ width: w, height: 900 });
      await page.goto(p.path);
      await page.waitForLoadState("networkidle");
      await page.screenshot({ path: path.join(OUT, `${p.name}-${w}.png`), fullPage: true });
    });
  }
}
