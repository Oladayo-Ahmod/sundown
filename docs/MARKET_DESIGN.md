# Sundown Market Design (M3 step 3a)

Status: **design only, no contract code**. Written for approval before step 3b. Everything here is a proposal unless it cites evidence; evidence tags follow `DISCOVERY.md` (**[V]** verified on chain or from a primary source in this project, **[D]** documented, **[S]** secondary, **[U]** unverified). Binding inputs: decisions D1-D11 and notes N1-N5 in `DESIGN.md` section 8; M1 (`UsMarketCalendar`, `MarketCalendar`); the M2/M2.1 research (`research/CLAIMS.md`).

Honest scope statement (D6): this market is infrastructure for a *measured* claim. At real LLTVs <= 86 % the session-aware rule is not distinguishable from zero; the market must therefore be a clean, small, auditable lending core whose guard is swappable, so the control (flat) and treatment (session-aware) markets differ **only** by the guard and the replay can say what the guard is worth. Everything session-related lives behind `IRiskGuard`; the market contains **no session logic**.

## 1. Scope and non-scope

In scope (this milestone): isolated market, one collateral token, one loan token; ERC-4626 supply vault; per-user collateral and debt shares; kinked, per-second compounding rate; lazy accrual; partial liquidation; explicit bad-debt realization; per-market collateral cap; issuer-control halt policy (D2); oracle adapter with calendar-aware freshness (N1); `IRiskGuard` with the `FlatGuard` control; mocks and a `Sim*` feed.

Out of scope (extension points only): protocol fee / reserve factor; loss-absorbing reserve (D8, claim 13: a premium-funded reserve cannot self-start); borrow delegation/authorizations; flash loans; multiple collateral; upgradeability; governance token; the `SundownGuard` itself (M4a, after the M2.2 results); the Stylus experiments (M8, optional).

## 2. Components and trust labels

| Path | What | Class |
|---|---|---|
| `contracts/src/SundownMarketFactory.sol` | ERC-1167 factory, registry of markets | production |
| `contracts/src/SundownMarket.sol` | clone implementation: vault + positions + liquidation + halt | production |
| `contracts/src/interfaces/{IRiskGuard,IEquityOracle,IWindowCache,ISundownMarket}.sol` | interfaces | production |
| `contracts/src/guards/FlatGuard.sol` | control guard: static LTV/LLTV, flat bonus | production (control) |
| `contracts/src/oracle/ChainlinkEquityOracle.sol` | production oracle path; claimed "integrated" only after a fork test against real feeds | production (not yet validated) |
| `contracts/src/oracle/WindowCache.sol` | cached window state over `MarketCalendar` (D11) | production |
| `contracts/src/lib/{KinkedRate,SharesMath}.sol` | rate and shares math | production |
| `contracts/src/lib/UsMarketCalendar.sol`, `MarketCalendar.sol` | M1, unchanged | production |
| `contracts/test/mocks/{MockEquityOracle,MockStockToken,Malicious*}.sol` | configurable test doubles | test fixture |
| `sim/SimEquityFeed.sol` | AggregatorV3-shaped simulated feed driven by replay data | **simulation, labeled `Sim*`** |

New dependency (needs approval, decision A1): `openzeppelin-contracts-upgradeable` v5.7.0, pinned like the others, **only** for `ERC4626Upgradeable`/`ERC20Upgradeable`/`Initializable` (ERC-7201 namespaced storage, safe for ERC-1167 clones). Not used for any upgradeability. `ReentrancyGuardTransient` (non-upgradeable lib, cancun `TSTORE` verified on all target chains [V]) needs no initializer.

## 3. Parameters (immutable after `initialize`)

```solidity
struct MarketParams {
    address collateralToken;     // 18 decimals expected, read at init
    address loanToken;           // 6 decimals (USDG) expected, read at init; assumed exactly 1 USD (D3)
    address oracle;              // IEquityOracle for collateralToken, priced in USD
    address guard;               // IRiskGuard
    address guardian;            // may halt (and resume within the freeze limit)
    address governance;          // timelock: resume after the freeze limit, optional wind-down
    uint64  lltvWad;             // hard liquidation threshold; also the base-solvency bound for any guard
    uint64  closeFactorWad;      // 0.5e18: max share of debt repaid per liquidation
    uint64  criticalHealthWad;   // below this health factor the close factor is 100 % (e.g. 0.95e18)
    uint64  maxBonusWad;         // hard cap on any guard-provided bonus (e.g. 0.15e18)
    uint128 collateralCap;       // max total collateral, in collateral-token units (section 12)
    uint128 minDebt;             // dust floor in loan units: a position may not be left with 0 < debt < minDebt
    uint64  baseAprWad;          // IRM: APR at 0 % utilization
    uint64  slope1AprWad;        // IRM: added APR from 0 % to kink
    uint64  slope2AprWad;        // IRM: added APR from kink to 100 %
    uint64  kinkWad;             // IRM kink utilization
    string  shareName;           // ERC-20 metadata of the vault share
    string  shareSymbol;
}
```

Validated by the factory: non-zero addresses; `collateralToken != loanToken`; decimals <= 18 each; `0 < lltvWad <= 0.98e18`; `0 < closeFactorWad <= 1e18`; `criticalHealthWad < 1e18`; `maxBonusWad <= 0.25e18`; `0 < kinkWad < 1e18`; `collateralCap > 0`. A configuration where a full-bonus liquidation of an LLTV-edge position exhausts the collateral is allowed; section 7.5 handles it explicitly. Guardian and governance addresses are immutable (no setter).

Placeholder values (unvalidated, to be set from research in 3b): IRM kink 80 %, base 0 %, slope1 4 % APR, slope2 75 % APR; `closeFactor` 50 %; `criticalHealth` 0.95; control markets at the in-the-wild LLTVs (N5): Morpho 62.5 / 77 / 86 % and a 5.5 % flat bonus (the Aave maximum, **[S]**).

