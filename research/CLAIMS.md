# CLAIMS (M2 + M2.1)

What we can and cannot defend, with evidence. Sample: 12 assets, windows 2018-01-01 to 2026-10-01 (test) unless stated; daily proxy (previous regular close -> next regular open), a conservative superset of the blind exposure. CIs are 95 % clustered bootstraps (date = all assets opening the same window date resampled together; month = calendar month). "bps/yr" = annualised bad debt in bps of outstanding debt per asset. UNIVERSE12 = all 12 assets, DEPLOY4 = TSLA/NVDA/AAPL/SPY. Files are in `research/results/` unless noted.

## Claims

| # | Claim | Evidence | CI / numbers | Status |
|---|---|---|---|---|
| 1 | Windows follow D1 (trading-day rule) and classes Short/Weekend/Long | `tests/test_calendar_windows.py`: 2 on-chain observations, DST 47/49 h, independent day-walk over 2010-2026 | exact | Supported. Early-close rule UNVERIFIED; Session A fixture comparison pending (test skipped) |
| 2 | The closed-window proxy gap has roughly the variance of an ordinary close-to-open proxy gap (not 3-4x) | `variance_ratios.csv`, month-cluster bootstrap | Weekend 1.23 [0.91, 1.57], Long 1.22 [0.80, 1.55], Short 0.65 [0.30, 1.01] | Supported **as a descriptive statement about the proxy only**. Weeknights are not blind (D1); this is not a risk comparison for the guard |
| 3 | The daily proxy overstates the blind exposure | `intraday_summary.json` (12 assets, 1,344 windows, 730 days) | extended-hours bracket = 58 % of proxy second moment; 99 % loss 342 vs 418 bps | Supported on a 2-year subset; never exact (overnight session not observable) |
| 4 | A 50 bps oracle buffer covers feed staleness at window start | simulated 0.5 %/24 h feed on hourly bars | adverse error p90 18, p99 41, max 48 bps | Supported **by simulation**; bounded by construction, not an on-chain measurement |
| 5 | The pooled-scaled EWMA gives a calibrated 99 % gap-VaR out of sample | `backtest_test_chosen.csv` | Weekend 1.87 % exceedances [0.96, 3.09], Long 1.23 % [0.27, 2.28], Short 4.51 % [0.38, 9.67]; Mar-2020 24 %; clustering p ~ 0 | **Not supported.** Effective coverage of nominal 99 % is ~98 %. 99.5 % VaR: Weekend 0.80 %; 99.9 %: 0.04 % (2/4,752) |
| 6 | One pooled class-scale vector fits all assets | `estimator_heterogeneity.csv` | Weekend exceedance by asset 0.5 % (TSLA), 0.8 % (WMT) ... 2.8 % (AAPL), 3.0 % (GOOGL); asset-specific scales do not fix it | **Not supported.** High-vol names are over-covered, mega-caps under-covered |
| 7 | At real flat LLTVs window-gap bad debt is negligible | `credit_summary.csv`, `per_asset_credit.csv` | 0 at <= 65 %; 0.08 bps/yr at 77 %; 4.5 bps/yr at 86 % (date-cluster CI [0.7, 9.7]); worst single-window loss 1.17 % | Supported for 2018-2026 with liquidations executing at bonus >= slippage. 63 % of 86 % bad debt is Mar-2020; JPM, NVDA, TSLA = 26/28/30 % |
| 8 | The stress rule reduces bad debt at in-the-wild LLTVs | `credit_frontier_*.csv`, `per_asset_credit.csv` | <= 77 %: exactly 0 (cap never binds on loss). 86 %: -0.58 bps/yr (13 %), CI [0, 1.7]; P(reduction <= 0) = 0.13 date / 0.37 month | **Not supported** (not distinguishable from 0). At 86 % TSLA gives 76 % and NVDA 24 % of the reduction; the other 10 assets give 0 |
| 9 | With enforcement the stress rule cuts bad debt at counterfactual 90-95 % LLTV | same, UNIVERSE12 (date cluster) | 90 %: -3.2 bps/yr [0.04, 8.5] (25 %); 93 %: -9.9 [1.6, 23.8] (41 %); 95 %: -19.5 [6.0, 40.9] (53 %). DEPLOY4: 93 % -21.2 [4.4, 47.0] | Supported at 93-95 %; marginal at 90 %. Counterfactual LLTVs, not observed anywhere |
| 10 | Equal-bad-debt LTV gain over a flat market | `credit_frontier_*.csv`, fig `m21_frontier_bands.png` | UNIVERSE12 gross: 86 %: +0.54 pp [0, 0.92]; 90 %: +1.24 [0.04, 1.98]; 93 %: +2.55 [0.92, 4.12]; 95 %: +3.61 [1.61, 5.50]. Net of capacity given up: 93 %: +2.28 [0.65, 3.83]. Month-cluster CIs within 0.2 pp | Supported as **modest** (2-4 pp), only above ~90 %, conditional on hard enforcement |
| 11 | A cap on new borrows only protects lenders | `mech_a_new_borrows_only.csv` | e = 0: zero by construction; 5 % turnover: 86 % -1 %, 93 % -3 % | **Not supported** |
| 12 | Hard pre-window deleveraging (cure window, reduced fee) is workable | `mech_b_hard_deleveraging.csv`; **assumptions, not estimates:** 70 % cure, 1 % fee, 1 % sale slippage | Bad-debt effect = claim 9. Borrower cost 0.25 bps of debt/yr (86 %, uniform) to 2.5 (93 %), 6.4 (93 %, clustered near max). Forced events per 100 borrowers per year (55 windows/yr): 86 %: 2 uniform / 9 clustered; 93 %: 19 / 80; 95 %: 43 / 181. A 30 % enforcement failure removes about 10 % (86 %) to 20 % (93 %) of the benefit | Partially supported: cheap in money, **heavy in event frequency at >= 93 %** and irrelevant at <= 77 %. Cure/fee/slippage unvalidated |
| 13 | A priced gap premium on exposure above the cap can fund a reserve | `mech_c_priced_premium.csv` | break-even premium 470-1,320 bps of excess debt **per window**; even 25x that leaves P(reserve exhausted in 10 y) = 0.34 / 0.33 / 0.20 / 0.11 (86/90/93/95 %, uniform) | **Not supported.** Losses come from gaps beyond the VaR cap, where exposure above the cap is tiny |
| 13b | Variant: premium on all debt into a reserve | `mech_c2_all_debt_premium.csv` | break-even = flat bad debt (4.5 bps/yr at 86 %) but the reserve must be seeded: p95 shortfall 200 bps of debt (p99 325) at 86 %; 660 / 1,040 at 93 %; clustered near max LTV up to 2,290 (p95) and 3,550 (p99) at 95 % | Supported as arithmetic; a premium-funded reserve cannot self-start (P(exhausted in 10 y) is still 17-18 % at 5x break-even from empty, for LLTV >= 86 %) |
| 14 | Liquidation bonus and slippage matter more than the guard | `slippage_grid.csv`, fig `m21_slippage_bonus.png` | 86 %, b = 4.4 %: slippage 0/1/3/5 % -> 4.5 / 6.3 / 11.7 / 21.0 bps/yr; b = 10 %, s = 3 %: 54; b = 15 %: 111-1,256. 77 %: ~0 unless b >= 8 % or s >= 3 %. The stress rule shaves 3-13 % of each cell at 86 % | Supported. Cells with (1+b)(1-s) <= 1 mean liquidators lose money and may not act (flagged `liquidator_margin_positive`) |
| 15 | Slippage grid {0,1,3,5} % spans realistic exits | `pool_depth_snapshot.json` (DexScreener TVL, Uniswap v3 `liquidity()` read over RPC, snapshot at retrieval) | USDG-pool TVL: TSLA $1.59M (11 pools), NVDA $4.82M (21), AAPL $1.71M (15), SPY $7.68M (17). Slippage at $100k: pessimistic (CP on half TVL) 11.2 / 4.0 / 10.5 / 2.5 %; optimistic (v3 active range) 1.7 / 0.14 / 0.7 / 0.18 % (TSLA/NVDA/AAPL/SPY) | Supported as a bracket only; $1M exits exceed the grid; RFQ/aggregator routing not modelled; snapshot moves minute to minute |

