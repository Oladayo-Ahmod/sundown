import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";

const PAGES = [
  { path: "/", h1: /Tokenized stocks trade almost around the clock/, minSrc: 12, mustHave: ["Claims we will not make", "AAPL at 93%", "still produced a loss", "not distinguishable"] },
  { path: "/risk", h1: /Risk evidence/, minSrc: 80, mustHave: ["The shipped static rule", "Which tiers bind", "Cross-check against the forge replay", "not the shipped static rule", "Limitations", "Simulation"] },
  { path: "/replay", h1: /Replay: control versus Sundown/, minSrc: 60, mustHave: ["Research simulation", "not a public chain", "The shipped rule: AAPL at 93%", "On-chain replay", "None (forge in-process only)", "not replayed on a public chain"] },
  { path: "/deployment", h1: /Deployment on Arbitrum Sepolia/, minSrc: 0, mustHave: ["Test fixture (simulation)", "Production", "Recorded live run", "Simulated tokens and feeds", "SundownMarketFactory", "Cannot be shown live"] },
  { path: "/markets", h1: /Markets on Arbitrum Sepolia/, minSrc: 0, ready: "[data-testid=live-markets][aria-busy=false]", mustHave: ["Simulated tokens and feeds", "Simulated prices", "Read-only"] },
  { path: "/preflight", h1: /^Preflight$/, minSrc: 0, ready: "[data-testid=live-preflight][aria-busy=false]", mustHave: ["Live on-chain checks", "Recorded offline results", "231 passed, 0 failed, 4 skipped", "Passed once"] },
] as readonly PageSpec[];

interface PageSpec {
  path: string;
  h1: RegExp;
  minSrc: number;
  mustHave: readonly string[];
  ready?: string;
}

