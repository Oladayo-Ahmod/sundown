// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AccountCtx, IRiskGuard} from "../interfaces/IRiskGuard.sol";
import {IEquityOracle, PriceData, PriceStatus} from "../interfaces/IEquityOracle.sol";
import {IWindowCache, WindowState} from "../interfaces/IWindowCache.sol";
import {MarketState} from "../interfaces/ISundownMarket.sol";
import {SundownMarket} from "../SundownMarket.sol";

/// @title SundownGuard
/// @notice Session-aware LLTV: boosted weekday capacity, tighter weekend capacity. An account may opt into a
/// boosted tier (a higher LLTV). From `preWindowHorizon` before a blind window, through the window and its
/// reopening, a boosted account's capacity is `min(boostedLLTV, 1 - gapVaR[class] - oracleBuffer - safetyBuffer)`.
/// Accounts above that cap are flagged, may cure, and after the cure window anyone may deleverage them through
/// the market's own liquidation path at a reduced fee. This is a capacity policy with enforcement, not loss
/// prevention: calibration and keeper economics are documented in docs/GUARD_DESIGN.md.
/// @dev Bound to exactly one market (`bindMarket`, once). Eligibility is a pure function of position, price
/// status, window state and time; nothing here is a state transition that someone must execute at the horizon
/// start. The market bounds this guard (bonus cap, close factor, non-worsening rule, `min(guard, cv * lltv)`).
contract SundownGuard is IRiskGuard {
    /// @notice 1e18 fixed point.
    uint256 internal constant WAD = 1e18;

    // ---- hard parameter bounds (docs/GUARD_DESIGN.md section 5)
    uint64 public constant MIN_STANDARD_LLTV = 0.3e18;
    uint64 public constant MAX_STANDARD_LLTV = 0.95e18;
    /// @notice `boostedLLTV * (1 + 5.5 %) < 1`: a position at the threshold stays liquidatable with a cushion.
    uint64 public constant MAX_BOOSTED_LLTV = 0.94e18;
    uint64 public constant MAX_GAP_VAR = 0.5e18;
    uint64 public constant MIN_ORACLE_BUFFER = 0.001e18;
    uint64 public constant MAX_ORACLE_BUFFER = 0.05e18;
    uint64 public constant MAX_SAFETY_BUFFER = 0.1e18;
    uint64 public constant MIN_BONUS = 0.03e18;
    uint64 public constant MAX_BONUS = 0.055e18;
    uint64 public constant MIN_DELEVERAGE_FEE = 0.0025e18;
    uint64 public constant MAX_DELEVERAGE_MARGIN = 0.05e18;
    uint32 public constant MIN_HORIZON = 1 hours;
    uint32 public constant MAX_HORIZON = 48 hours;
    /// @notice Shortest allowed deleverage interval (`horizon - cure`).
    uint32 public constant MIN_DELEVERAGE_INTERVAL = 1 hours;
    uint32 public constant MIN_TIMELOCK = 1 hours;
    uint32 public constant MAX_TIMELOCK = 14 days;

    /// @notice Policy parameters of the market this guard serves. All WAD values are fractions of 1e18.
    /// @param standardLltv Borrow cap and liquidation threshold of the standard tier.
    /// @param boostedLltv Same for the boosted tier; 0 disables the tier.
    /// @param gapShort Through-the-cycle downside gap for Short windows.
    /// @param gapWeekend Same for Weekend windows.
    /// @param gapLong Same for Long windows.
    /// @param oracleBuffer Allowance for the feed's irreducible deviation.
    /// @param safetyBuffer Extra margin on top.
    /// @param bonus Flat liquidation bonus for ordinary liquidations.
    /// @param deleverageFee Reduced bonus for deleveraging (<= bonus).
    /// @param deleverageMargin Distance below the stress cap a deleverage aims for.
    /// @param preWindowHorizon Seconds before a window at which the stress cap starts.
    /// @param cureWindow Seconds from the horizon start during which flagged accounts may cure.
    struct Params {
        uint64 standardLltv;
        uint64 boostedLltv;
        uint64 gapShort;
        uint64 gapWeekend;
        uint64 gapLong;
        uint64 oracleBuffer;
        uint64 safetyBuffer;
        uint64 bonus;
        uint64 deleverageFee;
        uint64 deleverageMargin;
        uint32 preWindowHorizon;
        uint32 cureWindow;
    }

    /// @notice Oracle of the served market (checked at binding).
    IEquityOracle public immutable ORACLE;
    /// @notice Shared blind-window cache (the oracle's cache in deployments).
    IWindowCache public immutable WINDOWS;
    /// @notice Proposes parameter changes (a timelock or multisig in deployments).
    address public immutable GOVERNANCE;
    /// @notice May only tighten: disable boosted entry, block new borrows.
    address public immutable GUARDIAN;
    /// @notice Delay between `queueParams` and `executeParams`.
    uint32 public immutable TIMELOCK_DELAY;
    uint256 internal immutable VALUE_SCALE;
    uint8 internal immutable COLLATERAL_DECIMALS;
    uint8 internal immutable LOAN_DECIMALS;

    /// @notice Current parameters.
    Params public params;
    /// @notice The bound market (zero before `bindMarket`).
    SundownMarket public market;
    /// @notice Deployer allowed to bind the market once, then zeroed.
    address public admin;
    /// @notice Guardian flag: no new boosted entries.
    bool public boostedEntryDisabled;
    /// @notice Guardian flag: `onBorrow` reverts.
    bool public borrowsBlocked;
    /// @notice Hash of the queued parameters (0 if none) and its earliest execution time.
    bytes32 public queuedHash;
    uint64 public queuedEta;

    /// @notice Whether an account is in the boosted tier.
    mapping(address account => bool) public boosted;
    /// @notice Window id for which an account was last flagged by `flag` (informational, gates nothing).
    mapping(address account => uint64) public flaggedWindow;

    event BoostedEntered(address indexed account);
    event BoostedExited(address indexed account);
    event Flagged(address indexed account, uint64 indexed windowId, uint256 debt, uint256 stressCap);
    event Deleveraged(
        address indexed account,
        address indexed liquidator,
        uint64 indexed windowId,
        uint256 repaid,
        uint256 seized,
        uint256 debtBefore,
        uint256 stressCap,
        uint256 requiredRepay
    );
    event ParamsQueued(bytes32 indexed hash, uint64 eta);
    event ParamsExecuted(bytes32 indexed hash);
    event ParamsCancelled(bytes32 indexed hash);
    event BoostedEntryDisabledSet();
    event BorrowsBlockedSet();
    event GuardianFlagsCleared();
    event MarketBound(address indexed market);

    error InvalidParam(bytes32 field);
    error Unauthorized();
    error AlreadyBound();
    error NotBound();
    error NotMarket();
    error BindingMismatch(bytes32 field);
    error BoostedUnavailable();
    error BoostedEntryDisabled();
    error BorrowsBlocked();
    error AlreadyBoosted();
    error NotBoosted();
    error EntryNotAllowed(bytes32 reason);
    error DoesNotFitStandard(uint256 debt, uint256 cap);
    error NotAboveStressCap();
    error AlreadyFlagged();
    error NothingQueued();
    error HashMismatch();
    error TooEarly(uint64 eta);
    error RepayExceedsRequired(uint256 repaid, uint256 requiredRepay);
    error PriceUnusable(uint8 status);

    /// @param initial Initial parameters (validated).
    /// @param oracle_ Price oracle of the served market.
    /// @param windows_ Blind-window cache.
    /// @param governance_ Parameter proposer.
    /// @param guardian_ Tighten-only guardian.
    /// @param admin_ Allowed to bind the market once.
    /// @param timelockDelay Seconds between queue and execute.
    /// @param collateralDecimals_ Collateral token decimals.
    /// @param loanDecimals_ Loan token decimals.
    constructor(
        Params memory initial,
        address oracle_,
        address windows_,
        address governance_,
        address guardian_,
        address admin_,
        uint32 timelockDelay,
        uint8 collateralDecimals_,
        uint8 loanDecimals_
    ) {
        if (oracle_ == address(0) || windows_ == address(0)) revert InvalidParam("address");
        if (governance_ == address(0) || guardian_ == address(0) || admin_ == address(0)) {
            revert InvalidParam("address");
        }
        if (timelockDelay < MIN_TIMELOCK || timelockDelay > MAX_TIMELOCK) revert InvalidParam("timelock");
        if (collateralDecimals_ > 18 || loanDecimals_ > 18) revert InvalidParam("decimals");
        _validate(initial);
        params = initial;
        ORACLE = IEquityOracle(oracle_);
        WINDOWS = IWindowCache(windows_);
        GOVERNANCE = governance_;
        GUARDIAN = guardian_;
        admin = admin_;
        TIMELOCK_DELAY = timelockDelay;
        COLLATERAL_DECIMALS = collateralDecimals_;
        LOAN_DECIMALS = loanDecimals_;
        VALUE_SCALE = 10 ** (uint256(collateralDecimals_) + 18 - uint256(loanDecimals_));
    }

    // ------------------------------------------------------------------ binding

    /// @notice Binds this guard to its market once; verifies the market names this guard, this oracle and the
    /// configured decimals. The admin role is then renounced.
    /// @param market_ The market created with this guard as its `guard`.
    function bindMarket(address market_) external {
        if (msg.sender != admin) revert Unauthorized();
        if (address(market) != address(0)) revert AlreadyBound();
        SundownMarket.Config memory c = SundownMarket(market_).config();
        if (c.guard != address(this)) revert BindingMismatch("guard");
        if (c.oracle != address(ORACLE)) revert BindingMismatch("oracle");
        if (c.collateralDecimals != COLLATERAL_DECIMALS || c.loanDecimals != LOAN_DECIMALS) {
            revert BindingMismatch("decimals");
        }
        Params memory p = params;
        uint256 maxLltv = p.boostedLltv > p.standardLltv ? p.boostedLltv : p.standardLltv;
        if (c.lltvWad != maxLltv) revert BindingMismatch("lltv");
        market = SundownMarket(market_);
        admin = address(0);
        emit MarketBound(market_);
    }

    // ------------------------------------------------------------------ IRiskGuard

    /// @inheritdoc IRiskGuard
    /// @dev Unscheduled blindness (`Stale`) returns 0, which blocks every borrow and every collateral
    /// withdrawal with debt (all are health-lowering). Boosted accounts get the stress cap during the stress
    /// period. Rounded down.
    function maxBorrowable(AccountCtx calldata c) external view returns (uint256) {
        if (c.status == PriceStatus.Stale) return 0;
        Params memory p = params;
        uint256 frac = p.standardLltv;
        if (p.boostedLltv != 0 && boosted[c.account]) {
            frac = p.boostedLltv;
            WindowState memory w = WINDOWS.peek();
            if (_stress(w, c.status, p)) frac = Math.min(frac, _stressFraction(p, w.cls));
        }
        return Math.mulDiv(c.collateralValue, frac, WAD);
    }

    /// @inheritdoc IRiskGuard
    /// @dev Ordinary: debt above the account's tier threshold. Deleverage: a healthy boosted account above the
    /// stress cap inside the deleverage zone (see {_deleverageZone}).
    function liquidationAllowed(AccountCtx calldata c) external view returns (bool) {
        Params memory p = params;
        bool isBoosted = p.boostedLltv != 0 && boosted[c.account];
        if (c.debtAssets > _threshold(c.collateralValue, p, isBoosted)) return true;
        if (!isBoosted) return false;
        (bool inZone, uint256 cap,) = _deleverageZone(c.collateralValue, c.debtAssets, c.status, p);
        return inZone && c.debtAssets > cap;
    }

    /// @inheritdoc IRiskGuard
    /// @dev The ordinary flat bonus when the account is unhealthy; the reduced deleverage fee otherwise (the
    /// market only asks after `liquidationAllowed`, so a healthy account here is in the deleverage zone).
    function liquidationBonus(AccountCtx calldata c, uint256) external view returns (uint256) {
        Params memory p = params;
        bool isBoosted = p.boostedLltv != 0 && boosted[c.account];
        if (c.debtAssets > _threshold(c.collateralValue, p, isBoosted)) return p.bonus;
        return p.deleverageFee;
    }

    /// @inheritdoc IRiskGuard
    function onBorrow(AccountCtx calldata, uint256) external view {
        if (msg.sender != address(market)) revert NotMarket();
        if (borrowsBlocked) revert BorrowsBlocked();
    }

    /// @inheritdoc IRiskGuard
    /// @dev For a deleverage (healthy pre-state) enforces `repaid <= requiredRepay` (or the full debt when the
    /// market's dust rule closed the position) and emits {Deleveraged}. Ordinary liquidations pass untouched.
    function onLiquidate(AccountCtx calldata c, address liquidator, uint256 repaid, uint256 seized) external {
        if (msg.sender != address(market)) revert NotMarket();
        Params memory p = params;
        bool isBoosted = p.boostedLltv != 0 && boosted[c.account];
        if (c.debtAssets > _threshold(c.collateralValue, p, isBoosted)) return;

        (, uint256 cap, uint256 capFrac) = _deleverageZone(c.collateralValue, c.debtAssets, c.status, p);
        uint256 required = _requiredRepay(c.collateralValue, c.debtAssets, capFrac, p);
        if (repaid > required && repaid != c.debtAssets) revert RepayExceedsRequired(repaid, required);
        emit Deleveraged(c.account, liquidator, c.windowId, repaid, seized, c.debtAssets, cap, required);
    }

    // ------------------------------------------------------------------ tier management

    /// @notice Opts the caller into the boosted tier. Only outside the stress period, with a Fresh price, an
    /// Active market, and a position that fits the standard tier and the stress cap (so entering can neither
    /// escape a liquidation nor start in breach).
    function enterBoosted() external {
        Params memory p = params;
        if (address(market) == address(0)) revert NotBound();
        if (p.boostedLltv == 0) revert BoostedUnavailable();
        if (boostedEntryDisabled) revert BoostedEntryDisabled();
        if (boosted[msg.sender]) revert AlreadyBoosted();
        if (market.state() != MarketState.Active) revert EntryNotAllowed("halted");
        PriceData memory pd = ORACLE.peek();
        if (pd.status != PriceStatus.Fresh) revert EntryNotAllowed("price");
        WindowState memory w = WINDOWS.peek();
        if (_stress(w, pd.status, p)) revert EntryNotAllowed("stress");

        uint256 debt = market.debtOf(msg.sender);
        if (debt != 0) {
            uint256 cv = _value(market.collateralOf(msg.sender), pd.priceWad);
            uint256 frac = Math.min(p.standardLltv, _stressFraction(p, w.cls));
            uint256 cap = Math.mulDiv(cv, frac, WAD);
            if (debt > cap) revert DoesNotFitStandard(debt, cap);
        }
        boosted[msg.sender] = true;
        emit BoostedEntered(msg.sender);
    }

    /// @notice Returns the caller to the standard tier, at any time, if the position fits the standard tier.
    function exitBoosted() external {
        if (!boosted[msg.sender]) revert NotBoosted();
        uint256 debt = market.debtOf(msg.sender);
        if (debt != 0) {
            PriceData memory pd = ORACLE.peek();
            _requireUsable(pd);
            uint256 cap = Math.mulDiv(_value(market.collateralOf(msg.sender), pd.priceWad), params.standardLltv, WAD);
            if (debt > cap) revert DoesNotFitStandard(debt, cap);
        }
        boosted[msg.sender] = false;
        emit BoostedExited(msg.sender);
    }

    /// @notice Optional permissionless poke: records and announces that a boosted account is above the stress
    /// cap in the current stress period. Gates nothing (eligibility is recomputed from live state).
    /// @param account The account to flag.
    function flag(address account) external {
        Params memory p = params;
        if (!boosted[account]) revert NotBoosted();
        PriceData memory pd = ORACLE.peek();
        _requireUsable(pd);
        WindowState memory w = WINDOWS.peek();
        if (!_stress(w, pd.status, p)) revert NotAboveStressCap();
        uint256 cap = Math.mulDiv(
            _value(market.collateralOf(account), pd.priceWad), Math.min(p.boostedLltv, _stressFraction(p, w.cls)), WAD
        );
        uint256 debt = market.debtOf(account);
        if (debt <= cap) revert NotAboveStressCap();
        if (flaggedWindow[account] == w.windowId) revert AlreadyFlagged();
        flaggedWindow[account] = w.windowId;
        emit Flagged(account, w.windowId, debt, cap);
    }

    // ------------------------------------------------------------------ views

    /// @notice What a keeper needs to deleverage `account` now through `market.liquidate`.
    /// @param account The borrower.
    /// @return eligible True if a deleverage call is allowed now.
    /// @return debt Current debt.
    /// @return stressCap Debt ceiling at the stress fraction.
    /// @return requiredRepay Largest repay the guard accepts (the market's close factor may bound a call lower).
    /// @return expectedSeized Collateral the keeper receives for `requiredRepay` at the deleverage fee.
    function quoteDeleverage(address account)
        external
        view
        returns (bool eligible, uint256 debt, uint256 stressCap, uint256 requiredRepay, uint256 expectedSeized)
    {
        Params memory p = params;
        debt = market.debtOf(account);
        PriceData memory pd = ORACLE.peek();
        if (debt == 0 || pd.priceWad == 0 || !boosted[account] || p.boostedLltv == 0) return (false, debt, 0, 0, 0);
        uint256 cv = _value(market.collateralOf(account), pd.priceWad);
        if (debt > _threshold(cv, p, true)) return (false, debt, 0, 0, 0); // ordinary liquidation territory
        bool inZone;
        uint256 capFrac;
        (inZone, stressCap, capFrac) = _deleverageZone(cv, debt, pd.status, p);
        eligible = inZone && debt > stressCap;
        if (eligible) {
            requiredRepay = _requiredRepay(cv, debt, capFrac, p);
            expectedSeized =
                Math.mulDiv(Math.mulDiv(requiredRepay, WAD + p.deleverageFee, WAD), VALUE_SCALE, pd.priceWad);
        }
    }

    /// @notice Stress fraction `1 - gapVaR - oracleBuffer - safetyBuffer` (floored at 0) for a window class.
    /// @param cls 0 Short, 1 Weekend, 2 Long.
    function stressFraction(uint8 cls) external view returns (uint256) {
        return _stressFraction(params, cls);
    }

    // ------------------------------------------------------------------ governance (timelocked) and guardian

    /// @notice Queues new parameters; executable after `TIMELOCK_DELAY`. Replaces any queued proposal.
    /// @param next The proposed parameters (bounds are checked now and again at execution).
    function queueParams(Params calldata next) external {
        if (msg.sender != GOVERNANCE) revert Unauthorized();
        _validate(next);
        bytes32 h = keccak256(abi.encode(next));
        uint64 eta = uint64(block.timestamp + TIMELOCK_DELAY);
        queuedHash = h;
        queuedEta = eta;
        emit ParamsQueued(h, eta);
    }

    /// @notice Applies the queued parameters once the delay has passed.
    /// @param next Must equal the queued proposal.
    function executeParams(Params calldata next) external {
        if (msg.sender != GOVERNANCE) revert Unauthorized();
        bytes32 h = queuedHash;
        if (h == 0) revert NothingQueued();
        if (keccak256(abi.encode(next)) != h) revert HashMismatch();
        if (block.timestamp < queuedEta) revert TooEarly(queuedEta);
        _validate(next);
        Params memory current = params;
        uint256 maxLltv = next.boostedLltv > next.standardLltv ? next.boostedLltv : next.standardLltv;
        uint256 curMax = current.boostedLltv > current.standardLltv ? current.boostedLltv : current.standardLltv;
        // the market's lltv is immutable: the guard may not claim a higher threshold than the market enforces
        if (maxLltv > curMax) revert InvalidParam("lltvAboveMarket");
        params = next;
        queuedHash = 0;
        queuedEta = 0;
        emit ParamsExecuted(h);
    }

    /// @notice Drops the queued proposal.
    function cancelParams() external {
        if (msg.sender != GOVERNANCE) revert Unauthorized();
        bytes32 h = queuedHash;
        if (h == 0) revert NothingQueued();
        queuedHash = 0;
        queuedEta = 0;
        emit ParamsCancelled(h);
    }

    /// @notice Guardian: stop new boosted entries (tightening only).
    function disableBoostedEntry() external {
        if (msg.sender != GUARDIAN) revert Unauthorized();
        boostedEntryDisabled = true;
        emit BoostedEntryDisabledSet();
    }

    /// @notice Guardian: block new borrows (tightening only; repay and withdrawals are unaffected).
    function blockBorrows() external {
        if (msg.sender != GUARDIAN) revert Unauthorized();
        borrowsBlocked = true;
        emit BorrowsBlockedSet();
    }

    /// @notice Governance: clear both guardian flags (restores the timelock-approved configuration).
    function clearGuardianFlags() external {
        if (msg.sender != GOVERNANCE) revert Unauthorized();
        boostedEntryDisabled = false;
        borrowsBlocked = false;
        emit GuardianFlagsCleared();
    }

    // ------------------------------------------------------------------ internals

    function _validate(Params memory p) internal pure {
        if (p.standardLltv < MIN_STANDARD_LLTV || p.standardLltv > MAX_STANDARD_LLTV) {
            revert InvalidParam("standardLltv");
        }
        if (p.boostedLltv != 0 && (p.boostedLltv < p.standardLltv || p.boostedLltv > MAX_BOOSTED_LLTV)) {
            revert InvalidParam("boostedLltv");
        }
        if (p.gapShort > MAX_GAP_VAR || p.gapWeekend > MAX_GAP_VAR || p.gapLong > MAX_GAP_VAR) {
            revert InvalidParam("gapVar");
        }
        if (p.oracleBuffer < MIN_ORACLE_BUFFER || p.oracleBuffer > MAX_ORACLE_BUFFER) {
            revert InvalidParam("oracleBuffer");
        }
        if (p.safetyBuffer > MAX_SAFETY_BUFFER) revert InvalidParam("safetyBuffer");
        if (p.bonus < MIN_BONUS || p.bonus > MAX_BONUS) revert InvalidParam("bonus");
        if (p.deleverageFee < MIN_DELEVERAGE_FEE || p.deleverageFee > p.bonus) revert InvalidParam("deleverageFee");
        if (p.deleverageMargin > MAX_DELEVERAGE_MARGIN) revert InvalidParam("deleverageMargin");
        if (p.preWindowHorizon < MIN_HORIZON || p.preWindowHorizon > MAX_HORIZON) revert InvalidParam("horizon");
        if (uint256(p.cureWindow) + MIN_DELEVERAGE_INTERVAL > p.preWindowHorizon) revert InvalidParam("cureWindow");
    }

    function _gap(Params memory p, uint8 cls) private pure returns (uint256) {
        return cls == 0 ? p.gapShort : cls == 1 ? p.gapWeekend : p.gapLong;
    }

    function _stressFraction(Params memory p, uint8 cls) private pure returns (uint256) {
        uint256 haircut = _gap(p, cls) + p.oracleBuffer + p.safetyBuffer;
        return haircut >= WAD ? 0 : WAD - haircut;
    }

    function _value(uint256 collateral, uint256 priceWad) private view returns (uint256) {
        return Math.mulDiv(collateral, priceWad, VALUE_SCALE);
    }

    /// @dev Account's liquidation threshold in loan units, rounded down (the account is liquidatable slightly
    /// earlier: against the borrower).
    function _threshold(uint256 cv, Params memory p, bool isBoosted) private pure returns (uint256) {
        return Math.mulDiv(cv, isBoosted ? p.boostedLltv : p.standardLltv, WAD);
    }

    /// @dev Stress period: the pre-window horizon, the blind window, and the reopening.
    function _stress(WindowState memory w, PriceStatus status, Params memory p) private view returns (bool) {
        if (w.blind) return true;
        if (status == PriceStatus.Reopening) return true;
        return w.start != 0 && block.timestamp + p.preWindowHorizon >= w.start;
    }

    /// @dev Deleverage zone: `[start - horizon + cure, start)`, Fresh price, Active market. Returns the zone
    /// flag, the stress cap in loan units (rounded down) and the cap fraction.
    function _deleverageZone(uint256 cv, uint256, PriceStatus status, Params memory p)
        private
        view
        returns (bool inZone, uint256 cap, uint256 capFrac)
    {
        if (status != PriceStatus.Fresh) return (false, 0, 0);
        if (address(market) == address(0) || market.state() != MarketState.Active) return (false, 0, 0);
        WindowState memory w = WINDOWS.peek();
        capFrac = Math.min(p.boostedLltv, _stressFraction(p, w.cls));
        cap = Math.mulDiv(cv, capFrac, WAD);
        inZone = !w.blind && w.start != 0 && block.timestamp + (p.preWindowHorizon - p.cureWindow) >= w.start;
    }

    /// @dev Smallest repay `R` that brings the debt to `(capFrac - margin)` of the remaining collateral value
    /// after seizing `R * (1 + fee)`: `R = ceil((D - floor(t*cv)) / (1 - t*(1+fee)))`, clamped to `D`. Rounded
    /// up: against the borrower.
    function _requiredRepay(uint256 cv, uint256 debt, uint256 capFrac, Params memory p) private pure returns (uint256) {
        uint256 t = capFrac > p.deleverageMargin ? capFrac - p.deleverageMargin : 0;
        uint256 target = Math.mulDiv(cv, t, WAD);
        if (debt <= target) return 0;
        uint256 growth = Math.mulDiv(t, WAD + p.deleverageFee, WAD, Math.Rounding.Ceil);
        if (growth >= WAD) return debt;
        uint256 r = Math.mulDiv(debt - target, WAD, WAD - growth, Math.Rounding.Ceil);
        return r > debt ? debt : r;
    }

    function _requireUsable(PriceData memory pd) private pure {
        if (
            pd.priceWad == 0 || pd.status == PriceStatus.Invalid || pd.status == PriceStatus.CorporateAction
                || pd.status == PriceStatus.SequencerDown
        ) revert PriceUnusable(uint8(pd.status));
    }
}
