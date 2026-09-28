// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Immutable parameters of a market (see docs/MARKET_DESIGN.md section 3).
struct MarketParams {
    address collateralToken;
    address loanToken;
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
    uint64 baseAprWad;
    uint64 slope1AprWad;
    uint64 slope2AprWad;
    uint64 kinkWad;
    string shareName;
    string shareSymbol;
}

/// @notice Market lifecycle state.
enum MarketState {
    Active,
    Halted
}

/// @notice Why a market is halted.
enum HaltReason {
    None,
    Guardian,
    CollateralPaused,
    CollateralBlocked,
    LoanPaused,
    LoanFrozen,
    CollateralShortfall,
    ProbeFailure
}

/// @title ISundownMarket
/// @notice Position, liquidation and halt interface of a Sundown market. The ERC-4626 vault interface of the
/// same contract is not repeated here.
interface ISundownMarket {
    event CollateralDeposited(address indexed caller, address indexed onBehalf, uint256 amount);
    event CollateralWithdrawn(address indexed account, address indexed receiver, uint256 amount);
    event Borrowed(address indexed account, address indexed receiver, uint256 assets, uint256 shares);
    event Repaid(address indexed payer, address indexed onBehalf, uint256 assets, uint256 shares);
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address receiver,
        uint256 repaid,
        uint256 seized,
        uint256 bonusWad
    );
    event BadDebtRealized(address indexed borrower, uint256 written, uint256 newTotalAssets);
    event Accrued(uint256 interest, uint256 newTotalBorrowAssets);
    event MarketHalted(HaltReason indexed reason, address indexed by);
    event MarketResumed(address indexed by, uint256 haltedFor);

    error InvalidParam(bytes32 field);
    error NotActive();
    error NotHalted();
    error AlreadyHalted();
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientIdle(uint256 requested, uint256 idle);
    error InsufficientCollateral(uint256 requested, uint256 available);
    error CollateralCapExceeded(uint256 total, uint256 cap);
    error ExceedsCapacity(uint256 debt, uint256 capacity);
    error BelowMinDebt(uint256 debt, uint256 minDebt);
    error PriceUnusable(uint8 status);
    error NoDebt();
    error NotLiquidatable();
    error NothingToRepay();
    error HasCollateral();
    error UnsupportedToken();
    error ProbesFailing();

    function depositCollateral(uint256 amount, address onBehalf) external;
    function withdrawCollateral(uint256 amount, address receiver) external;
    function borrow(uint256 assets, address receiver) external returns (uint256 shares);
    function repay(uint256 assets, address onBehalf) external returns (uint256 assetsPaid, uint256 sharesBurned);
    function repayShares(uint256 shares, address onBehalf) external returns (uint256 assetsPaid);
    function liquidate(address borrower, uint256 repayAssets, address receiver)
        external
        returns (uint256 repaid, uint256 seized);
    function realizeBadDebt(address borrower) external returns (uint256 written);
    function accrue() external;
    function guardianHalt() external;
    function resume() external;

    function debtOf(address account) external view returns (uint256);
    function collateralOf(address account) external view returns (uint256);
}
