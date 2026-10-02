#!/usr/bin/env python3
"""Fail on any High finding and on any Medium finding beyond the triaged baseline (scripts/slither_baseline.json).

Slither's text output has no impact labels to grep, so this reads the JSON report. The baseline counts the Medium
findings that were reviewed and accepted (see docs/THREAT_MODEL.md section 8); a new Medium finding, or a higher count,
fails. Usage: check_slither.py [CONTRACTS_DIR]   (default: contracts)
"""

from __future__ import annotations

import collections
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "scripts/slither_baseline.json"


def main() -> int:
    cdir = ROOT / (sys.argv[1] if len(sys.argv) > 1 else "contracts")
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "slither.json"
        subprocess.run(
            ["slither", ".", "--config-file", "slither.config.json", "--json", str(out)],
            cwd=cdir,
            capture_output=True,
            text=True,
        )
        if not out.exists():
            print("slither produced no JSON report")
            return 1
        dets = json.loads(out.read_text()).get("results", {}).get("detectors", [])
    base = json.loads(BASELINE.read_text())["medium"]
    medium = collections.Counter(d["check"] for d in dets if d["impact"] == "Medium")
    high = [d for d in dets if d["impact"] == "High"]
    problems = [f"HIGH {d['check']}: {d['description'].splitlines()[0][:140]}" for d in high]
    for check, n in medium.items():
        if n > base.get(check, 0):
            problems.append(f"MEDIUM {check}: {n} found, baseline {base.get(check, 0)}")
    print(f"slither: {len(dets)} findings, {len(high)} high, {sum(medium.values())} medium (baseline {sum(base.values())})")
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
