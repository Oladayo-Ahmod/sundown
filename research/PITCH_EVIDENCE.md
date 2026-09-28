# Sundown: evidence summary for judges

Written for: hackathon judges and technical reviewers. Everything below is offline research on 12 US equities (2010-2026), replaying real gaps between a stock's last regular close and its next regular open. It is a **conservative proxy** for the true oracle-blind exposure, not an on-chain measurement. Full tables, CIs and code: `research/CLAIMS.md`, `research/results/`, `make backtest m21 m22`.

## Three headline claims

**1. Weekend and holiday gaps cost conventional lending markets almost nothing, so we do not claim to fix them.** Replaying 2018-2026 (including March 2020) against the loan-to-value limits actually used on Robinhood Chain's Morpho markets: window-gap bad debt is 0 at <= 65 % LLTV, 0.08 bps/yr at 77 % and **4.5 bps/yr at 86 %** (95 % CI [0.7, 9.7], date-clustered), worst single window 1.2 % of debt; 63 % of the 86 % loss is one episode (March 2020). Our stress rule changes none of this below ~90 %.

**2. At higher LLTV the session-aware rule works, with enforcement.** With a gap-risk estimate per asset (pooled-scaled EWMA, integer-implementable) and hard pre-window deleveraging, bad debt falls **41 % at 93 % base LLTV** (23.98 -> 14.03 bps/yr, reduction 9.9, CI [1.6, 23.8]) and **53 % at 95 %** (reduction 19.5, CI [6.0, 40.9]); at equal bad debt it buys **+2.6 pp LTV at 93 % (CI [0.9, 4.1])**. Without enforcement (cap on new borrows only) the effect is exactly zero. These LLTVs are counterfactual: no market uses them today.

**3. Liquidation design and exit liquidity matter more than the guard, and tell us where a boosted tier is credible.** In a depth-calibrated model (pool snapshot, convex slippage, rational liquidators), cutting the flat bonus from 5.5 % to 2 % lowers bad debt **8.8 bps/yr at 86 % (CI [2.0, 17.7])** and 76 bps/yr at 93 % (CI [49, 106]); a Dutch ramp or depth-capped sizing does not help lenders. A boosted tier (90-93 %) covers its added lender loss at a **break-even borrow APR of 0.7-3.6 % for SPY** (upper CI bounds up to 9 %) and 1.4-8.6 % for AAPL, but 2.6-18 % for TSLA/NVDA, so we would offer it for SPY (and AAPL at 90 %) only.

## What we will NOT claim

- That Sundown is "safer than Aave or Morpho", or that it protects conventional LLTV markets.
- That our 99 % gap-VaR is calibrated: out of sample it realises ~98 % (Weekend 1.87 %, CI [0.96, 3.09]); March 2020 breaks it; Short windows fail (4.5 %).
- That weekends are riskier than weeknights, or any exact size of oracle-blind exposure (daily proxy only; on a 2-year hourly subset the proxy overstates it).
- That the +2-4 pp LTV gain generalises beyond 2018-2026, a sample whose tail is ~60 % one episode.
- That forced deleveraging is acceptable to borrowers (cure rate and fee are assumptions; 0.4-3.4 events per borrower-year on TSLA at 90-93 %), or that a premium-funded gap reserve works (it does not).
- That exit liquidity is guaranteed: one secondary-source pool snapshot (TSLA $1.6M, NVDA $4.8M, AAPL $1.7M, SPY $7.7M TVL), no routing or RFQ, bonuses below ~2-3 % unproven with real keepers.
- That any on-chain integration (Chainlink adapter, Robinhood token controls) is validated by this work, or anything about issuer risks (pause, blocklist, adminBurn), which no parameter here mitigates.