## 4. Interfaces

### 4.1 Oracle

```solidity
enum PriceStatus { Fresh, ScheduledBlind, Reopening, Stale, Invalid, CorporateAction, SequencerDown }

struct PriceData {
    uint256 priceWad;     // USD per 1 whole collateral token, 1e18 scale, multiplier already included by the feed
    uint64  updatedAt;    // feed updatedAt
    uint64  windowId;     // id of the current or next blind window (D11 cache), 0 if unknown
    uint256 haircutWad;   // fraction (1e18 = 100 %) the guard may subtract: deviation allowance + age haircut (N1)
    PriceStatus status;
}

interface IEquityOracle {
    function price() external returns (PriceData memory);     // may refresh the window cache; used by the market
    function peek() external view returns (PriceData memory); // uncached; for UIs and tests
}
```

Status semantics (N1):

| Status | Meaning | Calendar | Market-level rule |
|---|---|---|---|
| `Fresh` | valid answer, updated recently enough for the session | live | all actions per guard |
| `ScheduledBlind` | calendar says the feed is in a blind window; price is the last published | blind | guard decides (the control ignores it, as Aave/Morpho do) |
| `Reopening` | calendar says live again but `updatedAt` predates the last window end (first post-window update not yet seen; observed lag was 18-85 s [V, M1]) | live | guard decides |
| `Stale` | live per calendar but `age > maxAge` (heartbeat 24 h + grace): **unscheduled blindness** | live | guard decides |
| `Invalid` | `answer <= 0`, incomplete round, outside absolute bounds, `updatedAt > now`, decimals error | any | **market reverts** borrow, collateral withdrawal with debt, liquidation |
| `CorporateAction` | `token.oraclePaused()` or a pending multiplier change (`newUIMultiplier != uiMultiplier` and `effectiveAt` near) | any | **market reverts** the same actions (price unfair either way) |
| `SequencerDown` | optional sequencer feed reports down, or within its grace period after recovery (N3) | any | **market reverts** the same actions |

`Invalid`, `CorporateAction`, `SequencerDown` are the only states in which the **market itself** refuses to act on the price; every other state is passed to the guard through the context. Repay, vault deposit/withdraw/redeem, collateral deposit and `realizeBadDebt` never read the oracle; withdrawing collateral with zero debt never reads it.

### 4.2 Guard

```solidity
struct AccountCtx {
    address account;
    uint256 collateral;        // effective collateral units (after any shortfall scale, section 8.3)
    uint256 debtAssets;        // debt in loan units, rounded UP (the state *after* the proposed action for borrow/withdraw)
    uint256 priceWad;
    uint256 haircutWad;
    uint64  updatedAt;
    uint64  windowId;
    PriceStatus status;
    uint256 lltvWad;           // the market's hard threshold
    uint256 totalBorrowAssets;
    uint256 totalAssets;
    uint256 collateralValue;   // collateral * price in loan units, rounded DOWN (no haircut applied)
}

interface IRiskGuard {
    /// Max total debt (loan units) this account may hold now. Used after borrow and withdrawCollateral.
    function maxBorrowable(AccountCtx calldata c) external view returns (uint256);
    /// Whether this account may be liquidated now (the market has already required debt > 0 and a usable price).
    function liquidationAllowed(AccountCtx calldata c) external view returns (bool);
    /// Bonus (WAD) for repaying `repayAssets` now. The market caps it (section 7.5).
    function liquidationBonus(AccountCtx calldata c, uint256 repayAssets) external view returns (uint256);
    /// Market-only hooks (revert-capable). Used by stateful guards for tiers/cure windows; no-ops in FlatGuard.
    function onBorrow(AccountCtx calldata c, uint256 borrowed) external;
    function onLiquidate(AccountCtx calldata c, address liquidator, uint256 repaid, uint256 seized) external;
}
```

The market passes **account-level context** so a standard/boosted tier, a cure window or a per-account opt-in can live entirely inside a stateful guard (M4a) without touching the market. The market contains no session logic: it never reads a calendar, a window id or a session; it only forwards what the oracle returned.

**Guard trust model (decision A4).** The guard address is fixed at creation by governance and the factory owner only creates markets with reviewed guards. The market treats the guard as trusted for *policy* (how much may be borrowed, when a position may be liquidated, what bonus) and enforces *bounds* regardless: a guard can only **reduce** borrow capacity, because the market enforces `min(guard.maxBorrowable, collateralValue * lltv / WAD)`; a guard-authorized liquidation of an account that is still healthy at `lltv` (the boosted-tier cure/deleveraging path) is bounded by the close factor, the bonus cap and the non-worsening rule (7.5), and requires `liquidationAllowed`. A malicious or buggy guard therefore can freeze borrowing and can trigger bounded, bonus-capped liquidations, but cannot move funds to itself, mint shares, change debt arithmetic or seize more than the bounds permit. This residual power is the price of keeping the boosted tier outside the market and is a threat-model item (section 14).

**`FlatGuard` (control, N5).** Immutable `ltvWad <= lltvWad` and `bonusWad`: `maxBorrowable = collateralValue * ltvWad / WAD` (round down); `liquidationAllowed = (debtAssets > collateralValue * lltvWad / WAD)`; `liquidationBonus = bonusWad`; hooks no-op and `msg.sender == market` guarded. It ignores `status`, `haircutWad` and `windowId`, exactly like a conventional market with a frozen oracle: this is what the control must be.

### 4.3 Window cache (D11)

