// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {UsMarketCalendar as Cal} from "../src/lib/UsMarketCalendar.sol";

/// @title ObservedFeedTest
/// @notice EMPIRICAL consistency of the trading-day blind-window model against the real, complete round history
/// of Chainlink stock feeds on Robinhood mainnet (chain 4663), captured by research/observed_rounds.py into
/// test/fixtures/observed_feed_updates.json. The fixture is on-chain data, not a simulation.
///
/// A violation here is a FINDING about the model, not something to patch in the test.
contract ObservedFeedTest is Test {
    string internal fx;

    function setUp() public {
        fx = vm.readFile("test/fixtures/observed_feed_updates.json");
    }

    function _names() internal pure returns (string[6] memory) {
        return ["SPY", "TSLA", "NVDA", "AAPL", "QQQ", "MSFT"];
    }

    function _updates(string memory name) internal view returns (uint256[] memory) {
        return vm.parseJsonUintArray(fx, string.concat(".feeds.", name, ".updatedAt"));
    }

    /// @dev (a) No observed update has updatedAt strictly inside a predicted blind window.
    function test_noObservedUpdateInsideAPredictedBlindWindow() public {
        string[6] memory names = _names();
        uint256 total;
        for (uint256 f; f < names.length; ++f) {
            uint256[] memory ups = _updates(names[f]);
            assertGt(ups.length, 100, "feed history present");
            uint256 atStart;
            for (uint256 i; i < ups.length; ++i) {
                (bool inside, uint64 s, uint64 e,) = Cal.blindWindowAt(ups[i]);
                if (!inside) continue;
                if (ups[i] == s) {
                    ++atStart; // an update stamped exactly at the window start is the closing tick, reported separately
                    continue;
                }
                console.log("VIOLATION feed", names[f]);
                console.log("  updatedAt", ups[i]);
                console.log("  window start", s);
                console.log("  window end", e);
                fail("observed update strictly inside a predicted blind window");
            }
            console.log(names[f], "updates", ups.length);
            console.log("  updates exactly at a window start", atStart);
            total += ups.length;
        }
        assertGt(total, 1000);
    }

    /// @dev (b) Lag between each window end and the first update after it, plus coverage. Informational (logged);
    /// asserts only that coverage is non-trivial and every covered window is followed by an update.
    function test_windowEndLagAndCoverage() public view {
        string[6] memory names = _names();
        for (uint256 f; f < names.length; ++f) {
            _lagReport(names[f]);
        }
    }

    function _lagReport(string memory name) internal view {
        uint256[] memory ups = _updates(name);
        uint256 first = ups[0];
        uint256 last = ups[ups.length - 1];
        uint256 cursor = first;
        uint256 weekends;
        uint256 shorts;
        uint256 longs;
        uint256 maxLag;
        uint256 minLag = type(uint256).max;
        uint256 sumLag;
        uint256 j;
        while (true) {
            (uint64 s, uint64 e, Cal.WindowClass c) = Cal.nextBlindWindow(cursor);
            if (e > last) break;
            cursor = s;
            // first update at or after the window end
            while (j < ups.length && ups[j] < e) ++j;
            assertLt(j, ups.length, "an update follows every covered window");
            uint256 lag = ups[j] - e;
            if (lag > maxLag) maxLag = lag;
            if (lag < minLag) minLag = lag;
            sumLag += lag;
            if (c == Cal.WindowClass.Weekend) ++weekends;
            else if (c == Cal.WindowClass.Short) ++shorts;
            else ++longs;
        }
        uint256 n = weekends + shorts + longs;
        assertGe(n, 12, "coverage");
        console.log(name);
        console.log("  windows covered", n);
        console.log("  weekends", weekends);
        console.log("  short (mid-week holiday)", shorts);
        console.log("  long (holiday weekends)", longs);
        console.log("  lag min / mean / max (seconds)", minLag, sumLag / n, maxLag);
    }
}
