# Sundown: submission

Written for: hackathon judges (technical reviewers). Every factual statement below comes from the repository: `research/CLAIMS.md`, `research/results/`, `docs/DISCOVERY.md`, `docs/CALENDAR_NOTES.md`, `docs/THREAT_MODEL.md`. Items that depend on a deployment or on the team are placeholders; `scripts/check_pending.sh` lists them and must print "no pending tokens" before this is submitted.

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
| License | {{PENDING:license}} |
| Chains | Robinhood Chain mainnet (read-only evidence), Arbitrum Sepolia (demonstration, simulated feed): {{PENDING:sepolia_deployment_status}} |

## Short description

Tokenized stocks trade almost around the clock, but the Chainlink feeds that lending markets rely on go blind on a calendar (Sunday 20:00 ET to Friday 20:00 ET, plus NYSE holidays), and today's markets price that with one static LLTV. Sundown measures what that risk costs, builds a calendar-aware oracle adapter and a small auditable lending core with a swappable risk guard, and reports honestly where a session-aware guard helps: not at today's limits, but at higher LLTV with enforcement, with one credible boosted-tier case (AAPL at 90%).

## The problem (with sources)

- 194 stock tokens on Robinhood Chain mainnet, 18 decimals; 32 have Chainlink push feeds (24/5, 0.5% deviation, 24 h heartbeat). `docs/DISCOVERY.md` b, c.
- Measured on-chain: of 4,716 feed updates on six feeds, none inside a predicted blind window; 14 windows analysed (12 Weekend, 2 Long). `docs/CALENDAR_NOTES.md`.
- Morpho stock-collateral markets use static LLTVs of 38.5%, 62.5%, 77%, 86%. `docs/DISCOVERY.md` f. Aave V4 Equities Hub parameters are secondary-source only.
- The collateral is issuer-controlled: pause, blocklist, `adminBurn` and a beacon upgrade for all tokens, all behind EOA-held roles. `docs/DISCOVERY.md` b.

## What we built

| Area | Contents | State |
|---|---|---|
| Research | D1 blind-window calendar, 12-asset 2010-2026 gap data, gap-VaR estimators (float and integer reference), out-of-sample backtests with Kupiec and Christoffersen tests, credit simulation with clustered-bootstrap CIs, liquidation-design and two-tier studies, claims register | Complete |
| Contracts | `UsMarketCalendar` and `MarketCalendar`, `ChainlinkEquityOracle` and `WindowCache`, `SundownMarket` (ERC-4626 vault + isolated lending + liquidation + issuer-failure halt policy), `SundownMarketFactory`, `FlatGuard`, labelled `SimEquityFeed` | Implemented: {{PENDING:contracts_forge_test_count}}; oracle fork test {{PENDING:oracle_fork_test_result}} |
| Session-aware guard | Pre-window deleveraging guard | Not implemented |
| Web | Landing, risk evidence, replay; research simulation only, no contract calls | Built; Playwright and axe checks pass; deployed {{PENDING:vercel_url}} |
| Demonstration | Four Arbitrum Sepolia markets at demonstration scale, simulated feed | {{PENDING:sepolia_market_addresses}}; replay transactions {{PENDING:sepolia_replay_tx_links}} |

## What is real and what is simulated

| Real (reproducible) | Simulated or modelled (labelled as such) |
|---|---|
| Equity price history (Yahoo Finance), used as a daily proxy | Every lending-market result in `research/results/credit_*`, `liq_*`, `two_tier.csv`: a model of borrowers and liquidations replayed over real gaps |
| On-chain reads: feed update history, Morpho market state and borrow rates, Uniswap v3 depth, token source and role holders | Borrower behaviour (20-point utilisation grid), cure rate and fees in the deleveraging mechanism |
| Calendar library, differential-tested against an independent implementation | The Arbitrum Sepolia demonstration price feed (`SimEquityFeed`) |
| Contract code and tests | Anything the research labels counterfactual (LLTV 90-95% markets do not exist today) |

## Evidence (95% CIs; bad debt in bps of outstanding debt per year)

1. **Conventional LLTVs lose almost nothing to weekend gaps** (so we do not claim to fix them): 4.5 bps/yr at 86%, CI [0.7, 9.7]; 0.08 at 77%; 63% of the 86% loss is March 2020.
2. **At a counterfactual 93% LLTV the session-aware rule works with enforcement:** bad debt falls 41% (reduction 9.9, CI [1.6, 23.8]); +2.6 pp of LTV at equal bad debt (CI [0.9, 4.1]). With enforcement off the effect is exactly zero.
3. **Liquidation design matters more than the guard:** cutting the flat bonus from 5.5% to 2% lowers bad debt by 8.8 bps/yr at 86% (CI [2.0, 17.7]) if keepers still act. **Boosted-tier case: AAPL at 90%:** break-even borrow APR 1.4% (CI [0.1, 3.3]) to 3.7% (CI [0.4, 8.5]) against a measured 7.83% on the AAPL/USDG market (99.99% utilised, block 78,552,299). SPY is secondary (its market is idle); TSLA and NVDA are not recommended for a boosted tier.

Negative results we kept: the 99% gap-VaR is not calibrated out of sample (1.87% exceedances on weekends, CI [0.96, 3.09]); the Dutch ramp and depth-capped liquidation do not help lenders; a premium-funded gap reserve cannot self-start; the stress rule is not distinguishable from zero at 86%.

## Engineering highlights

- **Calendar correctness.** The on-chain calendar is differentially tested against an independent Python implementation over 3,012 sessions, 27 early closes and 20,000 random timestamps (all equal); the single disagreement is a documented ad-hoc closure (2025-01-09) the rules cannot derive; 11 hand-made rule mutants were all caught (`docs/CALENDAR_NOTES.md`, findings).
- **Evidence discipline.** Every claim in `research/CLAIMS.md` names its file and CI; an explicit list of claims we will not make is part of the pitch (`research/PITCH_EVIDENCE.md`).
- **Integer-implementable estimator.** The gap-VaR estimator has a WAD fixed-point reference that matches the float version within 1e-6 and rounds against the user.
- **Threat model first.** Issuer controls (pause, block, `adminBurn`) are modelled and the market halts on detection; the limits of that mitigation are written down (`docs/THREAT_MODEL.md`).
- **Web quality.** 13 Playwright tests (smoke, 360 px overflow, axe light and dark with zero serious violations, theme, navigation, lazy wallet) pass on the production build; every number on the pages names its source file.

## Limitations (short)

Daily proxy and a single data vendor; limited calendar evidence (12 Weekend and 2 Long windows, no EST or early-close observations); thin, single-moment exit liquidity (about $0.9M of collateral across four markets); issuer controls are EOA-held and `adminBurn` cannot be mitigated; USDG assumed to be 1 USD; Sepolia demonstration uses a simulated feed. Full list: README, "Limitations".

## What is next

Implement and fork-validate the session-aware guard (boosted tier for AAPL at 90%), measure early-close and EST windows when they occur (2026-11-27 is the first early close), re-measure keeper participation at low bonuses, and extend depth measurement to weekends.

## Disclosure

- Repository history begins 2026-10-02 (first commit `c467ccd`). Team attestation of no prior code: {{PENDING:team_confirms_no_prior_code}}.
- Third-party libraries and data sources are listed in the README, "Pre-existing work and third-party material". Contract code attribution: {{PENDING:contracts_third_party_attribution}}.
- Development tooling disclosure: {{PENDING:development_tooling_disclosure}}.
