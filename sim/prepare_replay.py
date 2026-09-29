"""Derive integer replay inputs from the real-event excerpt and the exit-liquidity snapshot.

SIMULATION INPUTS. Reads `sim/replay_events.json` (real historical gaps, daily proxy) and
`research/results/exit_liquidity.json` (read-only) and writes `sim/replay_inputs.json` with integers only
(Foundry's JSON cheatcodes cannot parse floats). Deterministic: no network, no randomness.

Usage: python sim/prepare_replay.py [--k 10]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVENTS = ROOT / "sim" / "replay_events.json"
DEPTH = ROOT / "research" / "results" / "exit_liquidity.json"
OUT = ROOT / "sim" / "replay_inputs.json"
WAD = 10**18
ASSETS = ("AAPL", "SPY")
CLASS_ID = {"Short": 0, "Weekend": 1, "Long": 2}


def build(k: int) -> dict:
    events = json.loads(EVENTS.read_text())["events"]
    depth = json.loads(DEPTH.read_text())["assets"]
    rows = []
    for asset in ASSETS:
        worst = sorted((e for e in events if e["asset"] == asset), key=lambda e: -e["loss_pct"])[:k]
        for e in worst:
            # ratio = open / prev_close, scaled by 1e18 (floor): the next regular open relative to the last close
            ratio = int(round(e["open"] / e["prev_close"] * 1e9)) * 10**9
            rows.append(
                {
                    "asset": asset,
                    "date": e["open_date"],
                    "cls": CLASS_ID[e["class"]],
                    "windowSeconds": int(round(e["window_hours"] * 3600)),
                    "ratioWad": ratio,
                    "lossBps": int(round(e["loss_pct"] * 100)),
                }
            )
    dep = {}
    for asset in ASSETS:
        agg = depth[asset]["aggregate_max_notional_usd"]
        dep[asset] = {"d1": agg["1pct"], "d3": agg["3pct"], "d5": agg["5pct"]}
    return {
        "kind": "SIMULATION INPUTS derived from real daily gaps and a v3 depth snapshot; not a live feed",
        "events_source": "sim/replay_events.json",
        "depth_source": "research/results/exit_liquidity.json (aggregate_max_notional_usd, v3 only)",
        "k": k,
        "events": rows,
        # column form for Foundry's JSON cheatcodes (no wildcard paths)
        "cols": {key: [r[key] for r in rows] for key in ("asset", "date", "cls", "windowSeconds", "ratioWad")},
        "depthUsd": dep,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--k", type=int, default=10)
    args = ap.parse_args()
    out = build(args.k)
    OUT.write_text(json.dumps(out, indent=1) + "\n")
    print(f"wrote {OUT} events={len(out['events'])} depth={out['depthUsd']}")


if __name__ == "__main__":
    main()
