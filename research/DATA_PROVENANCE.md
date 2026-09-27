# Data provenance (M2)

| Item | Value |
|---|---|
| Source | Yahoo Finance via `yfinance` 1.7.0 (free, unofficial API; research use). **Single source**: Stooq now requires a JavaScript bot check and could not be used for cross-validation |
| Retrieved | 2026-10-02 (UTC), daily history from 2010-01-01; the in-progress 2026-10-02 session is dropped, so data ends 2026-10-01 |
| Instruments | AAPL, NVDA, TSLA, SPY, QQQ, MSFT, AMZN, GOOGL, META (from 2012-05-18), JPM, XOM, WMT. TSLA from 2010-06-29 |
| Price basis | **Split-adjusted, not dividend-adjusted** (`auto_adjust=False`, columns `Open`/`Close`) |
| Calendar | `exchange_calendars` 4.13.2, `XNYS` (sessions, early closes), window arithmetic with `zoneinfo` America/New_York |
| Raw files | `research/data/raw/` - **git-ignored**, never committed. `manifest.json` records row counts, date ranges and SHA-256 of each raw file |
| Committed | `research/data/derived/<TICKER>.csv`: per consecutive-session pair, **returns only** (gap/open-to-close in bps, class, ex-dividend flag), no prices; `manifest.json`; `replay_prices.json` (prev close and open for the ~50 replay events only) |
| Reproduce | `make data` (network; Yahoo may revise history, so a re-download can differ slightly from the committed snapshot), then `make backtest` (offline) |

## Why not dividend-adjusted

The exposure is the move of the quoted price across a closed window. A dividend back-adjustment multiplies old prices by a ratio that never traded and mixes an accounting correction into every historical gap. Ex-dividend days are handled explicitly instead: the primary gap includes the ex-date drop (conservative); `gap_divneutral_bps` adds the cash dividend back. Stock tokens accrue dividends into `uiMultiplier` (DISCOVERY.md b), so the token-level drop is smaller than the share drop; the *timing* of that multiplier update against the feed is **unverified**. Effect on the 99% blind-window loss quantile is zero to the basis point for the deployed subset (`results/dividend_sensitivity.csv`: 8 ex-dividend windows out of 914 for AAPL, 1 for NVDA/SPY, 0 for TSLA).

## Quality checks (all in `derived/manifest.json`)

- Per ticker: 1 pair dropped (the first session has no predecessor in the data), 0 non-session rows, 0 invalid OHLC rows, 0 gaps larger than 40 % in absolute value flagged.
- Spot checks of the largest events against known history: NVDA 2018-11-16 (earnings), NVDA 2019-01-28 (pre-announcement), META 2022-02-03 / 2022-10-27 (earnings), TSLA 2020-09-08, JPM/TSLA 2020-03-09 and 2020-03-16. These match my recollection of the events but were **not** cross-checked against a second vendor.

## Intraday subset

Hourly bars incl. pre/post market for the last ~730 days (Yahoo limit), 2024-10-04 .. 2026-09-28, 12 assets, 1,344 blind windows. Coverage is 04:00-20:00 ET only; the 20:00-04:00 overnight session that the real 24/5 feed sees is **not** available. Raw bars are git-ignored; `results/intraday_windows.csv` and `intraday_summary.json` are the committed snapshot (the window rolls, so re-running later gives different numbers).

## Not covered

No on-chain feed data was used (no archive key, per D4); the proxy-vs-true-feed comparison on the 13 weekends since launch is left to M1's feed-consistency test.
