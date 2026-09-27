# M2 report: empirical foundation and risk-model calibration

> **M2.1 update:** claims, per-asset results, clustered CIs, enforcement mechanisms and the slippage grid are in [CLAIMS.md](CLAIMS.md); where this report and CLAIMS.md differ, CLAIMS.md governs (frontier numbers were recomputed on a 1 pp flat grid with date- and month-clustered bootstraps).
Status: research output on a **daily proxy** (previous regular close -> next regular open). The proxy is a conservative superset of the oracle-blind exposure: on the intraday subset the extended-hours bracket carries 58 % of the proxy's second moment and a 99 % loss of 342 bps vs 418 bps. It is never the exact blind gap. Split: structure chosen on 2015-2017 validation, evaluated strictly on 2018-2026-10-01 (test). All figures are reproducible with `make backtest`.

## 1. Coverage

12 assets, 2010-2026 (TSLA from 2010-06, META from 2012-05), 49,811 consecutive-session pairs; 8,970 weekend, 1,358 long, 490 short windows and 39,005 ordinary overnights. Windows reproduce the two on-chain observations (Labor Day, Independence Day observed) and DST (47 h / 49 h weekends). **Short has only 41 windows per asset** (~20 in training), Long 115: per-class estimation is infeasible for them.

## 2. Findings

**F1. Proxy-gap variance scales roughly 1x, not 3-4x.** Second-moment ratio of the closed-window proxy gap to an ordinary close-to-open gap (month-cluster bootstrap, 95 % CI, median across assets): Weekend **1.23 [0.91, 1.57]**, Long **1.22 [0.80, 1.55]**, Short **0.65 [0.30, 1.01]**. This is a descriptive property of the daily proxy (how big a gap is after a multi-day closure relative to a normal one), not a measure of oracle-blind exposure and not a statement about Sundown's value: under D1 weeknights are *not* blind (the 24/5 feed is live), so ordinary close-to-open gaps are not a comparison population for the guard. Earnings gaps inflate the baseline; the proxy also contains Monday pre-market news the feed would show.

**F2. The tails are the issue, not the variance.** Weekend excess kurtosis 11-47 (SPY 46.6, Mar-2020). Weekend 99 % loss (bps, point [CI]): SPY 259 [156, 537], AAPL 359 [258, 915], NVDA 754 [453, 1256], TSLA 555 [423, 1293]. 99.9 % is unresolvable per asset (n ~ 760).

**F3. Oracle noise (N1).** Simulated 0.5 %-deviation / 24 h-heartbeat feed on hourly bars: adverse staleness at window start is 0 at the median, 18 bps at p90, 41 bps at p99, 48 bps max (1,344 windows). The 50 bps deviation bound is nearly tight at the tail, so **the oracle buffer is set to 50 bps**. Hourly sampling makes the error bounded by construction; this is a floor on realism, not a chain measurement.

**F4. Censoring (N2).** If no update is pushed at reopen (the two observed holidays show one is), the first observation arrives with lag p50 0 h, p90 5 h, p99 12 h, max 72 h; 99.5 % are deviation-triggered; 55 % of reopen gaps are below 50 bps; 4.6 % of recorded gaps understate the reference loss by more than 50 bps. On daily data, dropping sub-50 bps gaps would *overstate* tail quantiles (SPY weekend 99 % loss 259 -> 537 bps): a conservative bias. **M4 recommendation:** record at the first update with `updatedAt >= windowEnd`, store the lag, skip (never impute) observations with lag above a cap (12 h covers 99 %), keep the multiplier floor.

**F5. Estimator (pooled-scaled EWMA, lambda 0.90).** Chosen on validation pinball loss over 21 candidates (EWMA, rolling HS N=126/250/500, blends, pooled-scaled; lambda 0.80-0.99) with a pre-set tie rule (simplest within 2 %). One (num, den) accumulator pair per asset; fixed class scales k = {Short 0.76, Weekend 1, Long 0.92}; class multipliers floored at 1. Integer/WAD reference matches float to < 1e-6 and rounds up.

**F6. Model failures (out of sample, 99 % VaR).**

| Class | n | exceedance rate | cluster-bootstrap 95 % CI | Kupiec p* | ES / VaR |
|---|---|---|---|---|---|
| Weekend | 4,752 | **1.87 %** (target 1 %) | [0.96, 3.09] | ~0 | 1.57 |
| Long | 732 | 1.23 % | [0.27, 2.28] | 0.55 | 1.71 |
| Short | 288 | **4.51 %** | [0.38, 9.67] | ~0 | 1.36 |

