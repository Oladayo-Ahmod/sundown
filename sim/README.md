# sim/

Simulations and replays. **Everything here is a simulation**: price paths come from `SimEquityFeed` (keeper-published, `IS_SIMULATION = true`) or from replayed historical data, and nothing is presented as a live integration.

| File | What it is |
|---|---|
| `SimEquityFeed.sol` | AggregatorV3-shaped simulated feed (8 decimals). SIMULATION ONLY |
| `replay_events.json` | Excerpt of the worst real daily gaps (previous close to next open, split-adjusted), from `research/` |
| `prepare_replay.py` | Derives `replay_inputs.json` (integers only) from the events and the exit-liquidity snapshot |
| `replay_inputs.json` | Top K (10) worst AAPL and SPY events plus the aggregate v3 depth table; derived, deterministic |
| `ReplayHarness.sol` | The on-chain replay (abstract; run by `contracts/test/Replay.t.sol`) |
| `compare_replay.py` | Compares the harness output to `research/replay_reference.py` (exact-integer re-implementation) |

## Replay (D25, D26, D29)

Per event and per tier (93 % and 90 %), three markets from the same implementation share one oracle stack (`SimEquityFeed` -> production `ChainlinkEquityOracle`) and one deterministic leverage-seeking population (20 borrowers, 50 tokens at $100 each, debt 80-99 % of the tier cap):

- **control**: `FlatGuard` at the boosted LLTV (a conventional market that keeps using the frozen price);
- **sundown**: `SundownGuard` with the D26 through-the-cycle `gapVaR` (session-aware LLTV: boosted weekday capacity, tighter weekend capacity);
- **standard**: `FlatGuard` at the standard LLTV (86 %).

Timeline: borrow at `S - 12 h`; the keeper (this contract) deleverages every eligible session-aware account when the zone opens (`S - 6 h + 3 h`); the window starts (feed quiet); at `S + W` the feed reopens at the gapped price; the keeper liquidates everything unhealthy (up to 5 rounds) and bad debt is realized. Output per market: lender loss (realized bad debt), ordinary liquidations, deleverage calls and amounts, weekday and in-window borrow capacity, and the keeper break-even fee (slippage from the depth table plus gas).

Run: `python sim/prepare_replay.py`, then `cd contracts && forge test --match-test test_replayPrintsResults -vv > /tmp/sol.log`, `cd research && python replay_reference.py > /tmp/ref.csv`, `python sim/compare_replay.py /tmp/sol.log /tmp/ref.csv`.

## Limits (read before quoting any number)

- The harness runs in forge's in-process EVM (the same engine anvil runs), not an anvil process; time moves with `vm.warp`. Nothing is broadcast to any network.
- Blind windows are a window-cache fixture placed at synthetic times with the event's class and length, because the on-chain calendar library accepts 2020-2040 but is differentially validated against the independent oracle only for 2024-2035, and most of the worst events are older or fall in the unvalidated 2020-2023 range. The oracle, market and guard are the production contracts.
- Prices are daily previous-close to next-open gaps (a conservative superset of the oracle-blind exposure), applied as one gap at reopen; no intraday path, no slippage on liquidation, no keeper competition.
- The borrower population is a modelling choice (leverage-seeking, 20 accounts); lender loss scales with it. No borrower cures during the cure window (the conservative case for the mechanism).
- Gas cost per deleverage transaction is an assumption (`GAS_USD_PER_TX`), not a measurement.
- The keeper is this script. A production keeper service is out of scope.