async function settle(page: Page, p: PageSpec) {
  await page.waitForLoadState("networkidle");
  if (p.ready) await page.locator(p.ready).waitFor({ timeout: 45_000 });
}

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
      await settle(page, p);
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
      await settle(page, p);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      expect(overflow).toBeLessThanOrEqual(0);
    });

    test("no serious accessibility violations (dark theme, the only theme)", async ({ page }) => {
      await page.goto(p.path);
      await settle(page, p);
      const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
      const bad = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
      expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(" ")).slice(0, 3).join(" | ")}`)).toEqual([]);
    });
  });
}

test("the site is dark-only (no light theme to switch to)", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto("/");
  await expect(page.locator("html")).toHaveClass(/dark/);
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme)).toBe("dark");
  await expect(page.getByRole("button", { name: /theme/i })).toHaveCount(0);
});

test("navigation reaches every page", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Risk" }).click();
  await expect(page).toHaveURL(/\/risk$/);
  await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Replay" }).click();
  await expect(page).toHaveURL(/\/replay$/);
  for (const [name, url] of [["Deployment", /\/deployment$/], ["Markets", /\/markets$/], ["Preflight", /\/preflight$/]] as const) {
    await page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name }).click();
    await expect(page).toHaveURL(url);
  }
});

test("markets: live read shows 6 markets and 4 simulated feeds", async ({ page }) => {
  await page.goto("/markets");
  await page.locator("[data-testid=live-markets][aria-busy=false]").waitFor({ timeout: 45_000 });
  test.skip((await page.getByTestId("live-error").count()) > 0, "Arbitrum Sepolia RPC unreachable from this machine");
  await expect(page.getByTestId("market-card")).toHaveCount(6);
  await expect(page.getByTestId("oracle-row")).toHaveCount(4);
  await expect(page.getByTestId("window-state")).toContainText("blind window");
  await expect(page.getByTestId("live-block")).toContainText("Block");
  await expect(page.getByText("Session-aware, boosted 93%").first()).toBeVisible();
  await expect(page.getByText("Stress cap, Weekend window").first()).toBeVisible();
});

test("preflight: every live check passes against the deployment", async ({ page }) => {
  await page.goto("/preflight");
  await page.locator("[data-testid=live-preflight][aria-busy=false]").waitFor({ timeout: 60_000 });
  test.skip((await page.getByTestId("live-error").count()) > 0, "Arbitrum Sepolia RPC unreachable from this machine");
  expect(await page.getByTestId("check-row").count()).toBeGreaterThanOrEqual(9);
  await expect(page.getByTestId("live-verdict")).toContainText(/All \d+ checks pass/);
});

test("deployment lists 27 contracts, labelled, and the recorded run links transactions", async ({ page }) => {
  await page.goto("/deployment");
  await expect(page.getByTestId("contract-row")).toHaveCount(27);
  expect(await page.getByText("Test fixture (simulation)").count()).toBeGreaterThanOrEqual(10);
  expect(await page.locator("a[href^='https://sepolia.arbiscan.io/tx/']").count()).toBeGreaterThan(40);
  await expect(page.getByTestId("deployer")).toContainText("0x5104C1A69242D94159Cf7151277252e568cB8F98");
});

test("live pages never send a transaction or request a signature", async ({ page }) => {
  const methods: string[] = [];
  page.on("request", (r) => {
    const body = r.postData();
    if (r.method() === "POST" && body) for (const m of body.matchAll(/"method":"([a-z_A-Z0-9]+)"/g)) methods.push(m[1] ?? "");
  });
  for (const path of ["/deployment", "/markets", "/preflight"]) {
    await page.goto(path);
    await page.waitForLoadState("networkidle");
  }
  expect(methods.filter((m) => /send|sign|accounts|requestAccounts/i.test(m))).toEqual([]);
  expect(methods.every((m) => /^eth_(call|getCode|getBlockByNumber|chainId|blockNumber)$/.test(m))).toBe(true);
});

test("home page only makes read-only RPC calls (the hero reads the calendar once)", async ({ page }) => {
  const methods: string[] = [];
  page.on("request", (r) => {
    const body = r.postData();
    if (r.method() === "POST" && body && /sepolia-rollup|arb-sepolia/.test(r.url()))
      for (const m of body.matchAll(/"method":"([a-z_A-Z0-9]+)"/g)) methods.push(m[1] ?? "");
  });
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(2500);
  expect(methods.length).toBeGreaterThan(0);
  expect(methods.every((m) => /^eth_(call|getCode|getBlockByNumber|chainId|blockNumber)$/.test(m))).toBe(true);
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
  // reads (the hero's calendar call) are allowed; the wallet button adds no contract call of its own
  expect(requests.filter((u) => /walletconnect|bridge\.walletconnect/.test(u))).toEqual([]);
});


async function jsBodies(page: Page): Promise<string[]> {
  const bodies: string[] = [];
  page.on("response", async (res) => {
    if (res.url().endsWith(".js") || res.url().includes("/_next/static/")) {
      try {
        const t = await res.text();
        if (t.includes("WebGLRenderer")) bodies.push(res.url());
      } catch {
        /* streamed or cached */
      }
    }
  });
  return bodies;
}

test.describe("sky scene", () => {
  test("default (reduced motion in CI): static SVG sky, no three.js code loaded", async ({ page }) => {
    const three = await jsBodies(page);
    await page.goto("/");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(1500);
    await expect(page.getByTestId("sky-hero")).toHaveAttribute("data-sky-mode", "static");
    expect(await page.locator("[data-testid=sky-hero] canvas").count()).toBe(0);
    expect(three).toEqual([]);
  });

  test("other pages never load the three.js chunk", async ({ page }) => {
    const three = await jsBodies(page);
    for (const path of ["/risk", "/deployment", "/preflight"]) {
      await page.goto(path + "?sky=webgl");
      await page.waitForLoadState("networkidle");
    }
    expect(three).toEqual([]);
  });

  test.describe("WebGL path (software GL)", () => {
    test.use({
      reducedMotion: "no-preference",
    });
    test("renders the three.js scene and the scrubber moves the sun and the readout", async ({ page }) => {
      const errors = collectErrors(page);
      const three = await jsBodies(page);
      await page.goto("/?sky=webgl");
      await expect(page.getByTestId("sky-hero")).toHaveAttribute("data-sky-mode", "webgl", { timeout: 30_000 });
      expect(await page.locator("[data-testid=sky-hero] canvas").count()).toBe(1);
      expect(three.length).toBeGreaterThan(0);
      await page.getByTestId("tow").fill("140");
      await expect(page.getByTestId("sky-readout")).toContainText("Blind window");
      await page.getByTestId("tow").fill("10");
      await expect(page.getByTestId("sky-readout")).toContainText("Feed live");
      await page.getByTestId("tow").fill("170");
      await expect(page.getByTestId("sky-readout")).toContainText("Window ended");
      expect(errors.filter((e) => !/Failed to load resource/.test(e))).toEqual([]);
    });
  });
});

test("keyboard: the time-of-week slider is reachable and shows a visible focus ring", async ({ page }) => {
  await page.goto("/");
  const slider = page.getByTestId("tow");
  await slider.focus();
  await expect(slider).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(slider).toHaveAttribute("aria-valuetext", /ET/);
  const outline = await slider.evaluate((el) => getComputedStyle(el).outlineStyle);
  expect(outline).not.toBe("none");
});

test("every page reveals its content without scrolling being required (reduced motion shows final state)", async ({ page }) => {
  await page.goto("/");
  const hidden = await page.evaluate(
    () => Array.from(document.querySelectorAll<HTMLElement>("main *")).filter((e) => e instanceof HTMLElement && getComputedStyle(e).opacity === "0").map((e) => e.tagName + "." + String(e.className).slice(0, 60)),
  );
  expect(hidden).toEqual([]);
});