```solidity
struct WindowState { bool blind; uint64 windowId; uint64 start; uint64 end; uint64 lastEnd; uint8 cls; }
interface IWindowCache {
    function state() external returns (WindowState memory);      // refreshes when stale; state-changing
    function peek() external view returns (WindowState memory);  // computes without writing
}
```

One shared instance per chain wraps a `MarketCalendar` and caches `(current-or-next window, windowId, class, lastEnd)` with a TTL of 24 h, **below** the 72 h `ANNOUNCE_LEAD` and 24 h minimum closure delay of `MarketCalendar`, so any ad-hoc closure that becomes effective is picked up before the window it creates can start (argument: a closure executed at `t1` yields a new window starting after `t1 + 72 h`; the cache is refreshed at most 24 h later). `state()` on a warm cache costs two `SLOAD`s; a refresh pays the `nextBlindWindow` scan (75.8k gas, worst case 151k [V, M1]) once per window instead of per action. Both the oracle adapter and guards read it; neither calls `secondsUntilBlind`/`nextBlindWindow` per user action.

### 4.4 Market

```solidity
interface ISundownMarket /* is IERC4626 */ {
    // positions
    function depositCollateral(uint256 amount, address onBehalf) external;
    function withdrawCollateral(uint256 amount, address receiver) external;
    function borrow(uint256 assets, address receiver) external returns (uint256 shares);
    function repay(uint256 assets, address onBehalf) external returns (uint256 sharesBurned);
    function repayShares(uint256 shares, address onBehalf) external returns (uint256 assetsPaid);
    function liquidate(address borrower, uint256 repayAssets, address receiver) external returns (uint256 repaid, uint256 seized);
    function realizeBadDebt(address borrower) external returns (uint256 written);
    function accrue() external;

    // issuer-control policy (section 8)
    function reportIssuerFailure() external returns (HaltReason);   // permissionless probe
    function guardianHalt() external;
    function resume() external;                                     // guardian within the freeze limit if probes pass; governance after it
    function windDown() external;                                   // governance only, after the freeze limit (A9)
    function reconcileCollateral() external;                        // permissionless, only in CollateralShortfall (A5)

    // views
    function debtOf(address) external view returns (uint256);            // rounded up, with pending interest
    function collateralOf(address) external view returns (uint256);      // effective units
    function marketState() external view returns (MarketState memory);
    function healthFactor(address) external returns (uint256);           // WAD; uses oracle.price()
}
```

Single contract is both the vault and the market (decision A2): fewer trust boundaries, one accounting domain, no vault/market desync. Borrow delegation (`onBehalf` for `borrow`/`withdrawCollateral`) is **not** provided: only `msg.sender` can borrow or withdraw their own collateral; `repay` and `depositCollateral` are for anyone on behalf of anyone.

## 5. State machine

Market states (one storage word):

```
                 deploy+initialize
                        |
                        v
   +---------+  guardianHalt()                                 +-----------+
   | Active  | ---------------------------------------------> |  Halted   |
   |         | <--- resume() (guardian, probes pass, <= 30 d)  | reason,   |
   |         |      resume() (governance, any time)            | haltedAt  |
   +---------+ --- reportIssuerFailure(): a probe fails -----> +-----------+
                                                                     | after MAX_FREEZE (30 d), governance only
                                                                     v
                                                               +-----------+
                                                               | WindDown  | terminal: no new borrow/supply,
                                                               +-----------+ accrual resumes; repay, liquidate,
                                                                              lender exits stay open
```

What each state permits (token transfers permitting; a reverting token reverts the action naturally):

| Action | Active | Halted | WindDown |
|---|---|---|---|
| `deposit`/`mint` (lenders) | yes | **no** | no |
| `withdraw`/`redeem` (up to idle) | yes | yes | yes |
| `depositCollateral` | yes (cap) | yes (cap) | yes |
| `withdrawCollateral` | yes | **no** | with zero debt only |
| `borrow` | yes | **no** | no |
| `repay`, `repayShares` | yes | **yes (never blocked)** | yes |
| `liquidate` | yes | **yes** (no halt gate; reverts only if the token reverts or the oracle is Invalid/CorporateAction/SequencerDown) | yes |
| `realizeBadDebt` | yes | yes | yes |
| interest accrual | yes | **frozen** | resumes |

Position states (derived, not stored): `NoDebt` -> `Healthy` (debt <= guard capacity) -> `Liquidatable` (guard says so) -> `Insolvent` (collateral value < debt) -> `BadDebt` (collateral 0, debt > 0) -> `realizeBadDebt` -> `NoDebt` (loss socialized to the vault share price, evented).

## 6. Units and arithmetic