## Claims we will NOT make

- That Sundown is "safer than Aave/Morpho" or protects conventional (<= 86 %) LLTV markets materially.
- That the 99 % gap-VaR is calibrated, or that any estimator forecasts regime breaks (March 2020).
- That weekends/holidays are riskier than weeknights, or any comparison treating weeknight gaps as unaddressed risk (weeknights are not blind, D1).
- Any absolute magnitude of oracle-blind exposure (proxy only), or any behaviour of the feed beyond the two observed holidays and the simulation.
- That the equal-risk LTV gain generalises beyond 2018-2026, a sample whose tail is ~60 % one episode.
- That forced deleveraging is acceptable to users (cure rate, fee and slippage are assumptions) or that a gap reserve can be premium-funded.
- Any liquidation-liquidity guarantee: pool snapshot only, no route simulation, no RFQ.
- Statistical significance of the effect at 86 % (CI includes 0) or for any asset other than TSLA/NVDA there.
- That JPM/XOM/WMT results apply to deployable markets (feed membership unverified), or that Aave parameters are anything but secondary-source.
- That the Chainlink adapter or any on-chain integration is validated by this work.

## Findings for Session A (not applied; `docs/DESIGN.md` and `DISCOVERY.md` untouched)

1. **Guard framing/IRiskGuard:** the benefit is capacity expansion at >= 90 % base LLTV, not protection at 38-86 %. "Cap on new borrows/withdrawals only" has no effect; the design needs stress-HF deleveraging of existing debt with a cure window (claim 12) or the guard is cosmetic.
2. **GapRiskModel:** pooled-scaled EWMA (lambda 0.9, one (num, den) pair per asset, class scales {Short 0.76, Weekend 1, Long 0.92}, multiplier floor 1, K_MIN 8); use q = 99.5 % (99 % realises ~98 %); Short := Weekend parameters; `recordPostWindow` stores lag, skips (never imputes) lag > 12 h. Integer reference is in `estimators.py`.
3. **Reserve:** drop the premium-funded gap reserve from scope or require an externally seeded reserve of >= ~2 % of debt at 86 % (>= ~7 % at 93 %).
4. **Bonus/liquidity:** bonus bounds and per-market caps should be driven by exit liquidity (claim 14-15); add to DISCOVERY (D5 exit-liquidity item): USDG-pool TVL TSLA $1.59M, NVDA $4.82M, AAPL $1.71M, SPY $7.68M, v3 depth via RPC, snapshot date in `pool_depth_snapshot.json`.
5. **Asset selection:** at 86 % the whole effect comes from TSLA and NVDA; SPY/AAPL show none. Consider whether a TSLA/NVDA-only treatment market, or a higher-LLTV market only for them, is the honest product.
6. **D1 consistency:** remove any statement implying weeknight overnight gaps are blind; oracle is live 24/5 on weeknights.
7. **Open:** calendar fixture schema (`calendar_cases.json`) for the skipped differential test; early-close behaviour still UNVERIFIED.
