# UsMarketCalendar - design note (M1)

Status: design note written **before** implementation. A "Findings" section is appended after verification. Decisions D1-D5 and notes N1-N5 are in `DESIGN.md` section 8.

## 1. Purpose

On-chain, pure, O(1) answer to: "when is the Chainlink 24/5 US-equity push feed expected to be blind (no updates), and for how long?" Risk logic uses **blind windows only**; `sessionAt` is for display.

## 2. Time

- UTC seconds in, America/New_York (ET) out; no DST table.
- DST (2007+ US rule): starts **second Sunday of March 02:00 EST = 07:00 UTC**, ends **first Sunday of November 02:00 EDT = 06:00 UTC**. `offset = -4h` in `[start, end)` else `-5h`.
- Civil date <-> day index via Howard Hinnant's days-from-civil / civil-from-days (exact, unsigned for >= 1970). Weekday = `(day + 4) % 7` (0 = Sunday; day 0 = Thursday 1970-01-01).
- Local date of an instant: `floor((ts - offset(ts)) / 86400)`. ET -> UTC for a **date + second-of-day** uses the DST status of that *local date*; this is unambiguous for every time we use (04:00, 09:30, 13:00, 16:00, 20:00) because transitions are at 02:00 local. Repeated hour (fall-back 01:00-02:00) is never an input to a boundary computation; instants inside it get the correct offset because `offset(ts)` is decided in UTC.
- Supported domain: `ts` in `[2020-01-01T00:00Z, 2041-01-01T00:00Z)` (years 2020-2040, UTC), else `OutOfRange`. Windows near the edges may return boundaries just outside the domain (rule evaluation is valid in any year).

## 3. Holidays (rule-based, NYSE)

Source: NYSE "Holidays & Trading Hours" page <https://www.nyse.com/markets/hours-calendars> (2026-2028 lists, fetched 2026-10-02), cross-checked by the independent oracle `research/calendar_oracle.py` (exchange_calendars) for 2024-2035.

| Holiday | Rule | Observed |
|---|---|---|
| New Year's Day | Jan 1 | Sunday -> Monday Jan 2. **Saturday is NOT observed** (Dec 31 stays open); NYSE page: "no New Year's Day holiday is observed" on 2028-01-01 |
| MLK Day | 3rd Monday of Jan | - |
| Washington's Birthday (Presidents' Day) | 3rd Monday of Feb | - |
| Good Friday | Easter Sunday - 2 days, Easter by the Anonymous Gregorian algorithm (bounded arithmetic, only evaluated for March/April) | - |
| Memorial Day | last Monday of May | - |
| Juneteenth | Jun 19, **from 2022** (first NYSE observance) | Sat -> Fri Jun 18, Sun -> Mon Jun 20 |
| Independence Day | Jul 4 | Sat -> Fri Jul 3, Sun -> Mon Jul 5 |
| Labor Day | 1st Monday of Sep | - |
| Thanksgiving | 4th Thursday of Nov | - |
| Christmas | Dec 25 | Sat -> Fri Dec 24, Sun -> Mon Dec 26 |

Not modeled (and why): ad-hoc one-off closures (e.g. 2025-01-09 national day of mourning for President Carter) cannot be derived from rules; they come from the owner-controlled closure bitmap. Pre-2022 Juneteenth is correctly *not* a holiday in 2020-2021.

**Early closes (13:00 ET), informational only** - day after Thanksgiving (Fri); Dec 24 when it is Mon-Thu and not a holiday; Jul 3 when it is Mon-Thu (so Jul 4 is a weekday holiday). NYSE page confirms: 2026-11-27, 2026-12-24, 2027-11-26, 2028-07-03, 2028-11-24. 2026-07-03 and 2027-12-24 are full holidays (observed), not early closes.

## 4. Trading-day model and blind windows (D1, exact)

- Trading day `D` **opens 20:00 ET on calendar day D-1** and **closes 20:00 ET on D**. Weekends and holidays are closed trading days.
- The *slot* of an instant `ts` is `local date of (ts_local + 4h)`: 20:00-24:00 ET belongs to the next calendar day.
- For consecutive **open** trading days `D1 < D2`, the blind window is `[20:00 ET on D1, 20:00 ET on (D2 - 1))`, half-open. `D2 = D1 + 1` -> zero-length, never reported.
- Class by closed calendar days `n = D2 - D1 - 1` (not hours): `1 = Short`, `2 = Weekend`, `>= 3 = Long`. A weekend is 47 h or 49 h across DST.
- `isBlind(ts)` <=> `ts` is in some window <=> the slot of `ts` is a closed day.
- `windowId` = day index of `D1` (the last open trading day before the window). Strictly increasing across windows; stable across calls. For an instant outside a window, `windowId(ts)` returns the id of the *next* window (so it is non-decreasing in `ts`).
- Examples (ET): weekend Fri 20:00 -> Sun 20:00 (Weekend); Labor Day 2026 Fri 20:00 -> Mon 20:00 (Long, n=3); Fri 2026-07-03 holiday Thu 20:00 -> Sun 20:00 (Long, n=3); Wed holiday Tue 20:00 -> Wed 20:00 (Short, 24 h).

