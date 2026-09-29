// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {HaltReason, ISundownMarket, MarketParams, MarketState} from "./interfaces/ISundownMarket.sol";
import {AccountCtx, IRiskGuard} from "./interfaces/IRiskGuard.sol";
import {IEquityOracle, PriceData, PriceStatus} from "./interfaces/IEquityOracle.sol";
import {KinkedRate} from "./lib/KinkedRate.sol";
import {SharesMath} from "./lib/SharesMath.sol";

/// @title SundownMarket
/// @notice Isolated lending market (one collateral token, one loan token) that is also an ERC-4626 vault of the
/// loan token. Deployed as an ERC-1167 clone by {SundownMarketFactory}; no upgradeability; parameters are
/// immutable after `initialize`. The market contains NO session logic: all of it lives behind {IRiskGuard}.
/// @dev Design: docs/MARKET_DESIGN.md. Decisions D12-D17 in docs/DESIGN.md. Units: loan token is exactly 1 USD (D3);
/// prices are USD per whole collateral token in WAD; collateral value in loan units is
/// `floor(collateral * price / 10^(cDec + 18 - lDec))`. Rounding always favors the protocol: collateral value
/// down, debt up, seized collateral down, interest up. Fee-on-transfer and rebasing tokens are unsupported.
contract SundownMarket is ISundownMarket, Initializable, ERC4626Upgradeable, ReentrancyGuardTransient {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice 1e18 fixed point.
    uint256 public constant WAD = 1e18;
    /// @notice Accrual stays frozen for this long after a halt, then resumes by itself (D14).
    uint256 public constant MAX_FREEZE = 30 days;
    /// @notice Highest accepted liquidation threshold (98 %).
    uint256 public constant MAX_LLTV_WAD = 0.98e18;
    /// @notice Lowest accepted `maxBonusWad` (3 %, D15).
    uint256 public constant MIN_MAX_BONUS_WAD = 0.03e18;
    /// @notice Highest accepted `maxBonusWad` (5.5 %, D15).
    uint256 public constant MAX_MAX_BONUS_WAD = 0.055e18;
    /// @notice Highest accepted APR parameter (500 %).
    uint256 public constant MAX_APR_WAD = 5e18;
    /// @notice Gas allowance of each issuer-failure probe call.
    uint256 public constant PROBE_GAS = 250_000;
    /// @notice Gas that must be left when probing, so a caller cannot cause a false positive by starving a probe.
    uint256 public constant MIN_GAS_FOR_PROBES = 1_200_000;

    /// @notice Immutable configuration, written once in `initialize`.
    struct Config {
        address collateralToken;
        address oracle;
        address guard;
        address guardian;
        address governance;
        uint64 lltvWad;
        uint64 closeFactorWad;
        uint64 criticalHealthWad;
        uint64 maxBonusWad;
        uint128 collateralCap;
        uint128 minDebt;
        KinkedRate.Params irm;
        uint8 collateralDecimals;
        uint8 loanDecimals;
    }

    /// @notice A borrower position: debt shares and credited collateral.
    struct Position {
        uint128 borrowShares;
        uint128 collateral;
    }

    struct LiqPlan {
        uint256 repay;
        uint256 seized;
        uint256 bonusWad;
        uint256 sharesBurned;
    }

    Config private _cfg;
    /// @notice `10^(collateralDecimals + 18 - loanDecimals)`.
    uint256 private _valueScale;

    /// @notice Total debt of all borrowers in loan units, including accrued interest, net of realized bad debt.
    uint128 public totalBorrowAssets;
    /// @notice Total borrow shares.
    uint128 public totalBorrowShares;
    /// @notice Loan tokens held for lenders (ledger; donations are not credited).
    uint128 public idleAssets;
    /// @notice Cumulative bad debt written off (information; already netted out of `totalBorrowAssets`).
    uint128 public badDebtRealized;
    /// @notice Total collateral credited to positions (ledger).
    uint128 public totalCollateral;
    /// @notice Time up to which interest has been accrued.
    uint40 public lastAccrual;
    /// @notice Time of the current halt (0 when Active).
    uint40 public haltedAt;
    /// @notice Lifecycle state.
    MarketState public state;
    /// @notice Why the market is halted.
    HaltReason public haltReason;

    mapping(address account => Position) private _positions;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------ initialization

    /// @notice Initialize a freshly cloned market. Callable once, by the factory in the creating transaction.
    /// @param p Market parameters; validated here so any clone is safe regardless of its creator.
    function initialize(MarketParams calldata p) external initializer {
        _validate(p);
        uint8 cDec = IERC20Metadata(p.collateralToken).decimals();
        uint8 lDec = IERC20Metadata(p.loanToken).decimals();
        if (cDec > 18) revert InvalidParam("collateralDecimals");
        if (lDec > 18) revert InvalidParam("loanDecimals");

        __ERC20_init(p.shareName, p.shareSymbol);
        __ERC4626_init(IERC20(p.loanToken));

        _cfg = Config({
            collateralToken: p.collateralToken,
            oracle: p.oracle,
            guard: p.guard,
            guardian: p.guardian,
            governance: p.governance,
            lltvWad: p.lltvWad,
            closeFactorWad: p.closeFactorWad,
            criticalHealthWad: p.criticalHealthWad,
            maxBonusWad: p.maxBonusWad,
            collateralCap: p.collateralCap,
            minDebt: p.minDebt,
            irm: KinkedRate.Params(p.baseAprWad, p.slope1AprWad, p.slope2AprWad, p.kinkWad),
            collateralDecimals: cDec,
            loanDecimals: lDec
        });
        _valueScale = 10 ** (uint256(cDec) + 18 - uint256(lDec));
        lastAccrual = uint40(block.timestamp);
    }

    function _validate(MarketParams calldata p) private pure {
        if (
            p.collateralToken == address(0) || p.loanToken == address(0) || p.oracle == address(0)
                || p.guard == address(0) || p.guardian == address(0) || p.governance == address(0)
        ) revert ZeroAddress();
        if (p.collateralToken == p.loanToken) revert InvalidParam("tokens");
        if (p.lltvWad == 0 || p.lltvWad > MAX_LLTV_WAD) revert InvalidParam("lltv");
        if (p.closeFactorWad == 0 || p.closeFactorWad > WAD) revert InvalidParam("closeFactor");
        if (p.criticalHealthWad == 0 || p.criticalHealthWad >= WAD) revert InvalidParam("criticalHealth");
        if (p.maxBonusWad < MIN_MAX_BONUS_WAD || p.maxBonusWad > MAX_MAX_BONUS_WAD) revert InvalidParam("maxBonus");
        if (p.collateralCap == 0) revert InvalidParam("collateralCap");
        if (p.kinkWad == 0 || p.kinkWad >= WAD) revert InvalidParam("kink");
        if (p.baseAprWad > MAX_APR_WAD || p.slope1AprWad > MAX_APR_WAD || p.slope2AprWad > MAX_APR_WAD) {
            revert InvalidParam("apr");
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice Immutable configuration.
    function config() external view returns (Config memory) {
        return _cfg;
    }

    /// @inheritdoc ISundownMarket
    function debtOf(address account) external view returns (uint256) {
        return SharesMath.toAssetsUp(
            _positions[account].borrowShares, uint256(totalBorrowAssets) + _pendingInterest(), totalBorrowShares
        );
    }

    /// @inheritdoc ISundownMarket
    function collateralOf(address account) external view returns (uint256) {
        return _positions[account].collateral;
    }

    /// @notice Raw position of `account`.
    function positionOf(address account) external view returns (Position memory) {
        return _positions[account];
    }

    /// @notice Health factor (WAD) of `account` at the oracle's current price: `collateralValue * lltv / debt`.
    /// Uses `peek()`; returns `type(uint256).max` without debt.
    function healthFactor(address account) external view returns (uint256) {
        Position memory pos = _positions[account];
        uint256 debt =
            SharesMath.toAssetsUp(pos.borrowShares, uint256(totalBorrowAssets) + _pendingInterest(), totalBorrowShares);
        if (debt == 0) return type(uint256).max;
        PriceData memory p = IEquityOracle(_cfg.oracle).peek();
        uint256 cv = uint256(pos.collateral).mulDiv(p.priceWad, _valueScale);
        return cv.mulDiv(_cfg.lltvWad, debt);
    }

    // ------------------------------------------------------------------ ERC-4626 (lenders)

    /// @notice Assets managed by the vault: idle loan tokens plus all debt with accrued interest.
    function totalAssets() public view override returns (uint256) {
        return uint256(idleAssets) + totalBorrowAssets + _pendingInterest();
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(address) public view override returns (uint256) {
        return state == MarketState.Active ? type(uint256).max : 0;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(address) public view override returns (uint256) {
        return state == MarketState.Active ? type(uint256).max : 0;
    }

    /// @notice Shares redeemable now: bounded by the owner's balance and by the idle (lendable) assets.
    /// @dev OpenZeppelin v5 defines `maxWithdraw` as `previewRedeem(maxRedeem(owner))`, so this override also
    /// bounds `maxWithdraw` by the idle assets (`previewRedeem` rounds down, so it never exceeds idle).
    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), _convertToShares(idleAssets, Math.Rounding.Floor));
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        // no Active check here: `maxDeposit`/`maxMint` are 0 unless Active, so OpenZeppelin reverts first
        _accrue();
        IERC20 token = IERC20(asset());
        uint256 balanceBefore = token.balanceOf(address(this));
        super._deposit(caller, receiver, assets, shares);
        if (token.balanceOf(address(this)) - balanceBefore != assets) revert UnsupportedToken();
        idleAssets += assets.toUint128();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        _accrue();
        // `maxWithdraw`/`maxRedeem` bound `assets` by idleAssets, so this subtraction cannot underflow
        idleAssets -= assets.toUint128();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ------------------------------------------------------------------ collateral

    /// @inheritdoc ISundownMarket
    function depositCollateral(uint256 amount, address onBehalf) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();
        uint256 newTotal = uint256(totalCollateral) + amount;
        if (newTotal > _cfg.collateralCap) revert CollateralCapExceeded(newTotal, _cfg.collateralCap);
        totalCollateral = newTotal.toUint128();
        _positions[onBehalf].collateral += amount.toUint128();
        _pullExact(_cfg.collateralToken, msg.sender, amount);
        emit CollateralDeposited(msg.sender, onBehalf, amount);
    }

    /// @inheritdoc ISundownMarket
    function withdrawCollateral(uint256 amount, address receiver) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (state != MarketState.Active) revert NotActive();
        _accrue();
        Position storage pos = _positions[msg.sender];
        if (amount > pos.collateral) revert InsufficientCollateral(amount, pos.collateral);
        pos.collateral -= amount.toUint128();
        totalCollateral -= amount.toUint128();
        uint256 debt = SharesMath.toAssetsUp(pos.borrowShares, totalBorrowAssets, totalBorrowShares);
        if (debt != 0) _checkCapacity(msg.sender, pos.collateral, debt);
        IERC20(_cfg.collateralToken).safeTransfer(receiver, amount);
        emit CollateralWithdrawn(msg.sender, receiver, amount);
    }

    // ------------------------------------------------------------------ borrow and repay

    /// @inheritdoc ISundownMarket
    function borrow(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (state != MarketState.Active) revert NotActive();
        _accrue();
        if (assets > idleAssets) revert InsufficientIdle(assets, idleAssets);

        shares = SharesMath.toSharesUp(assets, totalBorrowAssets, totalBorrowShares);
        Position storage pos = _positions[msg.sender];
        pos.borrowShares += shares.toUint128();
        totalBorrowShares += shares.toUint128();
        totalBorrowAssets += assets.toUint128();
        idleAssets -= assets.toUint128();

        uint256 debt = SharesMath.toAssetsUp(pos.borrowShares, totalBorrowAssets, totalBorrowShares);
        AccountCtx memory c = _checkCapacity(msg.sender, pos.collateral, debt);
        IRiskGuard(_cfg.guard).onBorrow(c, assets);

        IERC20(asset()).safeTransfer(receiver, assets);
        emit Borrowed(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc ISundownMarket
    function repay(uint256 assets, address onBehalf)
        external
        nonReentrant
        returns (uint256 assetsPaid, uint256 sharesBurned)
    {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        Position storage pos = _positions[onBehalf];
        uint256 debt = SharesMath.toAssetsUp(pos.borrowShares, totalBorrowAssets, totalBorrowShares);
        if (debt == 0) revert NothingToRepay();
        if (assets >= debt) {
            sharesBurned = pos.borrowShares;
            assetsPaid = debt;
        } else {
            sharesBurned = SharesMath.toSharesDown(assets, totalBorrowAssets, totalBorrowShares);
            assetsPaid = assets;
        }
        _applyRepay(pos, onBehalf, sharesBurned, assetsPaid);
    }

    /// @inheritdoc ISundownMarket
    function repayShares(uint256 shares, address onBehalf) external nonReentrant returns (uint256 assetsPaid) {
        if (shares == 0) revert ZeroAmount();
        _accrue();
        Position storage pos = _positions[onBehalf];
        if (pos.borrowShares == 0) revert NothingToRepay();
        if (shares > pos.borrowShares) shares = pos.borrowShares;
        assetsPaid = SharesMath.toAssetsUp(shares, totalBorrowAssets, totalBorrowShares);
        _applyRepay(pos, onBehalf, shares, assetsPaid);
    }

    function _applyRepay(Position storage pos, address onBehalf, uint256 shares, uint256 assetsPaid) private {
        pos.borrowShares -= shares.toUint128();
        totalBorrowShares -= shares.toUint128();
        totalBorrowAssets = assetsPaid >= totalBorrowAssets ? 0 : totalBorrowAssets - assetsPaid.toUint128();
        idleAssets += assetsPaid.toUint128();
        uint256 rest = SharesMath.toAssetsUp(pos.borrowShares, totalBorrowAssets, totalBorrowShares);
        if (rest != 0 && rest < _cfg.minDebt) revert BelowMinDebt(rest, _cfg.minDebt);
        _pullExact(asset(), msg.sender, assetsPaid);
        emit Repaid(msg.sender, onBehalf, assetsPaid, shares);
    }

    // ------------------------------------------------------------------ liquidation and bad debt

    /// @inheritdoc ISundownMarket
    function liquidate(address borrower, uint256 repayAssets, address receiver)
        external
        nonReentrant
        returns (uint256 repaid, uint256 seized)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (repayAssets == 0) revert ZeroAmount();
        _accrue();
        Position storage pos = _positions[borrower];
        uint256 debt = SharesMath.toAssetsUp(pos.borrowShares, totalBorrowAssets, totalBorrowShares);
        if (debt == 0) revert NoDebt();

        PriceData memory p = _price();
        AccountCtx memory c = _ctx(borrower, pos.collateral, debt, p);
        if (!IRiskGuard(_cfg.guard).liquidationAllowed(c)) revert NotLiquidatable();

        LiqPlan memory plan = _planLiquidation(c, pos.borrowShares, repayAssets);

        pos.borrowShares -= plan.sharesBurned.toUint128();
        totalBorrowShares -= plan.sharesBurned.toUint128();
        totalBorrowAssets = plan.repay >= totalBorrowAssets ? 0 : totalBorrowAssets - plan.repay.toUint128();
        pos.collateral -= plan.seized.toUint128();
        totalCollateral -= plan.seized.toUint128();
        idleAssets += plan.repay.toUint128();

        _pullExact(asset(), msg.sender, plan.repay);
        IERC20(_cfg.collateralToken).safeTransfer(receiver, plan.seized);
        IRiskGuard(_cfg.guard).onLiquidate(c, msg.sender, plan.repay, plan.seized);

        emit Liquidated(msg.sender, borrower, receiver, plan.repay, plan.seized, plan.bonusWad);
        return (plan.repay, plan.seized);
    }

    /// @dev Close factor, dust rule, bonus cap, non-worsening cap and collateral cap (docs/MARKET_DESIGN.md 7.5).
    function _planLiquidation(AccountCtx memory c, uint256 borrowShares, uint256 repayAssets)
        private
        view
        returns (LiqPlan memory plan)
    {
        uint256 debt = c.debtAssets;
        uint256 maxRepay = debt.mulDiv(_cfg.closeFactorWad, WAD, Math.Rounding.Ceil);
        // health factor = collateralValue * lltv / debt; below the critical health the whole debt may be repaid
        if (c.collateralValue.mulDiv(_cfg.lltvWad, WAD) * WAD < uint256(_cfg.criticalHealthWad) * debt) {
            maxRepay = debt;
        }
        uint256 rp = Math.min(Math.min(repayAssets, maxRepay), debt);
        uint256 rest = debt - rp;
        if (rest != 0 && rest < _cfg.minDebt) rp = debt;

        uint256 b = Math.min(IRiskGuard(_cfg.guard).liquidationBonus(c, rp), _cfg.maxBonusWad);
        if (c.collateralValue > debt) {
            // never seize more value than keeps the loan-to-value from rising: b <= collateralValue/debt - 1
            b = Math.min(b, c.collateralValue.mulDiv(WAD, debt) - WAD);
        }

        uint256 seized = rp.mulDiv(WAD + b, WAD).mulDiv(_valueScale, c.priceWad);
        if (seized > c.collateral) {
            seized = c.collateral;
            rp = seized.mulDiv(c.priceWad, _valueScale).mulDiv(WAD, WAD + b);
        }
        if (rp == 0) revert ZeroAmount();

        plan.repay = rp;
        plan.seized = seized;
        plan.bonusWad = b;
        plan.sharesBurned = rp >= debt
            ? borrowShares
            : Math.min(SharesMath.toSharesDown(rp, totalBorrowAssets, totalBorrowShares), borrowShares);
    }

    /// @inheritdoc ISundownMarket
    function realizeBadDebt(address borrower) external nonReentrant returns (uint256 written) {
        _accrue();
        Position storage pos = _positions[borrower];
        if (pos.collateral != 0) revert HasCollateral();
        uint256 shares = pos.borrowShares;
        if (shares == 0) revert NoDebt();
        written = Math.min(SharesMath.toAssetsUp(shares, totalBorrowAssets, totalBorrowShares), totalBorrowAssets);
        pos.borrowShares = 0;
        totalBorrowShares -= shares.toUint128();
        totalBorrowAssets -= written.toUint128();
        badDebtRealized += written.toUint128();
        emit BadDebtRealized(borrower, written, totalAssets());
    }

    // ------------------------------------------------------------------ accrual

    /// @inheritdoc ISundownMarket
    function accrue() external nonReentrant {
        _accrue();
    }

    function _accrualStart() private view returns (uint256 start) {
        start = lastAccrual;
        if (state == MarketState.Halted) {
            uint256 unfreeze = uint256(haltedAt) + MAX_FREEZE;
            if (unfreeze > start) start = unfreeze;
        }
    }

    function _pendingInterest() private view returns (uint256) {
        uint256 start = _accrualStart();
        if (block.timestamp <= start || totalBorrowAssets == 0) return 0;
        uint256 debt = totalBorrowAssets;
        uint256 utilWad = debt.mulDiv(WAD, uint256(idleAssets) + debt);
        uint256 f = KinkedRate.compoundFactor(KinkedRate.ratePerSecond(_cfg.irm, utilWad), block.timestamp - start);
        return debt.mulDiv(f, WAD, Math.Rounding.Ceil);
    }

    function _accrue() private {
        uint256 interest = _pendingInterest();
        if (interest != 0) {
            totalBorrowAssets += interest.toUint128();
            emit Accrued(interest, totalBorrowAssets);
        }
        lastAccrual = uint40(block.timestamp);
    }

    // ------------------------------------------------------------------ halt (guardian / governance)

    /// @inheritdoc ISundownMarket
    function guardianHalt() external nonReentrant {
        if (msg.sender != _cfg.guardian) revert Unauthorized();
        if (state == MarketState.Halted) revert AlreadyHalted();
        _accrue();
        state = MarketState.Halted;
        haltReason = HaltReason.Guardian;
        haltedAt = uint40(block.timestamp);
        emit MarketHalted(HaltReason.Guardian, msg.sender);
    }

    /// @inheritdoc ISundownMarket
    function resume() external nonReentrant {
        if (state != MarketState.Halted) revert NotHalted();
        if (msg.sender == _cfg.governance) {
            // unconditional
        } else if (msg.sender == _cfg.guardian) {
            if (!_probesPass()) revert ProbesFailing();
        } else {
            revert Unauthorized();
        }
        _accrue(); // books interest from day 30 of the halt (D14)
        uint256 haltedFor = block.timestamp - haltedAt;
        state = MarketState.Active;
        haltReason = HaltReason.None;
        haltedAt = 0;
        emit MarketResumed(msg.sender, haltedFor);
    }

    function _probesPass() private returns (bool) {
        return _runProbes() == HaltReason.None;
    }

    // ------------------------------------------------------------------ issuer-failure probes (D2, D13)

    /// @inheritdoc ISundownMarket
    function reportIssuerFailure() external nonReentrant returns (HaltReason reason) {
        if (state == MarketState.Halted) return haltReason;
        reason = _runProbes();
        if (reason != HaltReason.None) {
            _accrue();
            state = MarketState.Halted;
            haltReason = reason;
            haltedAt = uint40(block.timestamp);
            emit MarketHalted(reason, msg.sender);
        }
    }

    /// @dev Probes the collateral and loan tokens. Every external probe is gas-capped and failure-tolerant: a
    /// function that does not exist (older token versions, tokens without `paused()`) is simply not a failure.
    /// Order: collateral pause, collateral blocklist (the registry holds it on Robinhood tokens), collateral
    /// shortfall (`adminBurn` leaves the ledger above the real balance), a 1-wei self-transfer through the exact
    /// pause and blocklist modifiers, then the same for the loan token (pause, freeze, self-transfer).
    function _runProbes() private returns (HaltReason) {
        if (gasleft() < MIN_GAS_FOR_PROBES) revert InsufficientGas();
        address col = _cfg.collateralToken;
        address loan = asset();

        if (_staticFlag(col, abi.encodeWithSignature("paused()"))) return HaltReason.CollateralPaused;
        address registry = _staticAddress(col, abi.encodeWithSignature("ACCESS_CONTROLLED_REGISTRY()"));
        if (
            registry != address(0)
                && _staticFlag(registry, abi.encodeWithSignature("isBlocked(address)", address(this)))
        ) {
            return HaltReason.CollateralBlocked;
        }
        (bool ok, uint256 balance) = _staticBalance(col);
        if (!ok) return HaltReason.ProbeFailure;
        if (balance < totalCollateral) return HaltReason.CollateralShortfall;
        if (balance != 0 && !_selfTransferWorks(col)) return HaltReason.ProbeFailure;

        if (_staticFlag(loan, abi.encodeWithSignature("paused()"))) return HaltReason.LoanPaused;
        if (_staticFlag(loan, abi.encodeWithSignature("isFrozen(address)", address(this)))) {
            return HaltReason.LoanFrozen;
        }
        (ok, balance) = _staticBalance(loan);
        if (!ok) return HaltReason.ProbeFailure;
        if (balance != 0 && !_selfTransferWorks(loan)) return HaltReason.ProbeFailure;
        return HaltReason.None;
    }

    function _staticFlag(address target, bytes memory data) private view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall{gas: PROBE_GAS}(data);
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) == 1;
    }

    function _staticAddress(address target, bytes memory data) private view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall{gas: PROBE_GAS}(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 v = abi.decode(ret, (uint256));
        return v <= type(uint160).max ? address(uint160(v)) : address(0);
    }

    function _staticBalance(address token) private view returns (bool ok, uint256 balance) {
        bytes memory ret;
        (ok, ret) = token.staticcall{gas: PROBE_GAS}(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev A 1-wei transfer from the market to itself: it goes through the token's pause and blocklist checks for
    /// sender and receiver with no net balance change. Accepts tokens that return nothing (USDT-style).
    function _selfTransferWorks(address token) private returns (bool) {
        (bool ok, bytes memory ret) = token.call{gas: PROBE_GAS}(abi.encodeCall(IERC20.transfer, (address(this), 1)));
        return ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1));
    }

    // ------------------------------------------------------------------ internals

    function _price() private returns (PriceData memory p) {
        p = IEquityOracle(_cfg.oracle).price();
        if (
            p.priceWad == 0 || p.status == PriceStatus.Invalid || p.status == PriceStatus.CorporateAction
                || p.status == PriceStatus.SequencerDown
        ) revert PriceUnusable(uint8(p.status));
    }

    function _ctx(address account, uint256 collateral_, uint256 debt_, PriceData memory p)
        private
        view
        returns (AccountCtx memory c)
    {
        c.account = account;
        c.collateral = collateral_;
        c.debtAssets = debt_;
        c.priceWad = p.priceWad;
        c.haircutWad = p.haircutWad;
        c.updatedAt = p.updatedAt;
        c.windowId = p.windowId;
        c.status = p.status;
        c.lltvWad = _cfg.lltvWad;
        c.totalBorrowAssets = totalBorrowAssets;
        c.totalAssets = totalAssets();
        c.collateralValue = collateral_.mulDiv(p.priceWad, _valueScale);
    }

    /// @dev Post-state capacity check for borrow and collateral withdrawal: debt must not exceed
    /// `min(guard.maxBorrowable, collateralValue * lltv)` and must not be dust.
    function _checkCapacity(address account, uint256 collateral_, uint256 debt_) private returns (AccountCtx memory c) {
        PriceData memory p = _price();
        c = _ctx(account, collateral_, debt_, p);
        uint256 cap = Math.min(IRiskGuard(_cfg.guard).maxBorrowable(c), c.collateralValue.mulDiv(_cfg.lltvWad, WAD));
        if (debt_ > cap) revert ExceedsCapacity(debt_, cap);
        if (debt_ < _cfg.minDebt) revert BelowMinDebt(debt_, _cfg.minDebt);
    }

    function _pullExact(address token, address from, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - balanceBefore != amount) revert UnsupportedToken();
    }
}
