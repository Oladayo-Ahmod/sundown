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

---

# M2.2 additions: liquidation design, exit liquidity, two-tier

Model (see `liquidation.py`): Uniswap-v3-in-range constant-product slippage `N/(N+y)`, `y = concentration x TVL / 2`, TVL from a **single secondary-source snapshot** (DexScreener, `pool_depth_snapshot.json`: TSLA $1.59M, NVDA $4.82M, AAPL $1.71M, SPY $7.68M); concentration 1 is the pessimistic anchor. Rational liquidators execute only while average slippage + 5 bps gas <= bonus; unexecuted demand is delayed to the next 30-minute round (pool refills fully between rounds, an assumption); price drifts along the same day's open-to-close return; leftover liquidatable positions are settled at the close with the design's bonus. Market debt = 0.25 x TVL (assumption; 0.1-1 tested). DEPLOY4 only (no depth data for the other assets). At infinite depth the simulator reproduces `credit_sim` to 1e-17 (test).

| # | Claim | Evidence | CI / numbers | Status |
|---|---|---|---|---|
| 16 | Pool depth barely affects lender bad debt at realistic market sizes | `liq_design_sensitivity.csv` | debt = 0.25 x TVL: +0.5 % vs infinite depth (12.45 vs 12.39 bps/yr at 86 %); concentration >= 5x: identical; debt = 1 x TVL: +10 % (13.6 vs 12.4) | Supported for this model. Participation is not the binding constraint; it would be at market debt well above TVL |
| 17 | A Dutch bonus ramp reduces lender bad debt | `liq_design_comparison.csv` | Dutch 1 -> 5.5 % over 30/60/120 min: 12.45 / 43.5 / 119.8 bps/yr at 86 / 90 / 93 %, **identical to flat 5.5 %** (12.45 / 43.5 / 119.8). It lowers the borrower-side bonus cost by roughly 50-70 % (relative index) | **Not supported for lenders.** A Dutch ramp to `bmax = formula` looks better at 93 % only because its bmax (3.8 %) is below 5.5 %; at 86 % it is worse (25.7) |
| 18 | Partial-liquidation sizing capped to a fraction of depth helps | same | cap 2 % / 5 % of depth: 13.0 / 12.5 (86 %), 121.5 / 119.8 (93 %) vs 12.45 / 119.75 uncapped; close factor 50 vs 100 %: no difference | **Not supported** in a rational-liquidator model (can only slow liquidation). Value against MEV/manipulation is unmodelled |
| 19 | The liquidation bonus level is the dominant lever | `liq_bonus_sweep.csv`, `m22_headline_ci.csv` | DEPLOY4 mean, debt 0.25 x TVL, flat CF100: bonus 5.5 % -> 2 % cuts bad debt 12.4 -> 3.6 bps/yr at 86 % (reduction 8.8, date CI [2.0, 17.7]) and 119.8 -> 43.5 at 93 % (76.3, [49.4, 106.4]). At debt = 1 x TVL the optimum is 1-2 %; bonus 8 % at 93 % LLTV is insolvent by construction (0.93 x 1.08 > 1) | Supported in-model, **conditional on liquidators still acting at 2 %** (gas set to 5 bps; keeper margins, competition and price risk beyond the delay drift are not modelled). Do not ship <= 2 % without live keeper evidence |
| 20 | Per-market collateral caps from exit depth | `market_caps.csv` | Max single liquidation at 1 / 3 / 5 % slippage (pessimistic CP): TSLA $8.0k / 24.6k / 41.9k; NVDA $24.3k / 74.5k / 126.7k; AAPL $8.6k / 26.4k / 44.9k; SPY $38.8k / 118.8k / 202.2k (x5 / x15 for concentrated liquidity). Max market debt so that the p99.9 window liquidates within that slippage: TSLA $19k / 59k / 101k; NVDA $65k / 200k / 341k; AAPL $35k / 109k / 185k; SPY $160k / 489k / 832k | Supported as an order-of-magnitude sizing rule; one snapshot; RFQ/aggregator routing not modelled |
| 21 | A boosted tier (90-93 % with pre-window deleveraging) earns its keep for SPY and, at 90 %, AAPL; not for TSLA/NVDA | `two_tier.csv`, `m22_headline_ci.csv` (30 % boosted debt, shared liquidity, flat 5.5 %); break-even borrow APR = added lender bad debt / extra debt | uniform / clustered-near-max borrowers: SPY 90 %: 0.67 [0, 1.9] / 1.8 [0, 5.1]; SPY 93 %: 1.36 [0.2, 3.1] / 3.6 [0.6, 8.0]; AAPL 90 %: 1.4 [0.1, 3.3] / 3.7 [0.4, 8.5]; AAPL 93 %: 3.3 [1.3, 5.9] / 8.6 [3.6, 15.3]; TSLA 90 %: 2.6 / 6.8; TSLA 93 %: 4.7 [2.0, 8.3] / 12.0 [5.1, 20.7]; NVDA 90 %: 4.2 / 10.9; NVDA 93 %: 7.2 [3.2, 12.4] / 18.5 [8.4, 31.1] | **Partially supported.** Compare with the market's real USDG borrow APR (not measured here; 5 % is an assumption). Break-even is expected-value only, ignores tail clustering and reserve needs. For SPY the deleveraging adds little (13 % lower bad debt): the tier is mostly "higher flat LLTV on a low-volatility ETF" |
| 22 | Boosted-tier borrower burden | `two_tier.csv` | Extra borrowing power +13 pp (90 %) / +16 pp (93 %) nominal; capacity given up in windows (time-avg) 0.03-0.47 pp (90 %), 0.08-1.22 pp (93 %). Forced pre-window deleveraging events per boosted borrower per year (uniform / clustered): SPY 0.02 / 0.10 (90 %), 0.05 / 0.21 (93 %); AAPL 0.06 / 0.26, 0.17 / 0.71; NVDA 0.20 / 0.83, 0.48 / 1.99; TSLA 0.36 / 1.51, 0.80 / 3.35. Worst window lender loss 0.2-1.6 % of market debt | Supported; cure rate (70 %) and fee are assumptions |