- `WAD = 1e18`. Prices are USD per whole collateral token in WAD. The loan token is exactly 1 USD (D3). `cDec`, `lDec` are read from the tokens at `initialize` and stored.
- **Collateral value in loan units:** `value(c) = floor(c * priceWad / S)`, `S = 10^(cDec + 18 - lDec)` (`1e30` for 18/6 decimals). Rounds **down**.
- **Debt:** `debt(user) = ceil(shares * (totalBorrowAssets + VIRTUAL_ASSETS) / (totalBorrowShares + VIRTUAL_SHARES))`, `VIRTUAL_SHARES = 1e6`, `VIRTUAL_ASSETS = 1`. Rounds **up**.
- **Shares:** `shares = assets * (totalBorrowShares + 1e6) / (totalBorrowAssets + 1)` rounded **up** when borrowing (borrower owes slightly more), rounded **down** when repaying by assets (fewer shares burned), assets rounded **up** when repaying by shares. Liquidation burns shares rounded down.
- **Rates:** per-second `rate = apr / 365 days`; compounding by a 3-term Taylor expansion `x + x^2/2 + x^3/6` of `exp(rate * elapsed) - 1` (as Morpho's `wTaylorCompounded`, error bounded and measured in the Python reference), interest rounded **up**; utilization `u = totalBorrowAssets / (idle + totalBorrowAssets)` (0 if both are 0); APR = `base + slope1 * min(u,kink)/kink + slope2 * max(0, u-kink)/(1-kink)`.
- **Vault:** OpenZeppelin v5 `ERC4626Upgradeable` with `_decimalsOffset() = 6` (virtual shares 1e6, virtual assets 1). `totalAssets() = idle + totalBorrowAssets` from **internal ledgers**; tokens sent directly to the market are never credited (donations cannot move the share price and are not recoverable; documented).
- **Rounding summary (always against the user, for the protocol):** deposit shares down, mint assets up, withdraw shares up, redeem assets down (OZ defaults); collateral value down; debt up; seized collateral down; interest up; repaid-by-assets shares down.

Rounding table of the accounting identity: `totalAssets = idle + totalBorrowAssets`, and `loan.balanceOf(market) >= idle` always (excess = donations).

## 7. Actions

All state-changing externals use `nonReentrant` (transient) and follow checks-effects-interactions: accrue -> checks -> state updates -> external calls. `SafeERC20` everywhere; **fee-on-transfer and rebasing tokens are unsupported** (the market compares balance deltas on token entry and reverts on mismatch). No `tx.origin`, no `delegatecall`, no `selfdestruct`, no unbounded loops.

### 7.1 `deposit`/`mint`/`withdraw`/`redeem` (lenders, vault)

OZ ERC-4626 with overrides: `totalAssets` from the ledger; `_deposit` pulls assets, checks the balance delta, `idle += assets`, mints shares; `maxDeposit`/`maxMint` = 0 when not Active; `maxWithdraw`/`maxRedeem` limited by `idle`; accrue before every call.

### 7.2 `depositCollateral(amount, onBehalf)`

Accrue-free. Requires `totalCollateralStored + amount <= collateralCap` (in effective units), pulls tokens (balance delta check), credits `onBehalf`. Reverts if collateral token reverts.

### 7.3 `withdrawCollateral(amount, receiver)`

Requires Active. Accrue. If the account has debt: read `oracle.price()` (market reverts on `Invalid`/`CorporateAction`/`SequencerDown`), build the **post-state** context and require `debtAssets <= min(guard.maxBorrowable(ctx), collateralValue * lltvWad / WAD)`. Effects then transfer.

### 7.4 `borrow(assets, receiver)` / `repay`

`borrow`: Active only. Accrue; `assets <= idle`; compute shares (up); update ledgers; oracle read; post-state context; require the same bound as 7.3 and `debt >= minDebt`; `guard.onBorrow`; transfer. `repay`/`repayShares`: always allowed, no oracle; anyone for anyone; pulls from `msg.sender`; a leftover `0 < debt < minDebt` is rejected (repay all or leave at least `minDebt`).

### 7.5 `liquidate(borrower, repayAssets, receiver)`

1. Accrue. Read `oracle.price()` (revert on `Invalid`/`CorporateAction`/`SequencerDown`). Require `debt > 0`.
2. Build context; require `guard.liquidationAllowed(ctx)`.
3. **Close factor:** `maxRepay = debt * closeFactor / WAD` (rounded up); if health factor `maxDebt/debt < criticalHealthWad` (where `maxDebt = collateralValue * lltv / WAD`) then `maxRepay = debt`. If the remainder after repaying would be `0 < rest < minDebt`, require a full repay. `repay <= maxRepay`.
4. **Bonus:** `b = min(guard.liquidationBonus(ctx, repay), maxBonusWad)`.
5. **Seizure:** `seized = floor(floor(repay * (WAD + b) / WAD) * S / price)`. If `seized > collateral`: `seized = collateral` and the liquidator pays only `repay' = floor(value(collateral) * WAD / (WAD + b))` (so a liquidator is never charged for collateral that does not exist).
6. **Non-worsening rule:** if `collateralValue >= debt * (1 + b)` (solvent after bonus) the post-liquidation LTV is <= the pre-liquidation LTV by construction (`LTV_after <= LTV_before` iff `Cv >= D(1+b)`); otherwise (insolvent) the liquidator takes at most all collateral and the remaining debt is bad debt (explicit, 7.6). The market enforces by capping `b <= Cv/D - 1` when `Cv > D`, and `b` as above (never negative) when not.
7. Effects: burn debt shares (down), `totalBorrowAssets -= repay`, `collateral[borrower] -= seized`, then `safeTransferFrom(liquidator -> market, repay)` into `idle += repay`, then `safeTransfer(collateral -> receiver, seized)`, then `guard.onLiquidate`.

No halt gate: if the collateral token reverts the transfer, the whole liquidation reverts, which is exactly D2 ("disabled only while the token actually reverts").

### 7.6 `realizeBadDebt(borrower)`

Anyone. Accrue. Requires effective `collateral == 0` and `debt > 0`. `written = min(debt, totalBorrowAssets)`; `totalBorrowAssets -= written`; `totalBorrowShares -= userShares`; user shares = 0; `badDebtRealized += written`; event `BadDebtRealized(borrower, written, newTotalAssets)`. This is the **only** path by which `totalAssets` (hence the share price) can fall; it never rounds silently and never reverts on a healthy borrower.

### 7.7 `accrue()`

`elapsed = now - lastAccrual` (0 if Halted); `interest = ceil(totalBorrowAssets * taylor(rate(u) * elapsed))`; `totalBorrowAssets += interest`; `lastAccrual = now`. Cap `elapsed` and rate so the Taylor term cannot overflow (bounded: 5 years x slope2 max, tested).

## 8. Issuer-control policy (D2)

### 8.1 Detection: `reportIssuerFailure()` (permissionless)

Probes, each in `try/catch` with a fixed gas allowance (100k) and a precondition `gasleft() >= 150k` so a caller cannot cause a false positive by starving gas:

| # | Probe | Rationale [V] |
|---|---|---|
| 1 | `collateral.paused()` if it exists and returns true | Robinhood `Stock.paused()` = token flag OR registry-wide flag; one registry call freezes all tokens |
| 2 | `registry = collateral.ACCESS_CONTROLLED_REGISTRY()` then `registry.isBlocked(market)` | `isBlocked` lives on the registry, not the token |
| 3 | **Self-transfer probe**: if the market holds >= 1 wei of collateral, `try collateral.transfer(address(this), 1)`; revert/false = failure | passes through the exact `onlyNotPaused`, `onlyNotBlocked(to)`, `onlyNotBlocked(msg.sender)` modifiers with no net balance change; protects against unknown token variants (testnet token has no `oraclePaused`; generic tokens) |
| 4 | Loan token: `paused()` / `isFrozen(market)` where present (USDG exposes both [V]); else the same 1-wei self-transfer of loan token if `idle > 0` | USDG is pausable/freezable by its issuer [V] |
| 5 | **Collateral shortfall**: `collateral.balanceOf(market) < effective totalCollateral` | `adminBurn(from, amount)` burns from any address, even the market, ignoring pause and block [V]: the only way it shows up is a balance drop |

Any failing probe moves the market to `Halted` with a reason code and emits `IssuerFailure(reason, probeData)`. A passing report on an Active market emits nothing. A guardian may also `guardianHalt()` (reason `Guardian`), for example on a loan-token depeg (D3).

### 8.2 While halted

Table in section 5. Interest is frozen (`_accrue` early-returns; at `resume`, `lastAccrual = now`) so borrowers are not charged for something they cannot fix. Repay and lender exits of idle liquidity stay open (if the loan token permits). Liquidation has no halt gate; it fails by itself while the collateral transfer reverts.

### 8.3 Collateral shortfall handling (decision A5, needs approval)

Option **A (recommended)**: store `collateralScaleWad` (starts `1e18`); every read of a user's collateral is `stored * scale / WAD` (rounded down). `reconcileCollateral()` (permissionless, only when the halt reason is `CollateralShortfall`) sets `scale *= balanceOf(market) / effectiveTotal`, a deterministic pro-rata haircut, so there is no first-come advantage and no phantom collateral; positions are then re-evaluated on the haircut collateral and become liquidatable if they should. Cost: one `mulDiv` per collateral read. Option **B**: no scaling; the first withdrawers/liquidators drain the real balance and later users hold phantom collateral. B is smaller but unsound after an `adminBurn`; A is the minimum that keeps the ledger honest. Either way the loss is *not mitigated*, only bounded by the collateral cap.

### 8.4 Resumption and the freeze limit

`resume()`: the guardian may call it while `now < haltedAt + MAX_FREEZE` (30 days, constant) and only if all probes currently pass (the call runs them); governance may call it at any time after the limit. Resumption is explicit and evented (`Resumed(by, haltedFor)`); `lastAccrual = now`. If the collateral or loan token is still failing after `MAX_FREEZE`, only governance can act: `resume()` (if it chooses to accept the risk) or `windDown()` (decision A9): terminal; no new borrow or supply; accrual resumes (so borrowers who can repay have an incentive to); repay, liquidation and lender exits stay open. There is no mechanism that seizes collateral the issuer has frozen.

### 8.5 What lenders can and cannot recover

Can: idle liquidity (immediately, if the loan token works); repayments; liquidation proceeds once the collateral token works again. Cannot: loans backed by collateral that stays frozen or burned; the loss on those loans is bounded by `collateralCap * LLTV-weighted exposure`. **Not mitigable on chain (residual risk, THREAT_MODEL):** `adminBurn`, blocklisting of the market or of a liquidator, a registry-wide pause, and a beacon upgrade of the token logic. **All privileged roles are held by EOAs, with no multisig or timelock, and one `upgradeTo` changes every token's logic [V, DISCOVERY b]**; the issuer paused the registry once (about a minute, 2026-06-30) and blocked 246 addresses before launch; nothing since. The only mitigation is the per-market collateral cap and disclosure in the UI.

## 9. Oracle adapter: `ChainlinkEquityOracle`

Constructor (all immutable, config in `deployments/*.json`, never hardcoded in `src`): `feed` (AggregatorV3 proxy), `collateralToken`, `windowCache`, optional `sequencerFeed` + `sequencerGrace`, `maxAge` (24 h heartbeat + grace, N1), `deviationWad` (0.5 %, the irreducible price-error allowance), `freeAge`, `ageHaircutWadPerHour`, `maxAgeHaircutWad`, `minPriceWad`/`maxPriceWad` (absolute sanity bounds, which catch the zero/atypical prints Chainlink documents for thin sessions [D]).

Algorithm of `price()`:

1. `(roundId, answer, , updatedAt, answeredInRound) = feed.latestRoundData()`; `decimals = feed.decimals()` read at construction (8 on all observed feeds [V], never hardcoded). Invalid if `answer <= 0`, `updatedAt == 0`, `updatedAt > block.timestamp`, `answeredInRound < roundId` (incomplete), or the normalized price is outside `[minPriceWad, maxPriceWad]`. Normalize `priceWad = answer * 10^(18 - decimals)`. The feed price is **per token and already includes the corporate-action multiplier** [V]: no further scaling.
2. Corporate action: `try collateralToken.oraclePaused()` true, or `newUIMultiplier() != uiMultiplier()` with `effectiveAt() <= now + horizon` -> `CorporateAction`. Both calls are `try/catch` (the testnet token lacks `oraclePaused`).
3. Sequencer (optional, N3): if configured, down or inside `sequencerGrace` after `startedAt` -> `SequencerDown`. **Robinhood Chain has none [D]**: the check is simply omitted there (config), and sequencer downtime is covered as unscheduled blindness by `Stale`; Arbitrum One keeps `0xFdB631F5...97D` [V].
4. Calendar: `w = windowCache.state()`. If `w.blind` -> `ScheduledBlind` (no age haircut: the frozen price is the guard's gap-VaR problem). Else if `updatedAt < w.lastEnd` -> `Reopening`. Else `age = now - updatedAt`: `age > maxAge` -> `Stale`; otherwise `Fresh`.
5. `haircutWad = deviationWad + min(maxAgeHaircutWad, ageHaircutWadPerHour * max(0, age - freeAge) / 1h)` for `Fresh`/`Stale`/`Reopening`; `deviationWad` only for `ScheduledBlind`. The market does **not** apply the haircut; it passes it in the context (the control ignores it, the session-aware guard uses it).

Limits stated plainly: a 24 h heartbeat means a `Fresh` price can be hours old (SPY 4.4 h during regular hours, observed 2026-10-02 [V]); the haircut and the oracle buffer (50 bps, D7) are what bound the resulting error. Weekend and holiday behavior beyond the 14 observed windows, EST, and early-close days are unobserved (D6, D10): the adapter takes its blind/live decision from the calendar only, and a flipped early-close assumption would show up as `Stale`/`Reopening`, which fail safe. The adapter is **not** claimed integrated until a fork test reads the real feeds (optional, skipped without RPC env, D4).

`peek()` is the same logic without the cache write. `MockEquityOracle` (test fixture) returns whatever the test sets, including every status; `sim/SimEquityFeed.sol` is the AggregatorV3-shaped simulation (deviation/heartbeat updates, blind windows per the measured behavior, replay of `sim/replay_events.json`), labeled simulation everywhere.

## 10. Storage layout and gas-relevant packing

```
slot 0  : state (uint8) | haltReason (uint8) | haltedAt (uint40) | lastAccrual (uint40) | cDec, lDec
slot 1  : totalBorrowAssets (uint128) | totalBorrowShares (uint128)
slot 2  : idle (uint128) | badDebtRealized (uint128)
slot 3  : totalCollateral (uint128) | collateralScaleWad (uint128)
mapping : position[address] -> { uint128 borrowShares; uint128 collateral }   // one slot per account
immutable (clone args in storage after init): params (collateralToken, loanToken, oracle, guard, guardian, governance, lltv, ...)
```

Params are written once in `initialize` into packed storage (clones cannot use `immutable` for per-market values; each read is a cold SLOAD, accepted, see gas plan). OZ ERC-20/4626 state uses its ERC-7201 namespaced slots.

## 11. Factory

`SundownMarketFactory`: constructor takes the implementation (whose constructor calls `_disableInitializers()`), the `governance` owner (`Ownable2Step`) and the registries (allowed guards/oracles). `createMarket(MarketParams)` is **owner-only** (decision A3: permissionless creation invites fake markets and fake guards; the UI lists factory-registered markets only), validates (section 3), `Clones.cloneDeterministic(impl, keccak256(abi.encode(params)))` (one market per unique parameter set; address predictable before creation), calls `initialize`, records `isMarket[market]`, appends to `allMarkets`, emits `MarketCreated(market, params hash, collateral, loan, guard, oracle)`. No upgrade path, no admin function on markets.

## 12. Exit liquidity and the collateral cap (D5, D9)

**Evidence ([V], `research/exit_liquidity.py`, block 78,536,996, exact Uniswap v3 swap simulation selling stock for USDG at the oracle price; `DISCOVERY.md` section g):**

| Asset | max notional at slippage <= 1 % | <= 3 % | <= 5 % | Concentration | Proposed `collateralCap` = 0.5 x (3 % figure) |
|---|---|---|---|---|---|
| TSLA | $50.6k | $189.9k | $304.0k | 95 % one pool | **~$95k** |
| NVDA | $262.4k | $1.119M | $1.861M | 99 % one pool | **~$560k** |
| AAPL | $85.8k | $196.6k | $220.0k | 78 % one pool | **~$98k** |
| SPY | $143.6k | $249.9k | $250.5k | 94 % one pool | **~$125k** |

v3 only (v4, RFQ and aggregators not modeled); a snapshot minute; weekend depth unmeasured; basis to the oracle included (one NVDA pool is 11.8 % off and counts for nothing).

**Cap rule (proposal, decision A6):** `collateralCap (tokens) = floor(0.5 * maxNotional(3 %) / referencePrice)` computed off chain at creation from `exit_liquidity.json` and recorded in `deployments/<chain>.json` with the retrieval block; the cap is in token units and immutable. Rationale: a liquidator's margin is `(1 + bonus)(1 - s) - 1`; at a 5.5 % bonus and `s = 3 %` it is about 2.4 %; the 0.5 factor leaves room for a whole-book partial liquidation plus other sellers. A cap in token units is exact for the market and needs no oracle at deposit; its USD value drifts with the price (documented; resizing means a new market).

**Implication to decide (D5 asks for "meaningful onchain liquidity"):** the four candidate markets together support about **$0.9M** of collateral at a 3 % exit, and only NVDA exceeds $0.2M. TSLA/AAPL/SPY are marginal. Options: (i) ship NVDA as the headline market and the others as small, honestly labeled pilots; (ii) require RFQ/aggregator integration (unmeasured) before raising caps; (iii) keep the four and label them as demonstration-scale. Needs your call.

**Liquidation sizing (D9, to be evaluated in M2.2):** depth-sized partial liquidations mean `maxRepay` should not exceed what the pools absorb at the target slippage; the market's 50 % close factor plus the cap is the coarse version. A Dutch-ramp bonus (bonus rising with time since the position became liquidatable, up to `maxBonusWad`) and a minimum-slice rule live in the guard (`liquidationBonus` sees `repayAssets`), so M2.2 can change them without touching the market.

## 13. Invariants (formal; to be encoded as Foundry invariants with a `Handler`)

State variables: `C_u` effective collateral of user `u`, `S_u` borrow shares, `D = totalBorrowAssets`, `Sh = totalBorrowShares`, `I = idle`, `A = totalAssets = I + D`, `V = vault total shares`, `P = A / V` (share price).

| # | Invariant | Notes |
|---|---|---|
| I1 | **Collateral conservation:** `sum_u stored_u == totalCollateral` and `collateral.balanceOf(market) >= totalCollateral * scale / WAD` unless the market is `Halted(CollateralShortfall)` | donations only increase the left side of the inequality |
| I2 | **Loan conservation:** `loan.balanceOf(market) >= idle` | |
| I3 | **Vault accounting identity:** `totalAssets() == idle + totalBorrowAssets` at every externally observable point | `badDebtRealized` is already netted out of `D` |
| I4 | `sum_u S_u == totalBorrowShares` and `sum_u debt(u) <= totalBorrowAssets + dust` where `dust < 1 asset per account` from round-up | debts are rounded up so the sum can exceed `D` by <1 unit per account, never undercount |
| I5 | **No borrow above guard capacity:** immediately after `borrow` or `withdrawCollateral`, `debt(u) <= min(guard.maxBorrowable(ctx), collateralValue(u) * lltv / WAD)` evaluated at the oracle price used by that call | |
| I6 | **Liquidation never worsens a solvent position:** for a liquidation with `Cv >= D(1+b)`, `LTV_after <= LTV_before`; for an insolvent one the liquidator receives <= all collateral and `repay <= value(seized)/(1+b)` | |
| I7 | **Share price monotone:** `P` never decreases except in a transaction that emits `BadDebtRealized` (interest only increases `D`; the vault rounding favors the vault) | tested for deposit/withdraw/redeem/mint sequences too |
| I8 | **Repay is never blockable by halt/pause/guard:** `repay` succeeds whenever the loan-token transfer succeeds, in every market state, with no oracle read | the Handler asserts it in all states |
| I9 | **Liquidation has no halt gate:** in `Halted`, `liquidate` reverts only for a failing token transfer, an invalid/corporate-action/sequencer-down price, a guard refusal, or healthy position | |
| I10 | Interest accrues only when Active/WindDown and is monotone: `totalBorrowAssets` is non-decreasing across `accrue` | |
| I11 | `totalCollateral <= collateralCap` after any `depositCollateral` | |
| I12 | Inflation/donation resistance: for any donation `d` and first deposit sequence, a later depositor of `x` can redeem >= `x - 1` assets-equivalent (virtual shares 1e6) | |
| I13 | Only `realizeBadDebt` removes debt without a payment, only for `collateral == 0` accounts | |
| I14 | Guards cannot change accounting: for any guard (fuzzed mock), `A`, `V`, shares and balances change only through the documented actions | |
| I15 | Halted state: `deposit`, `mint`, `borrow`, `withdrawCollateral` revert; accrual constant | |

## 14. Component threat model

| Component | Threat | Control / residual |
|---|---|---|
| Vault | first-depositor inflation, donation | virtual shares 1e6 + internal ledger (I12); donations locked, not credited |
| Vault | rounding drain by dust deposits/borrows | rounding table (section 6); `minDebt` |
| Interest | overflow in Taylor term with huge `elapsed`; rate manipulation | bounded `elapsed` x rate, Python reference, fuzz; rate depends on utilization only (flash-borrowing moves utilization within one tx: no interest in a tx, accrual is lazy and uses prior state) |
| Positions | self-liquidation/sandwich around oracle updates | bonus capped; the oracle update order is outside our control (SVR feeds reserve that for others [D]); accepted |
| Liquidation | griefing with dust slices, front-running a cure window | `minDebt` dust rule; guard-level cure logic in M4a |
| Liquidation | bonus > position value (insolvent) | non-worsening rule and the explicit insolvent branch (7.5) |
| Oracle | stale price accepted | calendar-aware statuses (N1); market refuses on Invalid/CorporateAction/SequencerDown; guard decides on Stale/Blind |
| Oracle | zero or outlier print in thin sessions | absolute bounds; `Invalid` |
| Oracle | corporate action mid-flight | `oraclePaused`/pending multiplier -> `CorporateAction` -> borrow and liquidation refused |
| Oracle | calendar cache stale after an ad-hoc closure | TTL 24 h < `ANNOUNCE_LEAD` 72 h (argument in 4.3) |
| Guard | malicious/buggy guard | fixed at creation by governance, reviewed; market bounds (bonus cap, close factor, non-worsening, `min(guard, lltv)` borrow cap); cannot move funds (I14); residual: can freeze borrowing and trigger bounded liquidations |
| Issuer | pause, blocklist, `adminBurn`, beacon upgrade of the token; EOA-held roles [V] | halt policy (section 8) detects and freezes; **cannot be prevented**; cap bounds the loss; disclosed |
| Loan token | USDG pause/freeze [V], depeg | probe 4; guardian halt; D3 assumption disclosed |
| Halt policy | false-positive halts by gas starvation | gas precondition + fixed allowance; a revert is a halt only if the probe actually ran |
| Halt policy | guardian abuse | can only halt; resume limited by probes and 30-day limit; no fund access |
| Factory | fake markets, hostile params | owner-only creation; param validation; UI lists registry only |
| Clones | uninitialized implementation takeover | `_disableInitializers()` in the implementation constructor; clones initialize once atomically in the factory call |
| Reentrancy | malicious token callbacks | `ReentrancyGuardTransient`, CEI, no hooks to untrusted receivers beyond the token transfers; tokens are reviewed, fee-on-transfer/rebasing rejected by balance-delta checks |
| Collateral cap | cap too large for exit liquidity | cap derived from measured depth (section 12); small by construction |
| Oracle/calendar | feed beyond the observed regime (EST, early close, Short windows) | unobserved (D6/D10); fail-safe statuses; flagged |
| Social | users misread the claim | UI text must trace to `CLAIMS.md`; no "safer than Aave" claim |

## 15. Test plan (3b)

1. **Unit**: every action and revert path; rounding table cases; halt state table; probes with mocks; clone initialization and implementation lock; factory validation.
2. **Python-reference fixtures**: `research/market_reference.py` implements the kinked rate, Taylor compounding, share conversions and a full single-market ledger in exact integers and emits `contracts/test/fixtures/market_cases.json` (rate curve, accrual over long and irregular `elapsed`, borrow/repay sequences, liquidation amounts, bad-debt cases); Foundry asserts equality. The existing integer reference in `estimators.py` is for the guard, not this milestone.
3. **ERC-4626**: inflation and donation attacks (attacker/victim scripts), rounding properties, `maxDeposit/maxWithdraw` under halt and low idle, preview vs actual.
4. **Malicious/odd tokens** (`test/mocks`): reentrant on transfer, always-reverting after a switch (pause), blocklist-by-address, returns-false, fee-on-transfer, rebasing, burn-from-market (`adminBurn` model), gas-guzzling `transfer`, no-`paused()` token, 6/18/8-decimal tokens.
5. **Stateful invariants**: a `Handler` with actors (lenders, borrowers, liquidators, oracle mover, time warper, guardian, issuer-failure injector) and ghost variables for I1-I15; long runs in the `ci` profile; targeted scenarios for halt/resume/shortfall.
6. **Guard fuzz**: a configurable `MockGuard` returning arbitrary values to prove I5/I14 and the bounds.
7. **Fork tests** (optional, skipped when no RPC env, unpinned latest block, D4): real feeds through the adapter (decimals, status, haircut); real `Stock` token `paused()`/registry `isBlocked` probes; USDG `paused()/isFrozen`; a market created with the real tokens and a deposit/borrow/repay round trip if tokens permit. Only these tests may let us say "integrated".
8. **Static analysis**: slither clean-or-triaged; `forge fmt`; coverage target >= 95 % lines / branches on `src` (M1's libraries stay at 100 %).

## 16. Gas plan

Targets (to be measured and held with `forge snapshot`): `deposit`/`redeem` <= 120k; `depositCollateral` <= 90k; `borrow` <= 230k and `liquidate` <= 300k **including** oracle (feed + token + warm window cache) and one guard call; `accrue` <= 60k; clone creation + initialize <= 450k. Levers: `ReentrancyGuardTransient`; packed slots (section 10); one oracle read per action; one guard call per action (`onBorrow`/`onLiquidate` only for stateful guards via a code-size/flag check); the window cache avoids the 75.8k-151k calendar scan per action (D11); avoid redundant `accrue` in the same tx; custom errors; no loops. A cold `SLOAD` on param reads in clones is accepted.

## 17. Decisions needing your approval

| # | Decision | Recommendation |
|---|---|---|
| A1 | Add `openzeppelin-contracts-upgradeable` v5.7.0 (pinned submodule) solely for clone-safe ERC-4626/ERC-20/Initializable | yes (the alternative is a hand-written ERC-4626, strictly worse) |
| A2 | Market and vault are one contract | yes |
| A3 | Factory creation is owner-only; guards/oracles from a reviewed set | yes |
| A4 | Guard trust model (section 4.2): guard authorizes liquidations incl. early/boosted-tier ones, bounded by the market | yes; it is what keeps the tier out of the market |
| A5 | Collateral shortfall (`adminBurn`) handling: pro-rata `collateralScale` (A) vs none (B) | A |
| A6 | Collateral cap in token units, immutable, from exit liquidity (0.5 x depth at 3 %) | yes |
| A7 | The market passes `haircutWad` and uses only the raw price for seizure math; the control ignores the haircut | yes |
| A8 | `WindowCache` as a shared helper used by oracle and guards (D11) | yes |
| A9 | `MAX_FREEZE` 30 days; after it only governance may resume; optional terminal `windDown()` | yes |
| A10 | No protocol fee/reserve factor in this milestone; reserve is an extension point only | yes |
| A11 | Deployment scope vs measured depth (section 12): NVDA headline + small pilots, or demonstration-scale for all four | your call |
| A12 | `minDebt` dust floor and `closeFactor`/`criticalHealth` defaults (50 % / 0.95) | yes, tune in 3b with the Python reference |

## 18. Proposed step 3b order and estimate

1. **3b-1 core** (~7-9 h): `KinkedRate`/`SharesMath` libs + Python reference and fixtures; `SundownMarket` vault and positions with `FlatGuard` and `MockEquityOracle`; factory and clones; unit and reference tests.
2. **3b-2 oracle** (~4-5 h): `WindowCache`, `ChainlinkEquityOracle`, `SimEquityFeed`; status tests with the M1 calendar; optional fork test.
3. **3b-3 hardening** (~5-6 h): halt/probe policy, shortfall reconcile, malicious-token mocks, stateful invariants with a Handler, gas snapshot, slither.

**Honest estimate: about 16-20 hours of focused work for 3b**, with the invariant suite and the issuer-failure state machine as the main risks (they are the part most likely to find bugs; budget time to fix, not just to write). It stops at the end of each sub-step for your review per the charter. Nothing here starts without your approval.
