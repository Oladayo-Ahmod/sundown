import path from "node:path";

import { test } from "@playwright/test";

// Writes screenshots to docs/figures/web/. Run explicitly: SHOTS=1 pnpm exec playwright test tests/screenshots.spec.ts
// Pages with the WebGL sky are captured with the real three.js scene (software GL) after every reveal has played.
const OUT = process.env.SCREENSHOT_DIR ?? path.resolve(__dirname, "../../docs/figures/web");
const PAGES = [
  { name: "home", path: "/?sky=webgl", webgl: true },
  { name: "risk", path: "/risk" },
  { name: "replay", path: "/replay" },
  { name: "deployment", path: "/deployment" },
  { name: "markets", path: "/markets" },
  { name: "preflight", path: "/preflight" },
];
const WIDTHS = [1440, 390];

test.use({
  reducedMotion: "no-preference",
  launchOptions: { args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] },
});

for (const p of PAGES) {
  for (const w of WIDTHS) {
    test(`screenshot ${p.name} ${w}px`, async ({ page }) => {
      await page.setViewportSize({ width: w, height: 900 });
      await page.goto(p.path);
      await page.waitForLoadState("networkidle");
      if (p.webgl) {
        await page.locator("[data-sky-mode=webgl]").first().waitFor({ timeout: 30_000 });
        await page.waitForTimeout(4500); // let the sun ease to the live state
      }
      // scroll through so scroll-triggered reveals and count-ups finish, then back to the top
      const h = await page.evaluate(() => document.documentElement.scrollHeight);
      for (let y = 0; y < h; y += 600) {
        await page.evaluate((yy) => window.scrollTo(0, yy), y);
        await page.waitForTimeout(220);
      }
      await page.waitForTimeout(1600);
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.waitForTimeout(500);
      await page.screenshot({ path: path.join(OUT, `${p.name}-${w}.png`), fullPage: true });
    });
  }
}

// Real scroll-position captures (viewport only, not full page) of the home page, with the WebGL sky.
const SCROLL_OUT = process.env.SCROLL_DIR ?? OUT;
for (const [w, h] of [[1440, 900], [390, 844]] as const) {
  test(`home scroll positions ${w}px`, async ({ page }) => {
    await page.setViewportSize({ width: w, height: h });
    await page.goto("/?sky=webgl");
    await page.locator("[data-sky-mode=webgl]").first().waitFor({ timeout: 30_000 });
    await page.waitForTimeout(1200);
    for (const y of [0, 900, 1800]) {
      await page.evaluate((yy) => window.scrollTo(0, yy), y);
      await page.waitForTimeout(y === 0 ? 300 : 1600);
      await page.screenshot({ path: path.join(SCROLL_OUT, `home-${w}-scroll${y}.png`), fullPage: false });
    }
  });
}
