// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SimIssuerRegistry
/// @notice ***SIMULATION ONLY.*** Models the issuer's access-control registry of the real Robinhood stock tokens: a
/// global pause and a per-address blocklist, both set by the owner. It exists so the issuer-failure halt can be
/// demonstrated on a chain that has no real issuer tokens. It is not the real registry.
contract SimIssuerRegistry is Ownable {
    /// @notice Always true: lets scripts and UIs refuse to treat this as the real registry.
    bool public constant IS_SIMULATION = true;

    /// @notice Registry-wide pause; every SimStock transfer reverts while it is set.
    bool public paused;
    /// @notice Per-address block; a SimStock transfer reverts if the sender, receiver or caller is blocked.
    mapping(address account => bool) public isBlocked;

    event PausedSet(bool on);
    event BlockedSet(address indexed account, bool on);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Sets the registry-wide pause.
    /// @param on New value.
    function setPaused(bool on) external onlyOwner {
        paused = on;
        emit PausedSet(on);
    }

    /// @notice Blocks or unblocks an address.
    /// @param account The address.
    /// @param on New value.
    function setBlocked(address account, bool on) external onlyOwner {
        isBlocked[account] = on;
        emit BlockedSet(account, on);
    }
}

/// @title SimStock
/// @notice ***SIMULATION ONLY. NOT A REAL TOKENIZED STOCK.*** An 18-decimal test token with a public faucet (a
/// cumulative per-address limit) and the issuer-control surface of the real Robinhood stock token that the Sundown
/// market probes: `paused()` (token-level or registry-wide), `ACCESS_CONTROLLED_REGISTRY()` with a blocklist checked
/// on sender, receiver and caller, and the corporate-action getters the oracle adapter reads. It has no `adminBurn`.
contract SimStock is ERC20, Ownable {
    /// @notice Always true.
    bool public constant IS_SIMULATION = true;
    /// @notice Registry holding the global pause and the blocklist.
    SimIssuerRegistry public immutable REGISTRY;
    /// @notice Most one address can ever claim from the faucet (18 decimals).
    uint256 public immutable FAUCET_LIMIT;

    /// @notice Token-level pause set by the owner.
    bool public tokenPaused;
    /// @notice Corporate-action pause flag read by the oracle adapter.
    bool public oraclePaused;
    /// @notice Current UI multiplier (always 1e18 here).
    uint256 public constant uiMultiplier = 1e18;
    /// @notice Pending UI multiplier (equal to the current one: no corporate action).
    uint256 public constant newUIMultiplier = 1e18;
    /// @notice Effective time of a pending multiplier change (none).
    uint256 public constant effectiveAt = 0;
    /// @notice Faucet total claimed per address.
    mapping(address account => uint256) public claimed;

    event Faucet(address indexed account, uint256 amount, uint256 claimedTotal);
    event TokenPausedSet(bool on);
    event OraclePausedSet(bool on);

    /// @notice The faucet limit for this address is exhausted.
    error FaucetLimit(uint256 claimed, uint256 requested, uint256 limit);
    /// @notice A transfer was attempted while the token or the registry is paused.
    error IsPaused();
    /// @notice A transfer touched a blocked address.
    error Blocked(address account);

    /// @param name_ Token name (should say simulation).
    /// @param symbol_ Token symbol, prefixed "s".
    /// @param registry_ Issuer registry.
    /// @param owner_ Owner (pause and oracle flags).
    /// @param faucetLimit_ Cumulative per-address faucet limit.
    constructor(string memory name_, string memory symbol_, SimIssuerRegistry registry_, address owner_, uint256 faucetLimit_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {
        REGISTRY = registry_;
        FAUCET_LIMIT = faucetLimit_;
    }

    /// @notice Registry address, under the real token's getter name.
    function ACCESS_CONTROLLED_REGISTRY() external view returns (address) {
        return address(REGISTRY);
    }

    /// @notice True if the token or the registry is paused.
    function paused() public view returns (bool) {
        return tokenPaused || REGISTRY.paused();
    }

    /// @notice Claims test tokens, up to the cumulative per-address limit.
    /// @param amount Amount to mint to the caller (18 decimals).
    function faucet(uint256 amount) external {
        uint256 total = claimed[msg.sender] + amount;
        if (total > FAUCET_LIMIT) revert FaucetLimit(claimed[msg.sender], amount, FAUCET_LIMIT);
        claimed[msg.sender] = total;
        _mint(msg.sender, amount);
        emit Faucet(msg.sender, amount, total);
    }

    /// @notice Owner: pause or unpause token transfers.
    /// @param on New value.
    function setTokenPaused(bool on) external onlyOwner {
        tokenPaused = on;
        emit TokenPausedSet(on);
    }

    /// @notice Owner: set the oracle-pause (corporate action) flag.
    /// @param on New value.
    function setOraclePaused(bool on) external onlyOwner {
        oraclePaused = on;
        emit OraclePausedSet(on);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (paused()) revert IsPaused();
            if (REGISTRY.isBlocked(from)) revert Blocked(from);
            if (REGISTRY.isBlocked(to)) revert Blocked(to);
            if (REGISTRY.isBlocked(_msgSender())) revert Blocked(_msgSender());
        }
        super._update(from, to, value);
    }
}

