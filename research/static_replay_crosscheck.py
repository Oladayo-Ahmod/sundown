# ruff: noqa: E501
"""Cross-check: my Python simulation versus Session A's forge replay for the SAME scenario.

Scenario (docs/REPLAY_RESULTS.md, research/replay_reference.py): AAPL, tier 93 %, the 10 worst real
gaps (sim/replay_inputs.json), 20 borrowers with 50 tokens at $100 each (collateral $100k), debt =
tier x (0.80 + 0.19 x (i mod 10) / 9) of collateral, one gap at reopen, deleverage fee 2 %, no
borrower cures, flat 4 % bonus, calibration D26. Three markets: control (flat 93 %), session-aware
(static stress rule), standard (flat 86 %). Their results come from forge's in-process EVM (a
fixture window cache, NOT a public chain) and an exact-integer reference; mine from
`static_rule.simulate_book` with infinite depth (they do not model exit slippage), no intraday
drift, and the M2.2 liquidation rounds. Differences are reported, not reconciled.

Their per-event losses are taken from docs/REPLAY_RESULTS.md (the five events it lists) and the
totals (control 3,823.83 over 4 events; session-aware 1,224.37 over 1; standard 0).
"""

from __future__ import annotations

import json

import numpy as np
import pandas as pd

import static_rule as sr
from config import REPO, RESULTS_DIR

GAP_BPS = {1: 915.29, 2: 597.0, 0: 282.99}  # AAPL, replay_reference.GAP_BPS (D26)
THEIR = {  # docs/REPLAY_RESULTS.md, AAPL 93 %, lender loss in USDG: control / sundown / standard
    "2020-03-16": (1923.95, 1224.37, 0.0),
    "2015-08-24": (967.17, 0.0, 0.0),
    "2020-03-09": (432.68, 0.0, 0.0),
    "2024-08-05": (500.03, 0.0, 0.0),
}
THEIR_TOTALS = {"control": 3823.83, "sundown": 1224.37, "standard": 0.0}
COLLATERAL_USD = 20 * 50 * 100.0
N = 20


def population() -> tuple[np.ndarray, np.ndarray]:
    u = np.array([0.80 + 0.19 * (i % 10) / 9 for i in range(N)])
    return u, np.full(N, 1.0 / N)


def compute() -> tuple[pd.DataFrame, dict]:
    inputs = json.loads((REPO / "sim" / "replay_inputs.json").read_text())
    ev = [e for e in inputs["events"] if e["asset"] == "AAPL"]
    x = np.array([np.log(e["ratioWad"] / 1e18) * 1e4 for e in ev])
    oc = np.zeros(len(ev))
    gv = np.array([GAP_BPS[e["cls"]] for e in ev])
    pop = population()
    depth = sr.DepthInfinite()
    common = dict(population=pop, depth=depth, collateral_usd=COLLATERAL_USD)

    def run(L, rule, nonworsening, behaviour="naive", fee=sr.FEE_FLOOR):
        return sr.simulate_book(x, oc, gv, L, common["depth"], common["collateral_usd"], rule=rule,
                                behaviour=behaviour, fee=fee, population=pop,
                                nonworsening=nonworsening)

    ctrl = run(0.93, False, False)
    sess = run(0.93, True, False)
    std = run(0.86, False, False)
    ctrl_m = run(0.93, False, True)
    sess_m = run(0.93, True, True)
    std_m = run(0.86, False, True)
    rows = []
    for i, e in enumerate(ev):
        t = THEIR.get(e["date"])
        rows.append({
            "date": e["date"], "cls": {1: "Weekend", 2: "Long"}[e["cls"]],
            "gap_loss_pct": round(100 - 100 * e["ratioWad"] / 1e18, 2),
            "python_control": ctrl.bad[i], "python_session_aware": sess.bad[i],
            "python_standard_86": std.bad[i],
            "python_nonworsening_control": ctrl_m.bad[i],
            "python_nonworsening_session_aware": sess_m.bad[i],
            "python_nonworsening_standard_86": std_m.bad[i],
            "forge_control": t[0] if t else 0.0, "forge_session_aware": t[1] if t else 0.0,
            "forge_standard_86": t[2] if t else 0.0,
            "python_accounts_flagged": int(round(sess.flagged_share[i] * N)),
            "python_deleverage_notional_usd": sess.pre_notional[i],
        })
    out = pd.DataFrame(rows)
    tot = {
        "python_control": out.python_control.sum(), "python_session_aware": out.python_session_aware.sum(),
        "python_standard_86": out.python_standard_86.sum(),
        "python_nonworsening_control": out.python_nonworsening_control.sum(),
        "python_nonworsening_session_aware": out.python_nonworsening_session_aware.sum(),
        "python_nonworsening_standard_86": out.python_nonworsening_standard_86.sum(),
        "python_nonworsening_events_with_loss_control":
            int((out.python_nonworsening_control > 0.01).sum()),
        "python_nonworsening_events_with_loss_session_aware":
            int((out.python_nonworsening_session_aware > 0.01).sum()),
        "python_events_with_loss_control": int((out.python_control > 0.01).sum()),
        "python_events_with_loss_session_aware": int((out.python_session_aware > 0.01).sum()),
        "forge_control": THEIR_TOTALS["control"], "forge_session_aware": THEIR_TOTALS["sundown"],
        "forge_standard_86": THEIR_TOTALS["standard"],
        "forge_events_with_loss_control": 4, "forge_events_with_loss_session_aware": 1,
    }
    return out, tot


def main() -> None:
    out, tot = compute()
    out.to_csv(RESULTS_DIR / "static_replay_crosscheck.csv", index=False, float_format="%.2f")
    pd.DataFrame([tot]).to_csv(RESULTS_DIR / "static_replay_crosscheck_totals.csv", index=False,
                               float_format="%.2f")
    print(out.round(2).to_string(index=False))
    print(json.dumps({k: round(v, 2) for k, v in tot.items()}, indent=1))


if __name__ == "__main__":
    main()