*Pooled Kupiec ignores cross-asset dependence and is anti-conservative; read the CI. Christoffersen independence rejects for Weekend (p ~ 0): exceedances cluster. Mar-2020 alone: 29 exceedances in 120 windows (24 %); excluding named regimes the rate is 1.27 %. The 99.5 % VaR hits 0.80 % (Weekend), the 99.9 % VaR hits 0.04 % (2 of 4,752). **Effective coverage of the nominal 99 % is about 98 %**; use q = 99.5 % or a wider buffer. Rolling HS (N=250) gets 1.01 % coverage but its VaR is 65 % wider (662 vs 401 bps) and it also clusters; no estimator forecasts regime breaks. Short fails and is too small to fix: treat Short with Weekend parameters until live data accrues. Aug-2015 sits in the validation slice (named in `backtest_regimes_test.csv` as out of test).

**F7. Credit simulation (2018-2026, 12 assets; borrowers on a 20-point utilisation grid of max LTV, full close factor, no slippage).**

- At the **real flat LLTVs (38.5 / 62.5 / 77 / 86 %, Aave 65 / 79 %) window gaps produce almost no bad debt**: 0 % at <= 65 %, ~0.00001 % at 77 %, 0.0008 % of outstanding at 86 % (annualised 4.5 bps, 99.9th-percentile window lender loss 0.31 %, worst 1.17 %). **The stress rule is inert there**: it cuts annualised bad debt at 86 % by 13 % (4.46 -> 3.87 bps), bootstrap CI of the reduction includes 0, and it never binds below ~90 % LLTV.
- The rule only matters where it binds. Counterfactual flat LLTV 90/93/95 % (not observed anywhere): annualised bad debt 12.6 / 24.0 / 36.7 bps, with the rule 9.4 / 14.0 / 17.3 bps (reduction CIs exclude 0 for 93 and 95 %). Costs: capacity given up at windows 0.25 / 0.62 / 1.19 %, time-averaged 0.12 / 0.29 / 0.56 %, forced deleveraging 0.03-0.14 % of debt. **Equal-risk frontier:** the rule buys **+1.6 / +2.6 / +3.8 pp LTV** over an equal-bad-debt flat LLTV (UNIVERSE12; CIs in `credit_frontier.csv`, DEPLOY4 +1.9 / +3.4 / +4.9). That is modest and noisy.
- **Enforcement is the whole effect.** If the cap applies only to new borrows (pre-existing positions untouched) the benefit is exactly zero; at 50 % enforcement about half. The design (3.4) restricts new borrows/withdrawals, not existing debt, so it needs a stress-HF deleveraging path to work.
- **Sundown does NOT help with** (M2.1 corrected): regular-hours in-session moves (oracle live; 1.0 / 32.9 bps/yr at flat 86 / 93 %), single-name shocks beyond the VaR, thin liquidation liquidity (bonus and slippage dominate, see M2.1), issuer pause/blocklist/adminBurn, oracle bugs. The earlier comparison with ordinary overnight gaps was removed: weeknights are not blind under D1.
- Sensitivities (`credit_sensitivity.csv`): VaR quantile 99.5 / 99.9 % lifts reduction at 86 % to 50 % / ~100 % at 0.37 % / 4.3 % capacity cost at windows; adverse staleness 50 bps raises control bad debt 25 % and the 50 bps buffer covers it; high-utilisation borrowers raise bad debt ~2.8x; full-history run (`credit_summary_full_history.csv`, in-sample before 2018) agrees.
- Liquidated share per event (~4.6 %) is a scale-invariant artifact of the utilisation grid (a borrower is liquidated iff utilisation >= post-gap value, independent of LLTV); do not read it as LLTV risk.

## 3. Recommendation (product change, for discussion)

1. **Do not sell the guard as protection at conventional LLTVs**; against Morpho/Aave-style parameters it is near-redundant on this evidence.
2. **Reframe as capacity expansion**: run the isolated market at a higher base LLTV (90-93 %) with window tightening and stress-HF deleveraging, and measure the equal-risk LTV gain (+2-4 pp) in M7 replays. Decide whether +2-4 pp justifies the extra machinery.
3. Calibrate to q = 99.5 %, oracle buffer 50 bps, safety 100 bps; seed the cold start from `risk_params.json`; treat Short as Weekend.
4. Make the **liquidation bonus** and liquidation liquidity first-class: they dominate tail loss in the sensitivity.
5. (Removed in M2.1: the overnight (n = 0) comparison does not apply under D1.)

## 4. Limits and open items

Daily proxy, single vendor, no on-chain feed comparison (M1), no liquidity/slippage model, no earnings calendar, borrower model stylised, no interest/time. `risk_params.json` is a research artifact (deployment fit on full history; bonus bounds are design-derived and unvalidated; JPM/XOM/WMT feed membership unverified and research-only). The calendar fixture test is skipped until Session A's `calendar_cases.json` exists. D1-D5 / N1-N5 are **not yet recorded** in `docs/DESIGN.md` section 8 because Session A owns that file; D5's exit-liquidity depth check for DISCOVERY.md is outside this milestone and still open.
