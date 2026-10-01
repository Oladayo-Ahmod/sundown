# Sundown: submission

Written for: hackathon judges (technical reviewers). Every factual statement below comes from the repository: `research/CLAIMS.md`, `research/results/`, `docs/DISCOVERY.md`, `docs/CALENDAR_NOTES.md`, `docs/GUARD_DESIGN.md`, `docs/REPLAY_RESULTS.md`, `docs/THREAT_MODEL.md`. Items that depend on a deployment or on the team are placeholders; `scripts/check_pending.sh` lists them and must print "no pending tokens" before this is submitted.

## At a glance

| Field | Value |
|---|---|
| Project | Sundown |
| One line | A session-aware credit-risk layer and isolated lending market for tokenized-stock collateral, with a measured (not assumed) account of when it helps. |
| Event / track | Arbitrum Open House Singapore buildathon / {{PENDING:submission_track}} |
| Live site | {{PENDING:vercel_url}} |
| Repository | {{PENDING:repo_url}} |
| Demo video | {{PENDING:video_url}} |
| Team | {{PENDING:team_members}} |
| License | MIT |
| Chains | Robinhood Chain mainnet (read-only evidence), Arbitrum Sepolia (demonstration, simulated feed): {{PENDING:sepolia_deployment_status}} |

## Short description

Tokenized stocks trade almost around the clock, but the Chainlink feeds that lending markets rely on go blind on a calendar (Sunday 20:00 ET to Friday 20:00 ET, plus NYSE holidays), and today's markets price that with one static LLTV. Sundown measures what that risk costs, builds a calendar-aware oracle adapter and a small auditable lending core with a swappable risk guard, and ships a static session-aware guard for one boosted tier (AAPL at 93 %: boosted weekday capacity, tighter weekend capacity). The honest finding: at today's limits gaps cost lenders almost nothing, and the shipped guard is a modest capacity policy, not loss prevention.

## The problem (with sources)

- 194 stock tokens on Robinhood Chain mainnet, 18 decimals; 32 have Chainlink push feeds (24/5, 0.5% deviation, 24 h heartbeat). `docs/DISCOVERY.md` b, c.
- Measured on-chain: of 4,716 feed updates on six feeds, none inside a predicted blind window; 14 windows analysed (12 Weekend, 2 Long). `docs/CALENDAR_NOTES.md`.
- Morpho stock-collateral markets use static LLTVs of 38.5%, 62.5%, 77%, 86%. `docs/DISCOVERY.md` f. Aave V4 Equities Hub parameters are secondary-source only.
- The collateral is issuer-controlled: pause, blocklist, `adminBurn` and a beacon upgrade for all tokens, all behind EOA-held roles. `docs/DISCOVERY.md` b.

## What we built

| Area | Contents | State |
|---|---|---|
| Research | D1 blind-window calendar, 12-asset 2010-2026 gap data, gap-VaR estimators (float and integer reference), out-of-sample backtests with Kupiec and Christoffersen tests, credit simulation with clustered-bootstrap CIs, liquidation-design and two-tier studies, evidence for the shipped static rule, claims register | Complete |
| Contracts | `UsMarketCalendar` and `MarketCalendar`, `ChainlinkEquityOracle` and `WindowCache`, `SundownMarket` (ERC-4626 vault + isolated lending + liquidation with a non-worsening bonus cap + issuer-failure halt policy), `SundownMarketFactory`, `FlatGuard`, `SundownGuard` (static stress cap, cure window, permissionless deleverage; timelocked parameters; tighten-only guardian) | Implemented: {{PENDING:contracts_forge_test_count}}; oracle fork test {{PENDING:oracle_fork_test_result}} |
| Boosted tier | AAPL at 93 % only. SPY at 90/93 % and AAPL at 90 % are not deployed as boosted (the cap does not bind, or binds by 65 bps on Weekend windows only) | Per D26/D30 |
| Simulation | `SimEquityFeed` (labelled), `ReplayHarness` (forge in-process EVM replay, not a public chain) | Implemented |
| Web | Landing, risk evidence, replay; research simulation only, no contract calls | Built; Playwright and axe checks pass; deployed {{PENDING:vercel_url}} |
| Demonstration | Arbitrum Sepolia markets at demonstration scale, simulated feed | {{PENDING:sepolia_market_addresses}}; replay transactions {{PENDING:sepolia_replay_tx_links}} |

## What is real and what is simulated

| Real (reproducible) | Simulated or modelled (labelled as such) |
|---|---|
| Equity price history (Yahoo Finance), used as a daily proxy | Every lending-market result in `research/results/credit_*`, `liq_*`, `two_tier.csv`, `static_rule_*`: a model of borrowers and liquidations replayed over real gaps |
| On-chain reads: feed update history, Morpho market state and borrow rates, Uniswap v3 depth, token source and role holders | The forge replay (`docs/REPLAY_RESULTS.md`): real gaps applied as one gap at reopen to seeded borrowers, in forge's in-process EVM with a fixture window cache |
| Calendar library, differential-tested against an independent implementation | The Arbitrum Sepolia demonstration price feed (`SimEquityFeed`) |
| Contract code and tests | Anything the research labels counterfactual (LLTV 90-95% markets do not exist today) |

