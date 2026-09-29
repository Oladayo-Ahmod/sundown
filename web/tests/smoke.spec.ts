import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";

const PAGES = [
  { path: "/", h1: /Tokenized stocks trade almost around the clock/, minSrc: 12, mustHave: ["Claims we will not make"] },
  { path: "/risk", h1: /Risk evidence/, minSrc: 80, mustHave: ["Out-of-sample gap-VaR backtest", "Limitations", "Simulation"] },
  { path: "/replay", h1: /Replay: control versus Sundown/, minSrc: 60, mustHave: ["Research simulation", "On-chain replay", "Not deployed yet"] },
] as const;

function collectErrors(page: Page): string[] {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(`console: ${m.text()}`);
  });
  return errors;
}

for (const p of PAGES) {
  test.describe(`page ${p.path}`, () => {
    test("renders, no errors, sources tagged", async ({ page }) => {
      const errors = collectErrors(page);
      const res = await page.goto(p.path);
      expect(res?.status()).toBe(200);
      await expect(page.getByRole("heading", { level: 1 })).toHaveText(p.h1);
      for (const t of p.mustHave) await expect(page.getByText(t, { exact: false }).first()).toBeVisible();
      expect(await page.locator("[data-src]").count()).toBeGreaterThanOrEqual(p.minSrc);
      expect(await page.getByTestId("sources").count()).toBeGreaterThan(0);
      await expect(page.getByRole("link", { name: "Skip to content" })).toBeAttached();
      expect(errors).toEqual([]);
    });

    test("no horizontal overflow at 360px", async ({ page }) => {
      await page.setViewportSize({ width: 360, height: 800 });
      await page.goto(p.path);
      await page.waitForLoadState("networkidle");
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      expect(overflow).toBeLessThanOrEqual(0);
    });

    test("no serious accessibility violations (light and dark)", async ({ page }) => {
      for (const scheme of ["light", "dark"] as const) {
        await page.emulateMedia({ colorScheme: scheme });
        await page.goto(p.path);
        await page.waitForLoadState("networkidle");
        const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
        const bad = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
        expect(bad.map((v) => `${scheme}: ${v.id}: ${v.nodes.map((n) => n.target.join(" ")).slice(0, 3).join(" | ")}`)).toEqual([]);
      }
    });
  });
}

test("theme toggle switches the document theme", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto("/");
  await expect(page.locator("html")).not.toHaveClass(/dark/);
  await page.getByRole("button", { name: /Switch to dark theme/ }).click();
  await expect(page.locator("html")).toHaveClass(/dark/);
});

test("navigation reaches every page", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Risk" }).click();
  await expect(page).toHaveURL(/\/risk$/);
  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Replay" }).click();
  await expect(page).toHaveURL(/\/replay$/);
});

test("replay events filter by asset", async ({ page }) => {
  await page.goto("/replay");
  const table = page.getByRole("table", { name: "Most severe real weekend and holiday gaps" });
  const before = await table.locator("tbody tr").count();
  await page.getByLabel("Asset", { exact: true }).selectOption("SPY");
  const after = await table.locator("tbody tr").count();
  expect(after).toBeGreaterThan(0);
  expect(after).toBeLessThan(before);
  await expect(table.locator("tbody tr").first()).toContainText("SPY");
});

test("wallet stack loads only on request and makes no contract calls", async ({ page }) => {
  const requests: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  expect(requests.some((u) => /rainbow|wagmi/i.test(u))).toBe(false);
  await page.getByRole("button", { name: /Connect wallet/ }).click();
  await expect(page.getByRole("button", { name: /Connect Wallet/i })).toBeVisible({ timeout: 20_000 });
  expect(requests.some((u) => /arb-sepolia|sepolia-rollup/.test(u))).toBe(false);
});