### Additional claims we will NOT make (M2.2)

- That a Dutch ramp, a close-factor choice or a depth-capped liquidation size makes lenders safer.
- That bonuses below ~2-3 % are deployable (keeper participation unmodelled), or that higher bonuses are safer (they are not, in-model).
- That the depth snapshot is a liquidity guarantee: one DexScreener-sourced snapshot, v3 range structure approximated, no routing/RFQ, pool refill between rounds assumed.
- That the boosted tier is profitable for lenders: break-even APR is compared to an assumed 5 %, not a measured USDG borrow rate, and ignores tail clustering (Mar-2020) and reserve funding.
- That the boosted tier works for TSLA or NVDA, or that boosted borrowers are protected from forced deleveraging (0.4-3.4 events per borrower-year on TSLA).

### Findings for Session A (M2.2, not applied)

1. **IRiskGuard/liquidation module:** drop the Dutch ramp and depth-capped sizing from the lender-safety scope (they do not move lender bad debt); keep a ramp only if borrower-side liquidation cost is a goal. Make the **bonus a governance parameter swept against depth** (candidate 2-4 %, never above `1/LLTV - 1`); add the depth-capped market debt limit (claim 20) as the per-market borrow cap rule.
2. **Product:** boosted tier only for SPY (and AAPL <= 90 %), standard tier otherwise; TSLA/NVDA stay standard (<= 77 %). Boosted tier needs the cure window and the deleveraging path already specified in M2.1.
3. **DISCOVERY (D5 exit liquidity):** add the per-asset caps table and snapshot numbers; the 1 % slippage single-liquidation size is only ~$8k on TSLA/AAPL under the pessimistic reading.
4. **Open evidence needed before claiming more:** live keeper participation at <= 3 % bonus, measured USDG borrow APR on Morpho/Robinhood, per-asset depth beyond the 4-asset deploy set, route-level (RFQ) exit liquidity.

---

# M7a update: measured USDG borrow rates (replaces the assumed 5 % APR)

Source: `results/morpho_rates_snapshot.json`, **read on-chain** (Morpho Blue `0x9D53...1010` on chain 4663; `market()`, `idToMarketParams()` and the IRM's `borrowRateView()` at the block recorded in the file; market ids enumerated from the Morpho API). One point-in-time reading; the IRM is an adaptive curve, so rates move with utilisation.

| Market (USDG loan) | LLTV | Utilisation | Borrowed | Measured borrow APR |
|---|---|---|---|---|
| AAPL | 62.5 % | 99.99 % | $197k | **7.83 %** |
| NVDA | 62.5 % | 98.5 % | $614k | 10.92 % |
| GOOGL | 62.5 % | 96.6 % | $204k | 6.14 % |
| SPY | 62.5 % | 42.2 % | $4.7k | **0.06 %** |
| Reference: USDe collateral / syrupUSDG collateral | 91.5 % | 89 % / 90 % | $308M / $117M | 4.07 % / 4.10 % |

| # | Claim | Evidence | Numbers | Status |
|---|---|---|---|---|
| 23 | Boosted-tier break-even APR (claim 21) versus the measured rate | break-even from `two_tier.csv`, rates from `morpho_rates_snapshot.json` | **SPY:** break-even 0.67 / 1.8 % (90 %) and 1.36 / 3.6 % (93 %), uniform / clustered borrowers. Covered by the ~4.1 % large-market rate and the 6-11 % stock-market rates, **not covered by the SPY market's own current 0.06 %** (42 % utilisation, $4.7k borrowed). **AAPL 90 %:** 1.4 / 3.7 % vs measured 7.83 %: covered. AAPL 93 %: 3.3 / 8.6 % vs 7.83 %: covered only for uniform borrowers | Partially supported. The comparison is expected value at one snapshot of an adaptive-curve rate; it ignores tail clustering and reserve funding. The SPY boosted tier is economic only if boosted borrowers pay about the large-market rate or higher, not the idle-market rate. AAPL's 7.83 % reflects ~100 % utilisation and would fall if supply grew |

Not claimed: any rate time series, any statement about the rate a future Sundown market would clear at, or that the break-even covers tail-driven reserve needs.