## Evidence (95% CIs; bad debt in bps of outstanding debt per year)

1. **At today's limits, gaps cost lenders almost nothing** (so we do not claim to fix them): 2.5 bps/yr at 86%, CI [0.4, 5.6]; 0.00 at 77%; 47% of the 86% loss is March 2020 (deployed liquidation rule; the older full-bonus convention gave 4.5, an upper bound).
2. **The shipped rule does what its design says on AAPL at 93%, and two implementations agree.** Forge replay (20 seeded borrowers, the 10 worst real AAPL gaps): control $3,824 over 4 events, session-aware $1,224 over 1 event (-68%), standard 86% $0 at 7.5% lower capacity; the 2020-03-16 gap (13.9%) still produced a loss. My independent Python simulation reproduces it to 0.01% ($3,823.47 and $1,224.26) once it uses the market's liquidation rule (my earlier convention overstated the control by 45%: both are reported). Over 914 AAPL windows (in-sample for the cap) the rule cuts 93% bad debt from 19.6 to 4.8-6.3 bps/yr (reduction 14.7, CI [3.2, 30.3], naive borrowers; 13.2, CI [2.2, 27.5], borrowers who trim).
3. **Its economics are modest.** SPY: the cap never binds (a boosted SPY tier is a flat market). AAPL: not distinguishable from a flat market at the 89.35% weekend-cap level (+2.7 bps/yr, CI [0.0, 8.2], at 93%); 3.65 pp more weekday capacity at 93%; a never-adjusting near-max borrower is deleveraged 52 times a year (fee 4.3% of debt a year on average, 11.8% for borrowers clustered near the limit) against a measured 7.83% AAPL borrow APR (99.99% utilised); with a cap calibrated before March 2020 the rule does nothing.

Negative results we kept: the 99% gap-VaR is not calibrated out of sample (1.87% exceedances on weekends, CI [0.96, 3.09]); the Dutch ramp and depth-capped liquidation do not help lenders; a premium-funded gap reserve cannot self-start; the time-varying estimator's benefits (+2.6 pp LTV, 41% reduction at counterfactual 93%) are research results for an estimator that is not shipped.

## Engineering highlights

- **Calendar correctness.** The on-chain calendar is differentially tested against an independent Python implementation over 3,012 sessions, 27 early closes and 20,000 random timestamps (all equal); the single disagreement is a documented ad-hoc closure (2025-01-09) the rules cannot derive; 11 hand-made rule mutants were all caught (`docs/CALENDAR_NOTES.md`, findings).
- **Two implementations that disagreed, then reconciled.** Running Session A's replay scenario in my Python found a 45% gap in control losses; the cause was a liquidation-rule difference (the market caps the bonus so a liquidation never worsens an account), confirmed by testing the hypothesis (agreement to 0.01%) and locked in by a regression test.
- **Evidence discipline.** Every claim in `research/CLAIMS.md` names its file and CI; an explicit list of claims we will not make is part of the pitch (`research/PITCH_EVIDENCE.md`).
- **Integer-implementable estimator.** The gap-VaR estimator has a WAD fixed-point reference that matches the float version within 1e-6 and rounds against the user.
- **Threat model first.** Issuer controls (pause, block, `adminBurn`) are modelled and the market halts on detection; the limits of that mitigation are written down (`docs/THREAT_MODEL.md`).
- **Web quality.** 13 Playwright tests (smoke, 360 px overflow, axe light and dark with zero serious violations, theme, navigation, lazy wallet) pass on the production build; every number on the pages names its source file.

## Limitations (short)

Daily proxy and a single data vendor; the shipped cap is calibrated in-sample (inert out of sample) and the 2020-03-16 gap still produces a loss; limited calendar evidence (12 Weekend and 2 Long windows, no EST or early-close observations); thin, single-moment exit liquidity (about $0.9M of collateral across four markets); issuer controls are EOA-held and `adminBurn` cannot be mitigated; USDG assumed to be 1 USD; the replay is a forge in-process simulation and Sepolia uses a simulated feed. Full list: README, "Limitations".

## What is next

Fork-validate the oracle adapter, measure early-close and EST windows when they occur (2026-11-27 is the first early close), re-measure keeper participation, extend depth measurement to weekends, and test an on-chain guardian tightening that takes effect only at the next window boundary (roadmap, D27).

## Disclosure

- **Attribution.** Original contracts (MIT). Built on OpenZeppelin Contracts v5.7.0 (MIT). Design inspired by Morpho Blue (virtual shares, isolated markets) and Aave/Compound (kinked rates, liquidation parameters); no code copied.
- **Credits.** yfinance (Yahoo Finance data, subject to Yahoo's own terms), exchange_calendars (Apache-2.0), and Chainlink (the AggregatorV3 feed interface and the Robinhood Chain equity feeds).
- Repository history begins 2026-10-02 (first commit `c467ccd`). Team attestation of no prior code: {{PENDING:team_confirms_no_prior_code}}.
- Libraries and data sources are listed in the README, "Pre-existing work and third-party material".
- Development tooling disclosure: {{PENDING:development_tooling_disclosure}}.
