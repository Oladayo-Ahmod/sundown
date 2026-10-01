# Sundown

Session-aware credit-risk layer and isolated lending market for tokenized-stock collateral on Arbitrum and Robinhood Chain. Built for the Arbitrum Open House Singapore buildathon.

| | |
|---|---|
| Live site | {{PENDING:vercel_url}} |
| Repository | {{PENDING:repo_url}} |
| Demo video | {{PENDING:video_url}} |
| Team | {{PENDING:team_members}} |
| License | MIT |

> **Read this first.** Sundown is a research project with an honest headline: at the loan-to-value limits actually used today, weekend and holiday gaps cost lenders almost nothing, so we do **not** claim to fix them. The shipped session-aware guard is a *capacity policy* (boosted weekday capacity, tighter weekend capacity) for one boosted tier, AAPL at 93 %; it is not loss prevention, its measured economics are modest, and its benefit does not survive an out-of-sample calibration. Everything simulated is labelled as simulation; the claims we will not make are listed under [Evidence](#what-the-evidence-shows).

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
| `research/` | Calendar windows (D1), 2010-2026 gap data for 12 equities, gap-VaR estimators (float and integer reference), out-of-sample backtests, credit simulation, liquidation-design and two-tier studies, evidence for the shipped static rule, claims register | Complete; `make test` runs {{PENDING:research_pytest_count}} |
| `contracts/src/lib/UsMarketCalendar.sol`, `MarketCalendar.sol` | Pure O(1) blind-window calendar (D1: trading day opens 20:00 ET the day before, closes 20:00 ET; classes Short / Weekend / Long) plus an ad-hoc closure wrapper | Implemented; differential-tested against an independent Python calendar |
| `contracts/src/oracle/` | `ChainlinkEquityOracle` (calendar-aware freshness: scheduled blindness vs unexpected staleness) and `WindowCache` | Implemented; "integrated" only after the fork test: {{PENDING:oracle_fork_test_result}} |
| `contracts/src/SundownMarket.sol`, `SundownMarketFactory.sol` | ERC-4626 supply vault plus isolated single-collateral lending, kinked per-second rate, partial liquidation with a non-worsening bonus cap, per-market collateral cap, issuer-failure halt policy; ERC-1167 clone factory | Implemented; {{PENDING:contracts_forge_test_count}} |
| `contracts/src/guards/FlatGuard.sol` | Control guard: static LTV, flat bonus | Implemented |
| `contracts/src/guards/SundownGuard.sol` | Session-aware guard: static through-the-cycle stress cap from 6 h before a blind window until it ends, 3 h cure window, then permissionless deleveraging to the cap at a fee; standard accounts never touched; timelocked parameters, tighten-only guardian (`docs/GUARD_DESIGN.md`) | Implemented; deployed boosted tier: **AAPL at 93 % only** (SPY at 90/93 % and AAPL at 90 % are not deployed as boosted, D26/D30) |
| `sim/SimEquityFeed.sol`, `sim/ReplayHarness.sol` | AggregatorV3-shaped feed driven by replay data, and the replay harness, named and documented as **simulation** | Implemented; never used for Robinhood mainnet |
| `web/` | Research UI: landing, risk evidence, replay (research simulation, no contract calls) | Built, tested; deployed: {{PENDING:vercel_url}} |
| Arbitrum Sepolia demonstration | Markets at demonstration scale with the labelled simulated feed (SPY, NVDA, TSLA, AAPL standard; AAPL boosted 93 % and AAPL control 93 %) | {{PENDING:sepolia_deployment_status}}; addresses {{PENDING:sepolia_market_addresses}}; replay transactions {{PENDING:sepolia_replay_tx_links}} |

## What the evidence shows

Bad debt below is in basis points of outstanding debt per year from replaying real gaps through a **simulated** lending market, 95% bootstrap CIs clustered by window date; the replay in claim 2 runs in forge's in-process EVM, **not on a public chain**. Sources: `research/CLAIMS.md`, `research/PITCH_EVIDENCE.md`, `docs/REPLAY_RESULTS.md`.

1. **At today's limits, gaps cost lenders almost nothing.** At 86% (the highest in the wild) bad debt is 4.5 bps/yr, CI [0.7, 9.7]; at 77% it is 0.08 bps/yr; 63% of the 86% loss is March 2020. (Upper bounds: the convention used there overstates losses relative to the deployed market, see claim 2.)
2. **The shipped rule does what its design says on AAPL at 93%, and two implementations agree.** Session A's replay (20 seeded borrowers, the 10 worst real AAPL gaps, no borrower cures): control at 93% lost $3,824 over 4 events; session-aware $1,224 over 1 event (-68%); a standard 86% market $0 at 7.5% lower capacity; **the 2020-03-16 gap (13.9%) still produced a loss**. My independent Python simulation reproduces these to 0.01% ($3,823.47 and $1,224.26) once it uses the market's liquidation rule; my earlier convention overstated the control by 45% ($5,556), which is why both conventions are reported. Over all 914 AAPL windows 2010-2026 (in-sample for the cap) the rule cuts 93% bad debt from 19.6 to 4.8-6.3 bps/yr (reduction 14.7, CI [3.2, 30.3], for borrowers who never adjust; 13.2, CI [2.2, 27.5], for borrowers who trim before each window).
3. **Its economics are modest.** SPY: the cap never binds, so a boosted SPY tier is a flat market. AAPL: the rule is not distinguishable from a flat market at the 89.35% weekend-cap level (+2.7 bps/yr, CI [0.0, 8.2], at 93%), offers 3.65 pp more weekday capacity (0.65 pp at 90%), deleverages a never-adjusting near-max borrower on 96% of windows (52 a year, fee 4.3% of debt a year on average and 11.8% for borrowers clustered near the limit) against a measured 7.83% AAPL borrow APR, and does nothing when the cap is calibrated before March 2020.

### Claims we will not make

- That Sundown is safer than Aave or Morpho, or that it protects conventional LLTV markets or prevents losses.
- Any enforcement, protection or benefit for SPY at either tier or for AAPL at 90%; anything for TSLA or NVDA beyond "not recommended for a boosted tier".
- That the shipped rule is safer than a flat market at the weekend-cap level, or that the earlier time-varying estimator's results (+2.6 pp LTV, 41% bad-debt reduction) describe it.
- That naive borrowers are good customers, that attentive borrowers have no cost, that a keeper will run, or that the boosted tier is profitable for lenders or borrowers.
- That our 99% gap-VaR is calibrated: out of sample it realises 1.87% exceedances on weekends (target 1%, CI [0.96, 3.09]); March 2020 breaks it.
- That the replay ran on a public chain, that exit liquidity is guaranteed, or that any on-chain integration, issuer-risk mitigation or oracle security is validated by the research.

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
      ^   reads IRiskGuard: FlatGuard (control) or SundownGuard (static stress cap, cure window, deleverage)
      |   permissionless reportIssuerFailure() probes of the collateral token and USDG (pause and block state)
      v
  Halted policy: new borrows and withdrawals blocked, accrual frozen, repay stays open, bounded (30-day) freeze
  SundownMarketFactory: ERC-1167 clones with immutable parameters (no upgrade path)
```

The market contains no session logic; everything session-related is behind `IRiskGuard`, so a control market (flat) and a treatment market differ only by the guard and a replay can say what the guard is worth. Design, decisions and invariants: `docs/MARKET_DESIGN.md`, `docs/GUARD_DESIGN.md`, `docs/DESIGN.md`; threats and known gaps: `docs/THREAT_MODEL.md`; calendar rules and evidence: `docs/CALENDAR_NOTES.md`; replay: `docs/REPLAY_RESULTS.md`; feasibility facts with evidence labels: `docs/DISCOVERY.md`.

## Limitations

- **Daily proxy.** Risk is measured from the previous regular close to the next regular open, a conservative superset of the oracle-blind exposure. On a two-year hourly subset the extended-hours bracket carried 58% of the proxy's second moment. It is never exact.
- **The shipped cap is calibrated in-sample.** The static gapVaR is a full-sample number that contains March 2020; a cap calibrated on 2010-2017 would have done nothing on 2018+ windows. Even in-sample, the 2020-03-16 gap produces a loss.
- **Two liquidation conventions.** Most research bad-debt levels (M2.1-M2.3 default files) charge the full bonus on any liquidation and therefore overstate losses relative to the deployed market's non-worsening bonus cap; the market-rule variants (`*_marketrule.csv`) match Session A's forge replay to 0.01%. Absolute levels are not forecasts.
- **The replay is a forge in-process simulation**: a fixture window cache, 20 seeded borrowers, one gap at reopen, no exit slippage; not a public-chain run.
- **One data vendor.** Equity history comes from Yahoo Finance (split-adjusted, not dividend-adjusted); there is no second source for cross-checking (`research/DATA_PROVENANCE.md`).
- **Limited calendar evidence.** The D1 rule is confirmed on 12 Weekend and 2 Long windows only; 0 Short windows, **no EST (winter) observations and no early-close observations** exist yet. The early-close rule is an unverified one-line configuration.
- **Exit liquidity is thin and measured at one moment.** Depth was read directly from Uniswap v3 pools on Robinhood Chain; it supports about $0.9M of collateral across four markets under the proposed cap rule (`docs/DISCOVERY.md` section g). It excludes v4 pools and RFQ routing, and weekend depth is unmeasured. Keeper economics at the deployed scale are viable under the 2% default fee, but whether any keeper runs is not established.
- **Issuer controls are not mitigable.** Pause, blocklist, `adminBurn` and a beacon upgrade for all tokens are held by EOAs. The market detects pause and block and halts; it cannot prevent a burn, which is a direct loss to lenders bounded only by the per-market cap.
- **Loan token assumption.** USDG is treated as exactly 1 USD; there is no loan-token oracle.
- **No sequencer-uptime feed** exists for Robinhood Chain; sequencer downtime is modelled as unscheduled blindness.
- **Simulation scope.** Borrower behaviour is stylised (a utilisation grid, or a seeded population in the replay); no interest accrual, earnings calendar or issuer actions in the credit simulation; Sepolia demonstrations use a simulated feed and prove integration shape, not oracle security.
- **Performance.** Lighthouse performance on `/` was measured locally at 73-85 (accessibility, best practices and SEO 100); the deployed-URL measurement is {{PENDING:lighthouse_deployed}}.

## Reproduce

Everything below is deterministic (fixed seeds, pinned dependencies) unless marked as a network step.

```bash
# Research (Python 3.11, uv)
cd research
make venv && make test
make backtest      # statistics, estimators, credit sim; writes results/, figures, deployments/risk_params.json
make m21 && make m22 && make m23     # m23: shipped static rule, market-rule variants, forge replay cross-check
python static_replay_crosscheck.py   # my Python vs Session A's forge replay, same scenario
# network steps (refresh data / re-read the chain): make data, make intraday, make pools, make exit-liquidity, python morpho_rates.py

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

`contracts/` Solidity (Foundry, solc 0.8.28, cancun) | `research/` analysis, results, claims | `sim/` simulation-only contracts and replay harness | `web/` Next.js research UI | `deployments/` parameter and address files | `docs/` design, discovery, threat model, replay results, figures | `scripts/` repository checks.

## Pre-existing work and third-party material

- **Attribution.** Original contracts (MIT). Built on OpenZeppelin Contracts v5.7.0 (MIT). Design inspired by Morpho Blue (virtual shares, isolated markets) and Aave/Compound (kinked rates, liquidation parameters); no code copied.
- **Provenance.** The repository history begins on 2026-10-02 (first commit `c467ccd`, the operating charter); all code, research and documentation here were written in this repository during the buildathon window. Attestation by the team that no earlier code was imported: {{PENDING:team_confirms_no_prior_code}}.
- **Libraries (exact pins in the named files).** Contracts: OpenZeppelin Contracts and Contracts-Upgradeable v5.7.0 (git submodules; Upgradeable only for clone-safe ERC-4626 and ERC-20 bases, not for upgradeability), forge-std v1.17.0 (`contracts/foundry.lock`). Research: exchange_calendars (Apache-2.0), pandas, numpy, scipy, yfinance, matplotlib, pytest, ruff (`research/requirements.txt`). Web: Next.js 15.5, React 19, Tailwind CSS 4, wagmi 2, viem, RainbowKit, TanStack Query, next-themes, Radix Slot, class-variance-authority, clsx, tailwind-merge, Playwright, axe-core (`web/package.json`, `pnpm-lock.yaml`). The UI components follow shadcn/ui patterns and are written in this repository.
- **Credits.** yfinance (Yahoo Finance data, subject to Yahoo's own terms), exchange_calendars (Apache-2.0), and Chainlink (the AggregatorV3 feed interface and the Robinhood Chain equity feeds read by the oracle adapter).
- **External data and services.** Chainlink feeds, Morpho Blue and Uniswap v3 pools (on-chain reads), the Robinhood asset registry and the Morpho GraphQL API (enumeration), Sourcify (verified token source), the NYSE holiday page (calendar cross-check), DexScreener (secondary pool discovery in one study only).
- **Development tooling disclosure.** {{PENDING:development_tooling_disclosure}}
