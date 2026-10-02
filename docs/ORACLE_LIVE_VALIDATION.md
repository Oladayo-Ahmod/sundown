# ChainlinkEquityOracle: validation against the real Chainlink feeds

**Result:** the production `ChainlinkEquityOracle` was run, unmodified and with nothing mocked, against the real Chainlink tokenized-equity feeds for SPY, AAPL, NVDA and TSLA on Robinhood Chain mainnet (chain 4663), read at the latest block through the public RPC `https://rpc.mainnet.chain.robinhood.com`. Tests: `contracts/test/OracleForkLive.t.sol` (new) and `contracts/test/OracleFork.t.sol` (existing), skipped unless `ROBINHOOD_MAINNET_RPC_URL` is set. Run: `ROBINHOOD_MAINNET_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract 'OracleForkLiveTest|OracleForkTest' -vv` (4 passed, 0 failed, 0 skipped). Without the variable the new tests skip (verified). Addresses come from `deployments/robinhood-mainnet.json`.

Recorded run: `block.timestamp` 1791054971 (2026-10-03 19:16:11 UTC). RPC reliability on the same day: 12 of 12 `eth_blockNumber` calls succeeded.

## Live values

| Asset | Feed description | Raw answer (8 decimals) | priceWad (USD) | updatedAt (UTC) | Age at read | Adapter status |
|---|---|---|---|---|---|---|
| SPY | RHSPY / USD | 77071210575 | 770.712105750000000000 | 1790944238 (2026-10-02 12:30:38) | 110,733 s | ScheduledBlind |
| AAPL | Robinhood AAPL / USD | 33382386412 | 333.823864120000000000 | 1790959180 (2026-10-02 16:39:40) | 95,791 s | ScheduledBlind |
| NVDA | RHNVDA / USD | 23499711907 | 234.997119070000000000 | 1790960852 (2026-10-02 17:07:32) | 94,119 s | ScheduledBlind |
| TSLA | RHTSLA / USD | 37044800000 | 370.448000000000000000 | 1790970931 (2026-10-02 19:35:31) | 84,040 s | ScheduledBlind |

Calendar at that block (read directly from `MarketCalendar`): inside a blind window, class Weekend, start 1790985600 (Fri 2026-10-02 20:00 ET) and end 1791158400 (Sun 2026-10-04 20:00 ET).

## What the run proves

1. **Decimals normalization.** Every live feed reports 8 decimals; the adapter's scale is 1e10; `priceWad` equals the raw answer times 1e10 exactly, and the adapter reports the feed's own `updatedAt`. Each feed's `description()` names the asset it is wired to.
2. **Blindness classification at the current block, against the calendar.** The calendar says the market is inside a Weekend window; the adapter reports `ScheduledBlind` for all four assets, with the haircut equal to the deviation allowance only. The ages (23 to 31 hours) would exceed the 25 h heartbeat budget outside a window; inside it they are classed as scheduled blindness, not `Stale`. None of the four feeds updated inside the window: the last updates were 4.1 to 11.5 hours before the window start. This is a single observation, consistent with the D1 model, not a statistical claim.
3. **Rejection of a wrong feed address**, each by a different mechanism: an address with no code reverts at construction; a real contract that is not a feed (USDG) and the stock token used as a feed construct and then report `Invalid` with price 0; another asset's real feed (SPY, about 770 USD) wired to AAPL's configuration with price bounds 200-500 USD is `Invalid`, while AAPL's own feed with the same bounds is accepted.

## What it does not prove (limits)

- **No on-chain asset-identity check.** A wrong feed whose price lies inside the configured bounds is accepted. The bounds must bracket the asset's real range, and the deployer must check the feed description (the test does so off-chain).
- **Only the blind branch was exercised on real data**, because the market was inside a window. The `Fresh`, `Stale` and `Reopening` branches are asserted structurally by the test but were not hit; they are covered by the unit tests with mock feeds (`contracts/test/Oracle.t.sol`), not by live data. Reopening behavior on real feeds (the first update after a window) needs a run after the window ends.
- **Corporate-action detection** was checked only in the sense that no corporate action was pending on the four real tokens (existing test); the real `oraclePaused` and multiplier fields were readable, no pending change was live.
- **No Sundown market is deployed on Robinhood Chain.** This is read-only validation of the adapter (D15). The Arbitrum Sepolia demonstration uses simulated feeds.
