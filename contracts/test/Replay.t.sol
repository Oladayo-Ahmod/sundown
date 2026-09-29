// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReplayHarness} from "sim/ReplayHarness.sol";

/// @dev Runs the simulation replay (sim/ReplayHarness.sol) over `sim/replay_inputs.json` and prints one ROW per
/// event, tier and market plus the keeper break-even. Output is compared to research/replay_reference.py by
/// sim/compare_replay.py. SIMULATION: see sim/README.md for what is and is not modelled.
contract ReplayTest is ReplayHarness {
    function test_replayPrintsResults() public {
        runReplay("../sim/replay_inputs.json");
    }
}
