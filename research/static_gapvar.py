"""Static through-the-cycle gapVaR per asset and window class (input to the shipped guard, D26).

gapVaR[class] = full-sample empirical q99.5 downside gap (loss, bps) of the log gap
x = ln(open_D2 / close_D1), `-np.quantile(x, 1 - 0.995, method="lower")` per ticker and class,
exactly the method of `gap_stats.class_stats` and the value in `results/class_stats.csv`
(column `loss_q99.5_bps`). Sample 2010-01-04 .. 2026-10-01, includes March 2020. Daily proxy:
a conservative superset of the oracle-blind exposure. This script re-derives the numbers from
the committed derived series and ASSERTS they equal class_stats.csv, so the file cannot drift.

Resolution caveat (stated in the file): q99.5 is statistically resolvable only for the Weekend
class (n >= 200); Short (n = 41) and Long (n ~ 115) values equal the sample extreme.

A second file, static_gapvar_pre2018.csv, applies the same method to 2010-2017 only (excludes
March 2020). It exists to test how much the shipped rule depends on hindsight; it is NOT an
input to the shipped rule.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from config import BLIND_CLASSES, DEPLOY_SUBSET, RESULTS_DIR
from data import load_panel

Q = 0.995
ORACLE_BUFFER_BPS = 50.0
SAFETY_BUFFER_BPS = 100.0
TIERS = (0.90, 0.93)


def gapvar_table(panel: pd.DataFrame, sample: str, d_from=None, d_to=None) -> pd.DataFrame:
    p = panel[panel.cls.isin(BLIND_CLASSES)]
    if d_from is not None:
        p = p[(p.d2 >= d_from) & (p.d2 <= d_to)]
    rows = []
    for t in DEPLOY_SUBSET:
        for c in BLIND_CLASSES:
            x = p[(p.ticker == t) & (p.cls == c)].gap_bps.to_numpy(float)
            gv = -float(np.quantile(x, 1 - Q, method="lower"))
            stress = max(0.0, 10_000 - gv - ORACLE_BUFFER_BPS - SAFETY_BUFFER_BPS)
            row = {"ticker": t, "cls": c, "n": len(x), "gap_var_bps_q995": round(gv, 2),
                   "q995_resolvable": bool(len(x) * (1 - Q) >= 1),
                   "stress_fraction_bps": round(stress, 2),
                   "sample": sample,
                   "sample_first_window": str(p[p.ticker == t].d2.min().date()),
                   "sample_last_window": str(p[p.ticker == t].d2.max().date())}
            for tier in TIERS:
                row[f"tier{int(tier * 100)}_cap_bps"] = round(min(tier * 1e4, stress), 2)
                row[f"binds_tier{int(tier * 100)}"] = bool(stress < tier * 1e4)
                row[f"tightening_pp_tier{int(tier * 100)}"] = round(max(0.0, tier * 1e4 - stress)
                                                                    / 100, 2)
            rows.append(row)
    return pd.DataFrame(rows)


def main() -> None:
    panel = load_panel()
    full = gapvar_table(panel, "full 2010-2026 (includes March 2020)")
    ref = pd.read_csv(RESULTS_DIR / "class_stats.csv")
    for r in full.itertuples():
        want = ref[(ref.ticker == r.ticker) & (ref.cls == r.cls)]["loss_q99.5_bps"].iloc[0]
        assert abs(want - r.gap_var_bps_q995) < 0.01, (r.ticker, r.cls, want, r.gap_var_bps_q995)
    prov = {
        "source_file": "research/results/class_stats.csv (column loss_q99.5_bps)",
        "method": "-np.quantile(log gap in bps, 0.005, method='lower'), by ticker and class "
                  "(research/gap_stats.py)",
        "basis": "daily proxy: previous regular close to next regular open (conservative superset)",
        "price_basis": "split-adjusted, not dividend-adjusted (research/DATA_PROVENANCE.md)",
        "stress_fraction": "10000 - gapVaR - 50 (oracle buffer) - 100 (safety buffer), bps",
    }
    for k, v in prov.items():
        full[k] = v
    full.to_csv(RESULTS_DIR / "static_gapvar.csv", index=False, float_format="%.6g")
    pre = gapvar_table(panel, "pre-2018 (2010-2017, excludes March 2020; sensitivity only)",
                       "2010-01-01", "2017-12-31")
    pre.to_csv(RESULTS_DIR / "static_gapvar_pre2018.csv", index=False, float_format="%.6g")
    cols = ["ticker", "cls", "n", "gap_var_bps_q995", "stress_fraction_bps", "binds_tier90",
            "binds_tier93"]
    print(full[cols].to_string(index=False))


if __name__ == "__main__":
    main()
