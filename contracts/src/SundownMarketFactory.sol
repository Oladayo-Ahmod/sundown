// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {MarketParams} from "./interfaces/ISundownMarket.sol";
import {SundownMarket} from "./SundownMarket.sol";

/// @title SundownMarketFactory
/// @notice Creates {SundownMarket} ERC-1167 clones. Creation is owner-only (decision A3): permissionless
/// creation would invite fake markets and fake guards; the UI lists factory-registered markets only. One market
/// per unique parameter set (the clone address is derived from the parameters), so the address can be predicted
/// before creation. Parameter validation lives in `SundownMarket.initialize` (single source).
contract SundownMarketFactory is Ownable2Step {
    /// @notice The market implementation that clones delegate to (initializers locked).
    address public immutable IMPLEMENTATION;

    /// @notice Whether `market` was created by this factory.
    mapping(address market => bool) public isMarket;

    address[] private _markets;

    /// @notice A market was created.
    event MarketCreated(
        address indexed market,
        bytes32 indexed paramsHash,
        address collateralToken,
        address loanToken,
        address guard,
        address oracle
    );

    /// @notice The implementation address is zero.
    error ZeroAddress();

    /// @param implementation Deployed {SundownMarket} implementation.
    /// @param owner_ Owner (intended: a timelock) allowed to create markets.
    constructor(address implementation, address owner_) Ownable(owner_) {
        if (implementation == address(0)) revert ZeroAddress();
        IMPLEMENTATION = implementation;
    }

    /// @notice Create and initialize a market.
    /// @param p Market parameters (validated by the market).
    /// @return market The new market (clone) address.
    function createMarket(MarketParams calldata p) external onlyOwner returns (address market) {
        bytes32 salt = keccak256(abi.encode(p));
        market = Clones.cloneDeterministic(IMPLEMENTATION, salt);
        isMarket[market] = true;
        _markets.push(market);
        emit MarketCreated(market, salt, p.collateralToken, p.loanToken, p.guard, p.oracle);
        // initialize last: it reverts (undoing the registration) on invalid parameters
        SundownMarket(market).initialize(p);
    }

    /// @notice Address a market with parameters `p` would have.
    /// @param p Market parameters.
    function predictMarket(MarketParams calldata p) external view returns (address) {
        return Clones.predictDeterministicAddress(IMPLEMENTATION, keccak256(abi.encode(p)), address(this));
    }

    /// @notice Number of markets created.
    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    /// @notice Market at `index`.
    /// @param index Index in creation order.
    function marketAt(uint256 index) external view returns (address) {
        return _markets[index];
    }
}
