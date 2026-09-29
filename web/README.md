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

## Validation record (M7a)

- `pnpm typecheck`, `pnpm lint`, `pnpm build`: pass; no build warnings. First-load JS: `/` 108 kB, `/risk` 105 kB, `/replay` 115 kB.
- Playwright: 13 tests pass (smoke per page, no console errors, sources tagged, no horizontal overflow at 360 px, axe wcag2a/2aa/21aa with zero serious or critical violations in light and dark, theme toggle, navigation, replay filter, wallet stack loads only on request).
- Lighthouse on `/` (mobile profile, production build, local Chrome): accessibility 100, best-practices 100, SEO 100. **Performance is below the 90 target on this machine**: best run 85, typical 73-81 (TBT 490-1,400 ms, LCP about 2.5 s, CLS 0); a trivial static page measured with the same tooling scores 100, so the tool is valid. The cost is React/Next runtime evaluation plus a heavy first layout under 4x CPU throttling; the machine was also CPU-saturated by unrelated processes during later runs. Not claimed as met; re-measure on a quiet machine or CI.