### Bounds (no unbounded loops)

- Backward/forward run scans: `MAX_CLOSED_RUN = 14` consecutive closed days (real calendars max out at 3; ad-hoc closures may extend it). Exceeding it reverts `ClosedRunTooLong` (fail closed, never wrong).
- `nextBlindWindow` forward scan: `MAX_SCAN = 21` days, `ScanExceeded` otherwise.
- Easter is straight-line arithmetic (no loop).

## 5. Early-close assumption (D1, UNVERIFIED, one-line config)

Assume **early-close days do not move blind-window boundaries**: the extended session still runs to 20:00 ET. This is **unverified**: the NYSE page says "NYSE American/Arca/National/Texas late trading sessions will close at 5:00 p.m." on early-close days, so the 24/5 feeds *could* pause at 17:00 instead. Config: `UsMarketCalendar.EARLY_CLOSE_WINDOW_SOD = 20 hours` (second-of-day ET at which a window starts when `D1` is an early-close day). Setting it to `17 hours` flips the behaviour; the `*With` entry points take it as a parameter so the flipped path is tested against the Python oracle too. Real evidence arrives with the first early-close days after launch (2026-11-27, 2026-12-24); the feed fixture covers none (launch 2026-07-01).

## 6. Display session (`sessionAt`, display only)

| Our `Session` | ET | Chainlink Data Streams `marketStatus` |
|---|---|---|
| Closed (inside a blind window) | - | 5 Closed |
| PreMarket | 04:00-09:30 | 1 |
| Regular | 09:30-16:00 (09:30-13:00 early close) | 2 |
| PostMarket | 16:00 (13:00 early) - 20:00 | 3 |
| Overnight | 20:00-04:00 (nights belonging to an open trading day) | 4 |
| (unknown) | - | 0 Unknown |

`marketStatus` exists **only in Data Streams v11 reports**, not in the push AggregatorV3 feeds Sundown reads, and halts are not reflected in it. Early-close PostMarket from 13:00 is a display assumption.

## 7. Ad-hoc closure override (wrapper `MarketCalendar`)

- Date bitmap `mapping(uint256 => uint256)`: bit `day % 256` of word `day / 256`.
- Flow: `proposeClosure(day)` (owner) -> event `ClosureProposed(day, eta)` -> after `delay` -> `executeClosure(day)` -> event `ClosureAdded(day)`. `cancelClosure(day)` (owner) before execution. `delay >= 1 day` (constructor).
- **Never shorten or move an announced window.** Closures can only add closed days, so a window can never shorten; but adding a day adjacent to a window could extend/move it. Enforced rule at proposal **and** execution: after adding day `D`, the *resulting* window containing `D` must start more than `ANNOUNCE_LEAD = 72 h` in the future. Consequences: past dates rejected; a closure that would extend or move any window whose start is within 72 h is rejected; far-future closures accepted (including ones that extend not-yet-announced windows).
- Also rejected: already-closed day, a closure that creates a closed run longer than `MAX_CLOSED_RUN`, days outside the supported range.
- Library takes the closure bitmap as an internal function pointer `function(uint256) view returns (bool)`, so the library stays stateless.

## 8. API

