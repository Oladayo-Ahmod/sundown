# web/

Research UI for Sundown: `/` (problem, headline claims with CIs, claims we do not make), `/risk` (gap distributions, out-of-sample backtest, equal-risk frontier, calibrated parameters, measured rates, limitations) and `/replay` (control versus Sundown on real historical gaps). `/deployment` (addresses, roles, a recorded live run with transaction links), `/markets` (live read of the six markets, the calendar window and the simulated feeds) and `/preflight` (live on-chain wiring checks plus recorded offline results) show the Arbitrum Sepolia deployment: production Sundown contracts, **simulated tokens and simulated price feeds**, read-only (a public viem client; no wallet, no signature, no transaction). `/`, `/risk` and `/replay` are research simulation. The wallet button (RainbowKit, injected wallets) is lazy-loaded on click and is not used for reads.

Chain data: `scripts/export-abis.mjs` writes typed ABIs to `src/abi/` from forge output (`cd contracts && forge build` first; `--check` fails if stale); `scripts/export-chain-data.mjs` copies `deployments/421614.json` and parses the evidence tables of `docs/SEPOLIA_DEMO.md` into `src/data/`; `pnpm check-chain` runs both checks. The RPC defaults to the public Arbitrum Sepolia endpoint; set `NEXT_PUBLIC_ARBITRUM_SEPOLIA_RPC_URL` to override (a public URL only, never a keyed one).

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

**Fresh-clone build (re-verified in M2.4 Part 2 after merging `main`), from the repository, not a mirror.** The clone was updated to commit `f80b047` and the exact commands in "Build from a fresh clone" were run: `install --frozen-lockfile`, `typecheck`, `lint` and `build` exit 0, and the build prints no warnings; `test:e2e`: 27 of 27 Playwright tests pass (the earlier 13 plus the three new pages' render, 360 px overflow and axe checks, a live-read test of `/markets` (6 market cards, 4 simulated feeds), a live preflight test (all checks pass against the deployment), a deployment-page test (27 contracts, transaction links), a test that no JSON-RPC method other than eth_call, eth_getCode, eth_getBlockByNumber, eth_chainId or eth_blockNumber is sent, and a test that the home page makes no RPC request). The two live tests read the public Arbitrum Sepolia RPC and skip themselves if it is unreachable. `node scripts/export-chain-data.mjs --check` and `node scripts/export-abis.mjs --check` (run in the working tree, which has `contracts/out`) report no drift. The Lighthouse performance target remains dropped; the deployed-URL measurement is a pending token.

**Lighthouse on `/` (mobile profile, production build, local Chrome, M7a):** accessibility 100, best-practices 100, SEO 100. Performance 73-85 on this machine (best 85; TBT 490-1,400 ms, LCP about 2.5 s, CLS 0); a trivial static page scored 100 with the same tooling, so the tool is valid. The cost is React/Next runtime evaluation plus a heavy first layout under 4x CPU throttling, and later runs were distorted by unrelated CPU load. The performance target was dropped; the deployed-URL measurement is {{PENDING:lighthouse_deployed}}.

**Lazy-loading pass (M7b).** The charts are server-rendered SVG with no client JavaScript, and `/` contains no chart; lazy-loading them would add a client bundle rather than remove one, so no change was made. Link prefetch is off on the navigation. A `content-visibility` experiment made `/` slower and was reverted.
