# Documentation index

Every document, what it establishes, and what it does **not**. Where a document states a number, the committed result it rests on is named in that document.

## Design and decisions

| Document | What it establishes | What it does not |
|---|---|---|
| [DESIGN.md](DESIGN.md) | The M0 architecture and the accepted decisions D1-D35 with their rationale and carry-forward notes (section 8). | It is a record of decisions; implementation status lives in the documents below. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the contracts fit together and which directories are production, fixtures, simulation and research (mermaid diagram), plus the trust boundaries. | No behavior claims beyond the design documents. |
| [CALENDAR_NOTES.md](CALENDAR_NOTES.md) | The trading-day blind-window model, the DST and holiday rules, and the verification findings: 12 weekends and 2 Long holiday windows observed on the real feeds. | No Short, EST or early-close observations; early closes are an unverified configuration constant. |
| [MARKET_DESIGN.md](MARKET_DESIGN.md) | The lending market: rounding table, interest model, liquidation rules, halt state machine, issuer-failure probes, invariants, implementation notes, measured coverage (`SundownMarket` 95.35 % lines, 94.59 % branches). | The branch figure is below the 95 % target; not an audit. |
| [GUARD_DESIGN.md](GUARD_DESIGN.md) | The session-aware guard: state machine, stress-cap math, bounds, attack list with a test or refutation each, the D26 calibration table and its consequence (SPY has no boosted variant), implementation notes. | The guard is a capacity policy with enforcement, not loss prevention; enforcement depends on a keeper. |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Trust assumptions, issuer-control risks, oracle and calendar risks, guard risks, required disclosures, known gaps, the Slither baseline, final test counts. | It lists residual risks that are not mitigated (phantom collateral after `adminBurn`, token upgrades). |

## Evidence

| Document | What it proves | What it does not |
|---|---|---|
| [DISCOVERY.md](DISCOVERY.md) | The M0 feasibility facts with verification labels: chains, issuer-token source (Sourcify), feeds, USDG, exit-liquidity depth table. | Chain state moves; observations are dated 2026-10-02. |
| [REPLAY_RESULTS.md](REPLAY_RESULTS.md) | AAPL 93 %, 10 worst events, 20-borrower seeded population: control loss $3,824 over 4 events, session-aware $1,224 over 1 event, standard 86 % $0; keeper economics; 120/120 rows within tolerance of the exact-integer reference. | A simulation in forge's in-process EVM with a fixture window cache, **not a public chain**; it depends on the population and one gap at reopen. SPY 93 % and AAPL 90 % are not enforced. |
| [ORACLE_LIVE_VALIDATION.md](ORACLE_LIVE_VALIDATION.md) | `ChainlinkEquityOracle` read the real Chainlink feeds for SPY, AAPL, NVDA and TSLA on Robinhood Chain mainnet: 8 to WAD normalization exact, ScheduledBlind classification against the calendar, wrong feeds rejected. | Only the blind branch was exercised on real data; no on-chain asset-identity check; the fork tests are intermittently flaky on the public RPC and optional. |
| [SEPOLIA_DEPLOYMENT.md](SEPOLIA_DEPLOYMENT.md) | The 27 deployed addresses on Arbitrum Sepolia with creation transactions, labeled production or simulation (generated from `deployments/421614.json`). | Simulation tokens and feeds; a single-key demonstration; no mainnet deployment. |
| [SEPOLIA_DEMO.md](SEPOLIA_DEMO.md) | Timestamped live evidence inside a blind window: faucet, supply, standard borrow, in-window capacity limits with decoded errors, a liquidation, the full halt cycle, an invalid answer rejected. | States what cannot be shown live: the boosted stress-cap denial, the `Stale` status, the pre-window horizon, cure window and deleveraging. |
| [CLAIMS_AUDIT.md](CLAIMS_AUDIT.md) | A read-only audit of the `m2-research` branch's user-facing documents and web copy against the committed evidence: which statements are supported, stale, overclaimed or mislabeled, with exact corrected wording. | Pinned to one branch commit (`f80b047`); the branch kept moving; Session B's files were not edited. |
| [RECOMMENDED_CAPS.md](RECOMMENDED_CAPS.md) | The recommended production collateral caps and how they derive from measured exit liquidity. | Recommendations only; one depth snapshot; nothing was deployed at these sizes. |

## Research (offline)

| Document | What it establishes | What it does not |
|---|---|---|
| [../research/README.md](../research/README.md) | How to reproduce the research. | |
| [../research/REPORT.md](../research/REPORT.md) | The M2 empirical findings on closed-window gaps (superseded where [CLAIMS.md](../research/CLAIMS.md) differs). | |
| [../research/CLAIMS.md](../research/CLAIMS.md) | The claims that can and cannot be defended, with evidence and confidence intervals; the benefit appears only as capacity expansion at counterfactual 90-95 % LLTV. | No claim at real LLTVs of 86 % or lower. |
| [../research/DATA_PROVENANCE.md](../research/DATA_PROVENANCE.md) | The data sources, the split-adjusted basis and what is committed (returns only). | Single source (Yahoo Finance via yfinance); daily proxy of the blind exposure. |

## Supporting

| Document | Purpose |
|---|---|
| [../sim/README.md](../sim/README.md) | What the simulations are, how to run the replay, and its limits. |
| [../deployments/README.md](../deployments/README.md) | The configuration directory and its verification-label rule. |
| [../CLAUDE.md](../CLAUDE.md) | The project's operating charter and standing rules. |

## Scripts

`scripts/preflight.sh` runs every pre-submission check; `scripts/sepolia_demo.py` regenerates the live evidence; `scripts/check_deployed.py`, `scripts/check_slither.py` and `scripts/secret_scan.sh` are the individual checks it uses.
