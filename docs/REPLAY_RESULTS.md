# Replay results (M4b, D25)

**SIMULATION.** Prices come from `SimEquityFeed` through the production `ChainlinkEquityOracle`; the worst real daily gaps for AAPL and SPY (previous close to next open, split-adjusted, 2010-2026, from `sim/replay_events.json`) are applied as one gap at reopen. Read `sim/README.md` for the limits before quoting a number. Framing: **session-aware LLTV: boosted weekday capacity, tighter weekend capacity**. These results measure a capacity policy against a frozen-price control; they are not a claim of loss prevention.

Setup: 20 leverage-seeking borrowers (50 tokens at $100, debt 80-99 % of the tier cap), $5,000,000 lender liquidity, calibration D26 (full-sample empirical q99.5 per asset and class, `GUARD_DESIGN.md` section 11), deleverage fee 2 %, horizon 6 h, cure 3 h, no borrower cures (the conservative case). Three markets per event and tier: **control** (FlatGuard at the tier LLTV), **sundown** (SundownGuard), **standard** (FlatGuard at 86 %). Amounts in USDG.

## Totals over the K = 10 worst events per asset

| Asset | Tier | Variant | Lender loss | Events with loss | Ordinary liquidations | Deleverage calls | Deleveraged debt | Weekday capacity | In-window capacity | Borrowed |
|---|---|---|---|---|---|---|---|---|---|---|
| AAPL | 93 % | control | 3,823.83 | 4 | 164 | 0 | 0 | 93,000 | 93,000 | 83,235 |
| AAPL | 93 % | **sundown** | **1,224.37** | **1** | 138 | 32 | 38,247.80 | 93,000 | **89,347** | 83,235 |
| AAPL | 93 % | standard 86 % | 0.00 | 0 | 70 | 0 | 0 | 86,000 | 86,000 | 76,970 |
| AAPL | 90 % | control | 891.30 | 1 | 90 | 0 | 0 | 90,000 | 90,000 | 80,550 |
| AAPL | 90 % | sundown (weakly enforced) | 891.30 | 1 | 90 | 0 | 0 | 90,000 | 89,347 | 80,550 |
| SPY | 93 % | control | 996.34 | 1 | 84 | 0 | 0 | 93,000 | 93,000 | 83,235 |
| SPY | 93 % | sundown (**unenforced**) | 996.34 | 1 | 84 | 0 | 0 | 93,000 | 93,000 | 83,235 |
| SPY | 90 % | control / sundown (unenforced) | 0.00 | 0 | 48 | 0 | 0 | 90,000 | 90,000 | 80,550 |

AAPL 93 % per event (control / sundown / standard): 2020-03-16 (13.9 % gap) 1,923.95 / 1,224.37 / 0; 2015-08-24 967.17 / 0 / 0; 2020-03-09 432.68 / 0 / 0; 2024-08-05 500.03 / 0 / 0; the other six events 0 / 0 / 0. In the two Long-class events (2011-01-18, 2020-09-08) the cap is 92.53 % and no account exceeds it, so nothing is deleveraged.

## What this says, and what it does not

- **AAPL 93 %**: against the frozen-price control at the same LLTV, session-aware capacity cut total lender loss over the ten worst events by 68 % (3,824 to 1,224) and removed it in three of four loss events, at the price of 3.9 % lower in-window capacity; weekday capacity is unchanged. It did **not** match the 86 % standard market, which lost nothing in any event, with 7.5 % less capacity. The 2020-03-16 gap (13.9 %) still produced a loss: a position held at the 89.35 % stress cap (or deleveraged to 88.85 %) is insolvent after a 13.9 % gap, because the cap is a q99.5 design point, not a worst-case bound (the same gap exceeds the q99.5 for AAPL Weekend, 9.15 %).
- **AAPL 90 %** and **SPY 90 %/93 %**: the stress cap does not bind (or binds by 65 bps in Weekend only), nothing is deleveraged, and results equal the control. These variants are **not** deployed as boosted markets (D26).
- The numbers depend on the population (20 accounts, 20 % of them above the stress cap) and a single gap at reopen. Different distributions change magnitudes; the direction (fewer and smaller losses than the control, never more) follows from the mechanism.
- 138 ordinary liquidations (sundown) versus 164 (control): fewer accounts are liquidated at the gap because they were deleveraged first; liquidation exit slippage is not modelled.

## Keeper economics (D29)

At the demonstration scale the keeper deleverages 4 accounts per weekend event: batch notional about $4,876. Average slippage from the v3 depth table ($85,822 / $196,590 / $220,049 at 1 / 3 / 5 %) is 0.06 %, plus an assumed $0.50 gas per batch (**assumption, not measured**): break-even about 0.07 %, far below the default fee `max(2 %, break-even) = 2 %`.

| Fee | Largest batch the table supports (AAPL) | Largest total borrowed this population supports |
|---|---|---|
| 2 % | $141,186 | about $2.4 million |
| 5.5 % (bonus cap) | $220,049 | about $3.8 million |

The recommended AAPL collateral cap (0.5 x $196,590 = $98,295) supports about $91,000 of debt; even if every borrower were above the stress cap the batch would be about $44,000. **At the recommended caps deleveraging is viable; above roughly $2.4 million borrowed against this depth, enforcement at a 2 % fee may silently not execute** (no keeper can sell the batch within the fee). SPY is not enforced, so no break-even is reported for it. The demonstration keeper is the replay script; a production keeper service is out of scope.

## Cross-check against the exact-integer Python reference

`research/replay_reference.py` re-implements the timeline and the guard rules from `GUARD_DESIGN.md` in exact integers (it reuses the validated market model of `market_reference.py`; the guard formulas are a second implementation by the same author, so the check catches transcription and wiring errors, not a shared misreading of the design). `sim/compare_replay.py`: **120 of 120 rows within tolerance, 111 exact**; counts (liquidations, deleverage calls) match exactly in every row; the largest amount difference is 86 units of lender loss (4.5e-8 relative), which comes from the harness publishing the gapped price through the 8-decimal feed (truncation) while the reference uses the exact ratio. Tolerance used: counts exact, amounts within 10 units or 1e-4 relative. The comparison found one harness bug (the pre-window window class was fixed to Weekend for Long events); it is fixed and the rows above are from the corrected run. The Python credit simulation in `research/credit_sim.py` uses a different population and the EWMA estimator, so it is not row-comparable; agreement with it is on direction only (fewer losses than the flat control at the same LLTV).
