"""Compare the on-chain replay harness output with the exact-integer Python reference.

SIMULATION tooling. Inputs: a forge log containing `ROW,...` lines (sim harness) and the CSV printed by
`research/replay_reference.py`. Prints the number of rows compared, exact matches and, for each differing
field, the largest absolute and relative difference. Exit code 1 if any field differs by more than the stated
tolerance (default: exact for counts, 0.01 % of the value or 10 units for amounts).

Usage: python sim/compare_replay.py sol.log ref.csv
"""

from __future__ import annotations

import sys
from pathlib import Path

FIELDS = ["loss", "ordLiq", "delevCalls", "delevDebt", "delevNotional", "capWeekday", "capWindow", "borrowed"]
COUNTS = {"ordLiq", "delevCalls"}
REL_TOL = 1e-4
ABS_TOL = 10


def load_sol(path: Path) -> dict:
    rows = {}
    for line in path.read_text().splitlines():
        line = line.strip().replace(" ", "")
        if not line.startswith("ROW,"):
            continue
        p = line.split(",")[1:]
        key = tuple(p[:4])
        rows[key] = dict(zip(FIELDS, (int(x) for x in p[4:12])))
    return rows


def load_ref(path: Path) -> dict:
    rows = {}
    for line in path.read_text().splitlines()[1:]:
        p = line.strip().split(",")
        if len(p) < 12:
            continue
        rows[tuple(p[:4])] = dict(zip(FIELDS, (int(x) for x in p[4:12])))
    return rows


def main() -> int:
    sol, ref = load_sol(Path(sys.argv[1])), load_ref(Path(sys.argv[2]))
    common = sorted(set(sol) & set(ref))
    print(f"rows: solidity={len(sol)} reference={len(ref)} compared={len(common)}")
    only = set(sol) ^ set(ref)
    if only:
        print(f"UNPAIRED rows: {len(only)} (first: {sorted(only)[:2]})")
    exact = 0
    worst: dict[str, tuple[int, float]] = {}
    bad = 0
    for k in common:
        same = True
        for f in FIELDS:
            a, b = sol[k][f], ref[k][f]
            if a == b:
                continue
            same = False
            d = abs(a - b)
            rel = d / max(abs(b), 1)
            if d > worst.get(f, (0, 0.0))[0]:
                worst[f] = (d, rel)
            tol_ok = d == 0 if f in COUNTS else (d <= ABS_TOL or rel <= REL_TOL)
            if not tol_ok:
                bad += 1
                print(f"OUT OF TOLERANCE {k} {f}: solidity={a} reference={b}")
        exact += same
    print(f"exact row matches: {exact}/{len(common)}")
    for f, (d, rel) in worst.items():
        print(f"  largest difference in {f}: {d} units ({rel:.2e} relative)")
    print(f"tolerance: counts exact; amounts within {ABS_TOL} units or {REL_TOL:.0e} relative")
    return 1 if bad or only else 0


if __name__ == "__main__":
    sys.exit(main())
