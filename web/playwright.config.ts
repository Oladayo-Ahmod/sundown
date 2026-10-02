import { defineConfig } from "@playwright/test";

// Uses the locally installed Chrome (no browser download). Run `pnpm build` first (webServer starts the built app).
export default defineConfig({
  testDir: "./tests",
  testIgnore: process.env.SHOTS ? undefined : "**/screenshots.spec.ts",
  timeout: 60_000,
  fullyParallel: false,
  reporter: [["list"]],
  use: {
    baseURL: "http://localhost:3100",
    channel: "chrome",
    trace: "off",
    reducedMotion: "reduce",
    launchOptions: { args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] },
  },
  webServer: {
    command: "npx next start -p 3100",
    url: "http://localhost:3100",
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