Library (all `internal`, NatSpec'd): `isTradingDay`, `tradingDayOpen`, `tradingDayClose`, `regularOpen`, `regularClose`, `isEarlyClose`, `blindWindowAt`, `nextBlindWindow`, `windowId`, `windowIdOfStart`, `secondsUntilBlind`, `isBlind`, `sessionAt`, `marketStatusOf`, plus `*With(..., earlySod, adHoc)` generic forms. Wrapper `MarketCalendar`: external views over the same plus the closure flow.

## 9. Verification plan

1. `research/calendar_oracle.py` (exchange_calendars XNYS + zoneinfo) -> `contracts/test/fixtures/calendar_cases.json`: every window 2024-2035 (start/end/class/id), trading-day opens/closes, DST transitions +/- 1 s, holidays, early closes, 20,000 random timestamps (isBlind, windowId, class, session). Foundry asserts equality on all.
2. `research/observed_rounds.py` -> `contracts/test/fixtures/observed_feed_updates.json` (full proxy round history, all phases, `getRoundData`, 4 feeds on chain 4663); test: no update strictly inside a predicted window; report: lag from window end to first update; violations are findings.
3. Named tests, property/fuzz tests, coverage >= 100 % line / > 95 % branch, gas per function.

---

# Findings (written after verification, 2026-10-02)

## 10. Differential result (contract vs independent oracle)

Oracle: `exchange_calendars` 4.13.2 (XNYS) + `zoneinfo`; window model derived from the oracle's *session list*, not from the Solidity algorithm.

| Check | Cases | Result |
|---|---|---|
| Window chain via `nextBlindWindow` (start, end, class, id) | 661 windows 2024-2035 | all equal, no extra/missing windows |
| `isTradingDay` for every calendar day | 4,383 days | all equal |
| Trading-day open/close, regular open/close (incl. 13:00 early closes) | 3,012 sessions | all equal |
| `isEarlyClose` | every session; 27 early closes | all equal |
| Weekday closures | 119 (incl. 1 ad-hoc) | all closed |
| DST offsets at transition -1 s / 0 / +1 s, 2020-2040 | 126 | all equal |
| Random timestamps (isBlind, windowId, class, session) | 20,000 | all equal |
| Window edges +/-1 s | 2,644 | all equal |
| Rules-only API (no ad-hoc function) | 19k+ random rows away from 2025-01-09 | all equal |

**Disagreements between contract and oracle: exactly one, a genuine ambiguity, not a bug.** 2025-01-09 (national day of mourning for President Carter) is in `exchange_calendars` as an ad-hoc holiday and cannot be derived from rules. Rules-only evaluation says "open" (asserted by `test_ruleOnlyCalendarMissesAdHocClosure`); the differential suite supplies it through the ad-hoc closure function, exactly as production would via `MarketCalendar`. No other date differs.

**Primary-source cross-check.** The NYSE page <https://www.nyse.com/markets/hours-calendars> (fetched 2026-10-02) lists 29 holidays for 2026-2028 and early closes 2026-11-27, 2026-12-24, 2027-11-26, 2028-07-03, 2028-11-24; the fixture contains exactly those 29 holidays (no extras) and those 5 early closes, and Jan 1 2028 (Saturday) is *not* observed. Rules beyond 2028 rest on exchange_calendars and the stated NYSE rules, not on a NYSE-published list (unverified against a primary source for 2029-2040). Not done: a second library (`pandas_market_calendars`) cross-check.

**A bug caught during M1** (before any test ran): while generating independent UTC constants I found the library's `MAX_TS` was `2_208_988_800` (2040-01-01) instead of `2_240_611_200` (2041-01-01). Fixed; `test_rangeBoundaries` now pins both bounds with Python-derived values.

**Mutation sanity check** (scratch copy, not committed): 11 hand-made rule mutants (Juneteenth year gate, New Year Sunday observance, Saturday New Year observed, Thanksgiving early close, Good Friday/Easter constant, Christmas Saturday, Memorial Day, DST start week, DST end hour, class threshold, window-end off-by-one) were each **killed** by the suite; the unmutated baseline passed.

## 11. Empirical consistency against real Chainlink feeds (decision D1 caveat)

Method: `research/observed_rounds.py` walked every proxy phase with `getRoundData` (no archive) for **SPY, TSLA, NVDA, AAPL, QQQ, MSFT** on Robinhood mainnet (chain 4663), head block 78,504,251 (2026-10-02 20:06Z). Fixture: `contracts/test/fixtures/observed_feed_updates.json` (on-chain data). Test: `ObservedFeed.t.sol`; report: `research/feed_consistency_report.py`.

| Feed | Rounds | Phases | Span (first -> last update) |
|---|---|---|---|
| SPY | 154 | 1 | 2026-06-22 00:00Z -> 2026-10-02 12:30Z |
| TSLA | 1,446 | 1 | -> 2026-10-02 19:55Z |
| NVDA | 1,162 | 1 | -> 17:07Z |
| AAPL | 700 | 1 | -> 16:39Z |
| QQQ | 401 | 1 | -> 12:57Z |
| MSFT | 853 | 1 | -> 19:57Z |

- (a) **Violations: 0.** Of 4,716 observed updates, none has `updatedAt` strictly inside a predicted blind window, and none sits exactly at a window start. The test is sensitive on the *end* side: first updates arrive 18-85 s after the predicted end, so a model whose end was late by a minute would be flagged.
- (b) **Lag between window end and first update**: all 84 (window, feed) pairs: min 18 s, mean ~30-41 s per feed, max 85 s (TSLA). The 0.5 % deviation / 24 h heartbeat rule did **not** delay the first post-window update in any observed window: the feeds publish at the session open regardless of deviation. (Relevant to carry-forward note N2; the censoring concern is *not observed* in 14 windows x 6 feeds; it can still occur on a quiet opening, so the model must record the lag.)
- **Coverage (be precise):** 14 windows have both a last-before and a first-after update: **12 Weekend + 2 Long holiday windows (Fri 2026-07-03 Independence Day observed; Mon 2026-09-07 Labor Day), 0 Short**. The feed history starts Mon 2026-06-22 00:00Z, i.e. *after* the Juneteenth window (Fri 2026-06-19), so Juneteenth is not covered. This is **not** the "~13 weekends + 2 holidays" assumed in D1; the fixtures show 12 + 2.
- What the evidence does **not** constrain: (1) the window **start** is only bounded from one side. The last update before a window sits 0.25-19.5 h before the predicted start (median 4-9 h per feed), so the data show only that nothing is published *after* the predicted start, not that the feed actually stops at 20:00 ET. (2) All 14 windows lie in daylight time (EDT): **EST is unobserved** (first chance: Sun 2026-11-01 fall back, then Thanksgiving 2026-11-26). (3) **Early-close days: no observation** (first chance 2026-11-27, 2026-12-24). (4) No Short (mid-week holiday) window observed.
- Findings reported, nothing patched: no violations were found.

## 12. Verification summary

- `forge test`: **60 passed, 0 failed**: 30 named, 8 differential (incl. rules-only), 7 property/fuzz (256 runs each, incl. the gas report), 13 wrapper (incl. 1 fuzz), 2 observed-feed. `forge fmt --check`, `forge build --sizes` and `ruff check` are clean; `.gas-snapshot` holds the 52 non-fuzz entries (CI checks it with `--no-match-test testFuzz`). Deployed sizes: `MarketCalendar` 6,855 B runtime (library is inlined).
- Coverage (`forge coverage --ir-minimum`): `src/lib/UsMarketCalendar.sol` **100 % lines / 100 % statements / 100 % branches / 100 % functions**; `src/MarketCalendar.sol` **100 % / 100 % / 100 % / 100 %**. (Foundry's `--ir-minimum` mode, needed because the library hits "stack too deep" under unoptimised coverage builds, can mis-attribute lines; one such attribution glitch on `_classOf` was resolved by simplifying the function.)
- Gas (from `test_gasReport`, includes ~2.6k external-call overhead from the harness). All lookups are O(1) apart from bounded scans.

| Function | Gas (typical) | Worst case (12-day closed run) |
|---|---|---|
| `isTradingDay` | 11.7k | - |
| `isEarlyClose` | 14.0k | - |
| `tradingDayClose` | 19.0k | - |
| `isBlind` (open / blind) | 19.4k / 44.1k | - |
| `blindWindowAt` (blind) | 40.6k | 116.2k |
| `sessionAt` | 36.1k | - |
| `windowId` | 67.4k | 89.0k |
| `nextBlindWindow` | 75.8k | - |
| `secondsUntilBlind` | 80.2k | 151.4k |

The hard bounds are `MAX_CLOSED_RUN = 14` days per direction (`ClosedRunTooLong`) and `MAX_SCAN = 21` days (`ScanExceeded`); both revert fail-closed and are covered by tests. Hot-path callers should cache `windowId`/window bounds rather than call `secondsUntilBlind` per action.

## 13. Remaining unverified / assumptions

1. **Early-close days do not move window boundaries (UNVERIFIED).** Config constant `EARLY_CLOSE_WINDOW_SOD`; flipped behavior is tested against hand-derived expectations. The NYSE page says late trading sessions on early-close days close at 17:00, so the feed may pause earlier.
2. EST (winter) and early-close behavior of the real feeds: unobserved.
3. Start-of-window behavior (when the feed actually stops): only a one-sided bound.
4. Holiday rules 2029-2040 not checked against a NYSE-published list.
5. `sessionAt` post-market on early-close days (from 13:00) is a display assumption; the display session is never used for risk.
6. Chainlink `marketStatus` is not available in the push feeds; the mapping in section 6 is documentation only.
7. Two-library cross-check (`pandas_market_calendars`) not performed.
