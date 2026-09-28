// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockAggregator
/// @notice TEST FIXTURE (not a real feed). A fully settable AggregatorV3-shaped feed, including the ability to
/// revert, to exercise every validation branch of the oracle adapter.
contract MockAggregator {
    uint8 public decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    bool public shouldRevert;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRounds(uint80 roundId_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function setStartedAt(uint256 startedAt_) external {
        startedAt = startedAt_;
    }

    function setRevert(bool on) external {
        shouldRevert = on;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!shouldRevert, "feed down");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
