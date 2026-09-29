// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockIssuerRegistry
/// @notice TEST FIXTURE. Models Robinhood's `AccessControlsRegistry`: a global pause and a blocklist.
contract MockIssuerRegistry {
    bool public paused;
    mapping(address => bool) public isBlocked;

    function setPaused(bool on) external {
        paused = on;
    }

    function setBlocked(address account, bool on) external {
        isBlocked[account] = on;
    }
}

/// @title MockStockIssuerToken
/// @notice TEST FIXTURE. An 18-decimal token with the issuer controls of a Robinhood stock token: a token-level
/// pause or the registry-wide pause, a registry blocklist checked on `from`, `to` and the caller, and an
/// `adminBurn` that ignores every restriction. `ACCESS_CONTROLLED_REGISTRY()` and `paused()` mirror the real names.
contract MockStockIssuerToken is ERC20 {
    MockIssuerRegistry public immutable REGISTRY;
    bool public tokenPaused;

    constructor(MockIssuerRegistry registry_) ERC20("Stock", "STK") {
        REGISTRY = registry_;
    }

    function ACCESS_CONTROLLED_REGISTRY() external view returns (address) {
        return address(REGISTRY);
    }

    function paused() public view returns (bool) {
        return tokenPaused || REGISTRY.paused();
    }

    function setTokenPaused(bool on) external {
        tokenPaused = on;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function adminBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(!paused(), "IsPaused");
            require(
                !REGISTRY.isBlocked(from) && !REGISTRY.isBlocked(to) && !REGISTRY.isBlocked(_msgSender()), "Blocked"
            );
        }
        super._update(from, to, value);
    }
}

/// @title MockUsdgToken
/// @notice TEST FIXTURE. A 6-decimal token like USDG: `paused()` and `isFrozen(address)` but no registry.
contract MockUsdgToken is ERC20 {
    bool public paused;
    mapping(address => bool) public isFrozen;

    constructor() ERC20("USD", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool on) external {
        paused = on;
    }

    function setFrozen(address account, bool on) external {
        isFrozen[account] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(!paused, "paused");
            require(!isFrozen[from] && !isFrozen[to], "frozen");
        }
        super._update(from, to, value);
    }
}

/// @title MockBrickableToken
/// @notice TEST FIXTURE. A plain token with no `paused()` and no registry whose transfers can be switched off,
/// to prove the 1-wei self-transfer probe catches failures that no flag reveals.
contract MockBrickableToken is ERC20 {
    uint8 private immutable _DECIMALS;
    bool public bricked;

    constructor(uint8 decimals_) ERC20("Brick", "BRK") {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBricked(bool on) external {
        bricked = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) require(!bricked, "bricked");
        super._update(from, to, value);
    }
}

/// @title MockGuzzlerToken
/// @notice TEST FIXTURE. `transfer` (not `transferFrom`) burns all gas when armed, to prove the probe's gas cap
/// turns a hostile token into a ProbeFailure instead of bricking `reportIssuerFailure`.
contract MockGuzzlerToken is ERC20 {
    bool public guzzle;
    uint256 private _sink;

    constructor() ERC20("Guzzler", "GZL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setGuzzle(bool on) external {
        guzzle = on;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (guzzle) {
            while (true) {
                ++_sink;
            }
        }
        return super.transfer(to, value);
    }
}

/// @title MockNoReturnToken
/// @notice TEST FIXTURE. USDT-style token: `transfer` and `transferFrom` return no data.
contract MockNoReturnToken {
    string public constant name = "NoReturn";
    string public constant symbol = "NRT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @title MockReturnsFalseToken
/// @notice TEST FIXTURE. `transfer` and `transferFrom` return false instead of reverting (and move nothing) when
/// armed.
contract MockReturnsFalseToken is ERC20 {
    bool public failing;

    constructor() ERC20("False", "FLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailing(bool on) external {
        failing = on;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failing) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failing) return false;
        return super.transferFrom(from, to, value);
    }
}

/// @title MockReentrantToken
/// @notice TEST FIXTURE. When armed, every `transfer` and `transferFrom` first tries to re-enter `target` with
/// `data` and records whether that re-entrant call succeeded (it must not: the market is `nonReentrant`).
contract MockReentrantToken is ERC20 {
    uint8 private immutable _DECIMALS;
    address public target;
    bytes public data;
    uint256 public attempts;
    uint256 public successes;

    constructor(uint8 decimals_) ERC20("Reenter", "RNT") {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function disarm() external {
        target = address(0);
    }

    function _reenter() private {
        if (target == address(0)) return;
        ++attempts;
        (bool ok,) = target.call(data);
        if (ok) ++successes;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _reenter();
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _reenter();
        return super.transferFrom(from, to, value);
    }
}
