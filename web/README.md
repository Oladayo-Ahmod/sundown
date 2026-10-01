# web/

Research UI for Sundown: `/` (problem, headline claims with CIs, claims we do not make), `/risk` (gap distributions, out-of-sample backtest, equal-risk frontier, calibrated parameters, measured rates, limitations) and `/replay` (control versus Sundown on real historical gaps). **Research simulation only: no contract is called.** The wallet button (RainbowKit, injected wallets, Arbitrum Sepolia) is lazy-loaded on click and makes no calls.

Next.js 15 (App Router), TypeScript strict, Tailwind 4, shadcn-style components, wagmi 2 + viem + RainbowKit + TanStack Query, dependency-free SVG charts.

## Data and labels

All numbers come from `research/` through `research/export_web_data.py`, which writes `src/data/*.json`. Every block carries its source files; pages show them under each block (`Source:` line) and tag numbers with `data-src`. Simulated elements carry a "Simulation" / "Research simulation" badge.

```bash
cd research && .venv/bin/python export_web_data.py   # refresh src/data from research/results
```

## Build from a fresh clone

`web/` in this repository is the only source of the app; there is no other copy. Requirements: Node >= 20.19 (22 recommended), Git, and Google Chrome only for the e2e tests. The package manager is pinned in the root `package.json` (`pnpm@12.8.1`) and invoked through `npx` so no global install is needed.

```bash
git clone <repository-url> sundown && cd sundown        # submodules are NOT needed for web/
npx -y pnpm@12.8.1 install --frozen-lockfile            # run at the repository ROOT (workspace lockfile lives there)
cd web
npx -y pnpm@12.8.1 typecheck
npx -y pnpm@12.8.1 lint
npx -y pnpm@12.8.1 build
npx -y pnpm@12.8.1 test:e2e                             # starts the built app on :3100 and runs Playwright with the installed Chrome
npx next start -p 3100                                  # serve the production build manually
```

Develop: `npx -y pnpm@12.8.1 dev` (http://localhost:3000). Screenshots (1280 and 390 px) are written to `docs/figures/web/` with `SHOTS=1 npx -y pnpm@12.8.1 exec playwright test tests/screenshots.spec.ts`. Refresh the data: `cd ../research && .venv/bin/python export_web_data.py`.

Vercel: root directory `web`, settings in `web/vercel.json`, manual steps in the root `DEPLOY.md`. No environment variables are needed (`web/.env.example` states the policy).

Notes: `next.config.ts` stubs the Base Account and MetaMask SDKs (optional deps are not installed; only injected wallets are used). `pnpm-workspace.yaml` declares four optional native build scripts as not allowed.

## Validation record

**Fresh-clone build (re-verified in M2.3 after merging `main`), from the repository, not a mirror.** `git clone` of the repository at commit `73ae9a3`, then the exact commands in "Build from a fresh clone": `install --frozen-lockfile` (715 packages, 58 s), `typecheck`, `lint`, `build` pass; the build prints no warnings; route sizes: `/` 108 kB, `/risk` 105 kB, `/replay` 115 kB first-load JS. `test:e2e`: 13 of 13 Playwright tests pass from that clone (smoke per page, no console errors, sources tagged, no horizontal overflow at 360 px, axe wcag2a/2aa/21aa with zero serious or critical violations in light and dark, theme toggle, navigation, replay filter, wallet stack loads only on request). After the build the clone's only untracked file was Next's generated `next-env.d.ts`, now ignored by `web/.gitignore`.

**Lighthouse on `/` (mobile profile, production build, local Chrome, M7a):** accessibility 100, best-practices 100, SEO 100. Performance 73-85 on this machine (best 85; TBT 490-1,400 ms, LCP about 2.5 s, CLS 0); a trivial static page scored 100 with the same tooling, so the tool is valid. The cost is React/Next runtime evaluation plus a heavy first layout under 4x CPU throttling, and later runs were distorted by unrelated CPU load. The performance target was dropped; the deployed-URL measurement is {{PENDING:lighthouse_deployed}}.

**Lazy-loading pass (M7b).** The charts are server-rendered SVG with no client JavaScript, and `/` contains no chart; lazy-loading them would add a client bundle rather than remove one, so no change was made. Link prefetch is off on the navigation. A `content-visibility` experiment made `/` slower and was reverted.