/// @title SimUSDG
/// @notice ***SIMULATION ONLY. NOT USDG.*** A 6-decimal test token with a public faucet (a cumulative per-address
/// limit) and the loan-token surface the Sundown market probes on USDG: `paused()` and `isFrozen(address)`.
contract SimUSDG is ERC20, Ownable {
    /// @notice Always true.
    bool public constant IS_SIMULATION = true;
    /// @notice Most one address can ever claim from the faucet (6 decimals).
    uint256 public immutable FAUCET_LIMIT;

    /// @notice Token-wide pause.
    bool public paused;
    /// @notice Per-address freeze.
    mapping(address account => bool) public isFrozen;
    /// @notice Faucet total claimed per address.
    mapping(address account => uint256) public claimed;

    event Faucet(address indexed account, uint256 amount, uint256 claimedTotal);
    event PausedSet(bool on);
    event FrozenSet(address indexed account, bool on);

    /// @notice The faucet limit for this address is exhausted.
    error FaucetLimit(uint256 claimed, uint256 requested, uint256 limit);
    /// @notice A transfer was attempted while the token is paused.
    error IsPaused();
    /// @notice A transfer touched a frozen address.
    error Frozen(address account);

    /// @param owner_ Owner (pause and freeze).
    /// @param faucetLimit_ Cumulative per-address faucet limit (6 decimals).
    constructor(address owner_, uint256 faucetLimit_) ERC20("SIM USD (simulation)", "sUSDG") Ownable(owner_) {
        FAUCET_LIMIT = faucetLimit_;
    }

    /// @notice 6 decimals, like USDG.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Claims test tokens, up to the cumulative per-address limit.
    /// @param amount Amount to mint to the caller (6 decimals).
    function faucet(uint256 amount) external {
        uint256 total = claimed[msg.sender] + amount;
        if (total > FAUCET_LIMIT) revert FaucetLimit(claimed[msg.sender], amount, FAUCET_LIMIT);
        claimed[msg.sender] = total;
        _mint(msg.sender, amount);
        emit Faucet(msg.sender, amount, total);
    }

    /// @notice Owner: pause or unpause transfers.
    /// @param on New value.
    function setPaused(bool on) external onlyOwner {
        paused = on;
        emit PausedSet(on);
    }

    /// @notice Owner: freeze or unfreeze an address.
    /// @param account The address.
    /// @param on New value.
    function setFrozen(address account, bool on) external onlyOwner {
        isFrozen[account] = on;
        emit FrozenSet(account, on);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (paused) revert IsPaused();
            if (isFrozen[from]) revert Frozen(from);
            if (isFrozen[to]) revert Frozen(to);
        }
        super._update(from, to, value);
    }
}
