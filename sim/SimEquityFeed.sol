// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SimEquityFeed
/// @notice ***SIMULATION ONLY. NOT A CHAINLINK FEED. NOT AN ORACLE INTEGRATION.***
/// An AggregatorV3-shaped feed whose answers are pushed by a keeper from simulated or replayed data (for example
/// `sim/replay_events.json`). It exists so the Sundown markets can be deployed and demonstrated on chains that have
/// no real stock-token feeds (Arbitrum Sepolia). It performs no aggregation, no staleness logic and no schedule: the
/// keeper decides when to publish, so a replay can reproduce deviation-triggered updates and blind windows.
/// Nothing in `contracts/src` imports this file, and it must never appear in a Robinhood mainnet deployment
/// config (the `ChainlinkEquityOracle` adapter is the production path and is only claimed integrated after a
/// fork test against the real feeds).
contract SimEquityFeed {
    /// @notice Always true: lets scripts and UIs refuse to treat this as a real feed.
    bool public constant IS_SIMULATION = true;
    /// @notice Same decimals as the Chainlink USD equity feeds on Robinhood Chain.
    uint8 public constant decimals = 8;
    /// @notice Aggregator version (Chainlink-compatible field).
    uint256 public constant version = 1;

    /// @notice Address allowed to publish simulated answers (the replay driver).
    address public immutable KEEPER;
    /// @notice Human-readable description, prefixed `SIM`.
    string public description;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    /// @notice A simulated answer was published.
    event SimAnswerUpdated(int256 indexed answer, uint256 indexed roundId, uint256 updatedAt);

    /// @notice Caller is not the keeper.
    error NotKeeper();
    /// @notice The first answer must be positive.
    error InvalidAnswer();

    /// @param keeper Replay driver address.
    /// @param description_ Description, for example "SIM TSLA / USD (simulation)".
    /// @param initialAnswer First simulated answer, 8 decimals.
    constructor(address keeper, string memory description_, int256 initialAnswer) {
        if (initialAnswer <= 0) revert InvalidAnswer();
        KEEPER = keeper;
        description = description_;
        _publish(initialAnswer);
    }

    /// @notice Publish a simulated answer stamped with the current block time.
    /// @param answer New answer, 8 decimals.
    function publish(int256 answer) external {
        if (msg.sender != KEEPER) revert NotKeeper();
        _publish(answer);
    }

    /// @notice Latest simulated round, in the Chainlink AggregatorV3 shape.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }

    function _publish(int256 answer) private {
        ++_roundId;
        _answer = answer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        emit SimAnswerUpdated(answer, _roundId, block.timestamp);
    }
}
