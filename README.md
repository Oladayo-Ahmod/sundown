# Sundown

Session-aware credit-risk layer and isolated lending market for tokenized-stock collateral on Arbitrum and Robinhood Chain. Built for the Arbitrum Open House Singapore buildathon.

| | |
|---|---|
| Live site | {{PENDING:vercel_url}} |
| Repository | {{PENDING:repo_url}} |
| Demo video | {{PENDING:video_url}} |
| Team | {{PENDING:team_members}} |
| License | {{PENDING:license}} |

> **Read this first.** Sundown is a research project with an honest headline: at the loan-to-value limits actually used today, weekend and holiday gaps cost lenders almost nothing, so we do **not** claim to fix them. The measured contribution is a calibrated risk model, a clean isolated lending core whose risk guard is swappable, and a quantified case for a higher-LLTV "boosted tier" on one asset (AAPL at 90%). Everything simulated is labelled as simulation; the list of claims we will not make is in [Evidence](#what-the-evidence-shows).

## The problem

Tokenized stocks now trade on-chain, but their lending markets price weekend risk with a single static number.

- **A large, live universe.** The Robinhood registry lists 194 stock tokens on Robinhood Chain mainnet (chain 4663), all 18 decimals; 32 of them have a Chainlink push feed (24/5, 0.5% deviation, 24 h heartbeat, 8 decimals). Source: `docs/DISCOVERY.md` sections b and c (verified-api / verified-onchain).
- **The oracle goes blind on a calendar.** The feeds publish Sunday 20:00 ET to Friday 20:00 ET and hold the last value across weekends and NYSE holidays (documented by Chainlink). We measured it: across 4,716 updates on six feeds, **none** lies inside a predicted blind window; 14 windows had both a last-before and a first-after update, **12 Weekend and 2 Long (holiday)**, 0 Short. Source: `docs/CALENDAR_NOTES.md` findings, `contracts/test/fixtures/observed_feed_updates.json`.
- **Static limits price it once.** Morpho Blue stock-collateral markets on Robinhood Chain use fixed LLTVs of 38.5%, 62.5%, 77% and 86% (verified-api, `docs/DISCOVERY.md` section f). Aave V4's Equities Hub on Base reports 65-79% collateral factors and a 5.5% maximum liquidation bonus (**secondary source**, unverified against primary documents).
- **The gaps are real.** Over 2010-2026 the 99th-percentile weekend gap down (previous regular close to next regular open) was 259 bps for SPY, 359 for AAPL and 555 for TSLA (`research/results/class_stats.csv`; a daily proxy, see limitations).
- **Demand exists.** On-chain reads at block 78,552,299 (`research/results/morpho_rates_snapshot.json`): the AAPL/USDG market is 99.99% utilised at a 7.83% borrow APR and NVDA/USDG 98.5% at 10.92%. The SPY/USDG market is idle (42% utilised, 0.06% APR). Large USDG markets borrow at about 4.1%.
- **The collateral is issuer-controlled.** Pause, per-address blocklist, `adminBurn` and a beacon upgrade for all 194 tokens sit behind roles held by externally owned accounts, verified from Sourcify source and role-grant logs (`docs/DISCOVERY.md` section b).

## What we built

Labels follow the repository rule: `contracts/src` is production code, `contracts/test/mocks` and fixtures are test fixtures, `sim/` is simulation, `research/` is offline analysis.

| Component | What it is | Status |
|---|---|---|
| `research/` | Calendar windows (D1), 2010-2026 gap data for 12 equities, gap-VaR estimators (float and integer reference), out-of-sample backtests, credit simulation, liquidation-design and two-tier studies, claims register | Complete; `make test` runs {{PENDING:research_pytest_count}} |
| `contracts/src/lib/UsMarketCalendar.sol`, `MarketCalendar.sol` | Pure O(1) blind-window calendar (D1: trading day opens 20:00 ET the day before, closes 20:00 ET; classes Short / Weekend / Long) plus an ad-hoc closure wrapper | Implemented; differential-tested against an independent Python calendar |
| `contracts/src/oracle/` | `ChainlinkEquityOracle` (calendar-aware freshness: scheduled blindness vs unexpected staleness) and `WindowCache` | Implemented; "integrated" only after the fork test: {{PENDING:oracle_fork_test_result}} |
| `contracts/src/SundownMarket.sol`, `SundownMarketFactory.sol` | ERC-4626 supply vault plus isolated single-collateral lending, kinked per-second rate, partial liquidation, per-market collateral cap, issuer-failure halt policy; ERC-1167 clone factory | Implemented; {{PENDING:contracts_forge_test_count}} |
| `contracts/src/guards/FlatGuard.sol` | Control guard: static LTV, flat bonus | Implemented |
| Session-aware guard (boosted tier) | Pre-window deleveraging guard specified by the research | **Not implemented** (listed in `docs/THREAT_MODEL.md` known gaps) |
| `sim/SimEquityFeed.sol` | AggregatorV3-shaped feed driven by replay data, named and documented as **simulation** | Implemented; never used for Robinhood mainnet |
| `web/` | Research UI: landing, risk evidence, replay (research simulation, no contract calls) | Built, tested; deployed: {{PENDING:vercel_url}} |
| Arbitrum Sepolia demonstration | Four markets at demonstration scale with the labelled simulated feed | {{PENDING:sepolia_deployment_status}}; addresses {{PENDING:sepolia_market_addresses}}; replay transactions {{PENDING:sepolia_replay_tx_links}} |

## What the evidence shows

All numbers: annualised bad debt in basis points of outstanding debt, replaying real 2018-2026 gaps through a **simulated** lending market; 95% bootstrap CIs clustered by window date. Source of every figure: `research/CLAIMS.md` and the files it names under `research/results/`.

1. **Conventional LLTVs lose almost nothing to weekend gaps.** At 86% (the highest limit in the wild) bad debt is 4.5 bps/yr, CI [0.7, 9.7]; at 77% it is 0.08 bps/yr. The worst single window cost 1.2% of debt, and 63% of the 86% loss is one episode (March 2020). The stress rule changes none of this below about 90%.
2. **At higher LLTV the session-aware rule works, with enforcement.** At a counterfactual 93% base LLTV, pre-window deleveraging cuts bad debt 41% (24.0 to 14.0 bps/yr; reduction 9.9, CI [1.6, 23.8]); at 95% it cuts 53%. At equal bad debt it buys +2.6 pp of LTV at 93% (CI [0.9, 4.1]). A cap on new borrows only has exactly zero effect. These LLTVs exist in no market today.
3. **Liquidation design matters more than the guard, and it points to one credible boosted-tier case: AAPL at 90%.** Cutting the flat bonus from 5.5% to 2% lowers bad debt by 8.8 bps/yr at 86% (CI [2.0, 17.7]) and 76 bps/yr at 93% (CI [49, 106]), if liquidators still act at 2%. A Dutch ramp or depth-capped liquidation does not help lenders. For AAPL at 90% the added lender loss is covered at a break-even borrow APR of 1.4% (CI [0.1, 3.3]) for uniform borrowers and 3.7% (CI [0.4, 8.5]) for borrowers clustered near the limit, against a **measured** 7.83% on the AAPL/USDG market. SPY is the secondary case, but its market is idle. TSLA and NVDA are not recommended for a boosted tier: they have the highest break-even APRs and the most forced deleveraging events.

### Claims we will not make

- That Sundown is safer than Aave or Morpho, or that it protects conventional LLTV markets.
- That our 99% gap-VaR is calibrated: out of sample it realises 1.87% exceedances on weekends (target 1%, CI [0.96, 3.09]); March 2020 breaks it; the Short class fails.
- That weekends are riskier than weeknights, or any exact size of the oracle-blind exposure: the daily proxy is a conservative superset.
- That the LTV gain generalises beyond 2018-2026, a sample whose tail is mostly one episode.
- That forced deleveraging is acceptable to borrowers (cure rate and fee are assumptions), that a premium-funded gap reserve works, or that exit liquidity is guaranteed.
- Anything about TSLA or NVDA beyond "not recommended for a boosted tier".
- That any on-chain integration is validated by the research, or anything about issuer risks, which no parameter here mitigates.

## Architecture

```text
  Chainlink 24/5 equity push feed (Robinhood Chain; SimEquityFeed on Sepolia)
              |
              v
  ChainlinkEquityOracle --- WindowCache --- MarketCalendar / UsMarketCalendar (D1 blind windows)
     status: Fresh | ScheduledBlind | Reopening | Stale | Invalid | CorporateAction | SequencerDown
              |
              v
  SundownMarket (ERC-4626 vault + isolated lending, one collateral, USDG loan, per-market cap)
      ^   reads IRiskGuard (FlatGuard today; session-aware guard not implemented)
      |   permissionless reportIssuerFailure() probes of the collateral token and USDG (pause and block state)
      v
  Halted policy: new borrows and withdrawals blocked, accrual frozen, repay stays open, bounded (30-day) freeze
  SundownMarketFactory: ERC-1167 clones with immutable parameters (no upgrade path)
```

The market contains no session logic; everything session-related is behind `IRiskGuard`, so a control market (flat) and a treatment market differ only by the guard and a replay can say what the guard is worth. Design, decisions and invariants: `docs/MARKET_DESIGN.md`, `docs/DESIGN.md`; threats and known gaps: `docs/THREAT_MODEL.md`; calendar rules and evidence: `docs/CALENDAR_NOTES.md`; feasibility facts with evidence labels: `docs/DISCOVERY.md`.

## Limitations

- **Daily proxy.** Risk is measured from the previous regular close to the next regular open, a conservative superset of the oracle-blind exposure. On a two-year hourly subset the extended-hours bracket carried 58% of the proxy's second moment. It is never exact.
- **One data vendor.** Equity history comes from Yahoo Finance (split-adjusted, not dividend-adjusted); there is no second source for cross-checking (`research/DATA_PROVENANCE.md`).
- **Limited calendar evidence.** The D1 rule is confirmed on 12 Weekend and 2 Long windows only; 0 Short windows, **no EST (winter) observations and no early-close observations** exist yet. The early-close rule is an unverified one-line configuration.
- **Exit liquidity is thin and measured at one moment.** Depth was read directly from Uniswap v3 pools on Robinhood Chain; it supports about $0.9M of collateral across four markets under the proposed cap rule (`docs/DISCOVERY.md` section g). It excludes v4 pools and RFQ routing, and weekend depth is unmeasured. The liquidation study additionally used a secondary DexScreener snapshot as a model input; sizing numbers should come from section g.
- **Issuer controls are not mitigable.** Pause, blocklist, `adminBurn` and a beacon upgrade for all tokens are held by EOAs. The market detects pause and block and halts; it cannot prevent a burn, which is a direct loss to lenders bounded only by the per-market cap.
- **Loan token assumption.** USDG is treated as exactly 1 USD; there is no loan-token oracle.
- **No sequencer-uptime feed** exists for Robinhood Chain; sequencer downtime is modelled as unscheduled blindness.
- **Simulation scope.** Borrower behaviour is a 20-point utilisation grid; no interest accrual, earnings calendar or issuer actions in the credit simulation; Sepolia demonstrations use a simulated feed and prove integration shape, not oracle security.
- **Performance.** Lighthouse performance on `/` was measured locally at 73-85 (accessibility, best practices and SEO 100); the deployed-URL measurement is {{PENDING:lighthouse_deployed}}.

## Reproduce

Everything below is deterministic (fixed seeds, pinned dependencies) unless marked as a network step.

```bash
# Research (Python 3.11, uv)
cd research
make venv && make test
make backtest      # statistics, estimators, credit sim; writes results/, figures, deployments/risk_params.json
make m21 && make m22
# network steps (refresh data / re-read the chain): make data, make intraday, make pools, python morpho_rates.py

# Web app (Node 22, Chrome for the e2e tests); run from the repository root
npx -y pnpm@12.8.1 install --frozen-lockfile
cd web
npx -y pnpm@12.8.1 typecheck && npx -y pnpm@12.8.1 lint && npx -y pnpm@12.8.1 build
npx -y pnpm@12.8.1 test:e2e

# Contracts (Foundry)
git submodule update --init --recursive
cd contracts && forge build && forge test
```

`web/README.md` has the exact web build record; `DEPLOY.md` lists the manual deployment steps; `scripts/check_pending.sh` lists unresolved placeholders.

## Repository map

`contracts/` Solidity (Foundry, solc 0.8.28, cancun) | `research/` analysis, results, claims | `sim/` simulation-only contracts | `web/` Next.js research UI | `deployments/` parameter and address files | `docs/` design, discovery, threat model, figures | `scripts/` repository checks.

## Pre-existing work and third-party material

- **Provenance.** The repository history begins on 2026-10-02 (first commit `c467ccd`, the operating charter); all code, research and documentation here were written in this repository during the buildathon window. Attestation by the team that no earlier code was imported: {{PENDING:team_confirms_no_prior_code}}.
- **Libraries (exact pins in the named files).** Contracts: OpenZeppelin Contracts and Contracts-Upgradeable v5.7.0 (git submodules; Upgradeable only for clone-safe ERC-4626 and ERC-20 bases, not for upgradeability), forge-std v1.17.0 (`contracts/foundry.lock`). Research: exchange_calendars, pandas, numpy, scipy, yfinance, matplotlib, pytest, ruff (`research/requirements.txt`). Web: Next.js 15.5, React 19, Tailwind CSS 4, wagmi 2, viem, RainbowKit, TanStack Query, next-themes, Radix Slot, class-variance-authority, clsx, tailwind-merge, Playwright, axe-core (`web/package.json`, `pnpm-lock.yaml`). The UI components follow shadcn/ui patterns and are written in this repository.
- **Contract code attribution.** {{PENDING:contracts_third_party_attribution}}
- **External data and services.** Yahoo Finance via yfinance (equity history), Chainlink feeds and Morpho Blue and Uniswap v3 pools (on-chain reads), the Robinhood asset registry and the Morpho GraphQL API (enumeration), Sourcify (verified token source), the NYSE holiday page (calendar cross-check), DexScreener (secondary pool discovery in one study only).
- **Development tooling disclosure.** {{PENDING:development_tooling_disclosure}}
