"""Report: observed Chainlink updates vs the predicted blind windows (offline analysis).

Reads the two fixtures (calendar windows from the independent oracle, observed feed rounds from
observed_rounds.py) and prints coverage, violations and the lag distribution between each window end
and the first update after it. Output is pasted into docs/CALENDAR_NOTES.md.

Run: python feed_consistency_report.py
"""

from __future__ import annotations

import bisect
import json
import statistics
from datetime import UTC, datetime
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "contracts/test/fixtures"
CLS = {0: "Short", 1: "Weekend", 2: "Long"}


def fmt(ts: int) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime("%a %Y-%m-%d %H:%MZ")


def pct(xs: list[float], p: float) -> float:
    xs = sorted(xs)
    k = min(len(xs) - 1, int(round(p * (len(xs) - 1))))
    return xs[k]


def main() -> None:
    cal = json.loads((FIXTURES / "calendar_cases.json").read_text())
    obs = json.loads((FIXTURES / "observed_feed_updates.json").read_text())
    w = cal["windows"]
    windows = list(zip(w["start"], w["end"], w["cls"], w["id"], strict=True))
    starts = [x[0] for x in windows]

    print(f"observed head: block {obs['meta']['headBlock']} ts {fmt(obs['meta']['headTimestamp'])}")
    for name, feed in obs["feeds"].items():
        ups = feed["updatedAt"]
        first, last = ups[0], ups[-1]
        covered = [x for x in windows if x[0] > first and x[1] <= last]
        counts = {c: sum(1 for x in covered if x[2] == k) for k, c in CLS.items()}

        violations, at_start = [], 0
        for t in ups:
            i = bisect.bisect_right(starts, t) - 1
            if i >= 0 and windows[i][0] <= t < windows[i][1]:
                if t == windows[i][0]:
                    at_start += 1
                else:
                    violations.append((t, windows[i]))

        lags, last_before = [], []
        for (
            s,
            e,
            _c,
            _id,
        ) in covered:
            j = bisect.bisect_left(ups, e)
            lags.append((ups[j] - e) / 3600)
            k = bisect.bisect_left(ups, s) - 1
            last_before.append((s - ups[k]) / 3600)

        print(f"\n## {name}  rounds={len(ups)} phases={feed['roundsPerPhase']}")
        print(f"span {fmt(first)} -> {fmt(last)}")
        print(f"windows fully covered: {len(covered)}  {counts}")
        print(
            f"updates strictly inside a predicted window: {len(violations)}   "
            f"exactly at a start: {at_start}"
        )
        for t, win in violations[:5]:
            print(f"  VIOLATION {fmt(t)} in [{fmt(win[0])}, {fmt(win[1])})")
        if lags:
            print(
                "lag end->first update (h): "
                f"min {min(lags):.2f}  p50 {statistics.median(lags):.2f}  "
                f"p90 {pct(lags, 0.9):.2f}  max {max(lags):.2f}"
            )
            print(
                "gap last update -> window start (h): "
                f"min {min(last_before):.2f}  p50 {statistics.median(last_before):.2f}  "
                f"p90 {pct(last_before, 0.9):.2f}  max {max(last_before):.2f}"
            )
            late = [(e, lg) for (s, e, *_), lg in zip(covered, lags, strict=True) if lg > 1.0]
            for e, lg in late:
                print(f"  late first update: window end {fmt(e)} lag {lg:.2f} h")

    all_cov = sorted(
        {
            (x[0], x[1], x[2])
            for x in windows
            if x[0] > min(f["updatedAt"][0] for f in obs["feeds"].values())
        }
    )
    print("\nwindows on or after the earliest observed update (all feeds):")
    for s, e, c in all_cov:
        if e <= max(f["updatedAt"][-1] for f in obs["feeds"].values()):
            print(f"  {CLS[c]:8s} {fmt(s)} -> {fmt(e)}")


if __name__ == "__main__":
    main()
