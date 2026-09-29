# web/

Research UI for Sundown: `/` (problem, headline claims with CIs, claims we do not make), `/risk` (gap distributions, out-of-sample backtest, equal-risk frontier, calibrated parameters, measured rates, limitations) and `/replay` (control versus Sundown on real historical gaps). **Research simulation only: no contract is called.** The wallet button (RainbowKit, injected wallets, Arbitrum Sepolia) is lazy-loaded on click and makes no calls.

Next.js 15 (App Router), TypeScript strict, Tailwind 4, shadcn-style components, wagmi 2 + viem + RainbowKit + TanStack Query, dependency-free SVG charts.

## Data and labels

All numbers come from `research/` through `research/export_web_data.py`, which writes `src/data/*.json`. Every block carries its source files; pages show them under each block (`Source:` line) and tag numbers with `data-src`. Simulated elements carry a "Simulation" / "Research simulation" badge.

```bash
cd research && .venv/bin/python export_web_data.py   # refresh src/data from research/results
```

## Develop, build, test

```bash
pnpm install
pnpm dev                 # http://localhost:3000
pnpm typecheck && pnpm lint && pnpm build
pnpm test:e2e            # Playwright (installed Chrome): smoke, 360px overflow, axe (light+dark), theme, nav, filter, lazy wallet
SHOTS=1 pnpm exec playwright test tests/screenshots.spec.ts   # writes docs/figures/web/*.png (1280 and 390 px)
```

Notes: `next.config.ts` stubs the Base Account and MetaMask SDKs (optional deps are not installed; only injected wallets are used). `pnpm-workspace.yaml` declares four optional native build scripts as not allowed.

## Validation record (M7a)

- `pnpm typecheck`, `pnpm lint`, `pnpm build`: pass; no build warnings. First-load JS: `/` 108 kB, `/risk` 105 kB, `/replay` 115 kB.
- Playwright: 13 tests pass (smoke per page, no console errors, sources tagged, no horizontal overflow at 360 px, axe wcag2a/2aa/21aa with zero serious or critical violations in light and dark, theme toggle, navigation, replay filter, wallet stack loads only on request).
- Lighthouse on `/` (mobile profile, production build, local Chrome): accessibility 100, best-practices 100, SEO 100. **Performance is below the 90 target on this machine**: best run 85, typical 73-81 (TBT 490-1,400 ms, LCP about 2.5 s, CLS 0); a trivial static page measured with the same tooling scores 100, so the tool is valid. The cost is React/Next runtime evaluation plus a heavy first layout under 4x CPU throttling; the machine was also CPU-saturated by unrelated processes during later runs. Not claimed as met; re-measure on a quiet machine or CI.
