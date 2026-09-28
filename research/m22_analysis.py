"""M2.2: liquidation designs under convex slippage, per-market caps, two-tier evaluation.

Depth: single secondary-source snapshot (pool_depth_snapshot.json, USDG-pool TVL per asset),
v3 constant-product approximation: quote reserve y = concentration * TVL / 2.
Market debt B = LAMBDA * TVL (ASSUMPTION; sensitivity 0.1-1).
"""

from __future__ import annotations

import json

import numpy as np
import pandas as pd

import credit_sim as cs
import liquidation as lq
import m21_analysis as m21
from config import DEPLOY_SUBSET, RESULTS_DIR

LAMBDA = 0.25
LLTVS = [0.77, 0.86, 0.90, 0.93]
BASE_DESIGNS = ["flat 5.5% CF100", "dutch 60min", "cap 5% of depth"]
BONUS_SWEEP = [0.01, 0.02, 0.03, 0.044, 0.055, 0.08]
APR_ASSUMED = 0.05  # ASSUMPTION for the revenue comparison only


def tvl():
    snap = json.loads((RESULTS_DIR / "pool_depth_snapshot.json").read_text())
    return {a: v["usdg_pool_tvl_usd"] for a, v in snap["per_asset_summary"].items()}


def _events(ev, t):
    g = ev[(t, "blind")]
    return (g.gap_bps.to_numpy(float), g.oc_bps.to_numpy(float), g["var"].to_numpy(float),
            g.hours.to_numpy(float))


def design_table(ev, years, depth):
    by = {d.name: d for d in lq.DESIGNS}
    rows = []
    for t in DEPLOY_SUBSET:
        x, oc, _, _ = _events(ev, t)
        for lt in LLTVS:
            ref = lq.simulate(x, oc, [lq.Tier(lt)], by["flat 5.5% CF100"], None, 1.0)
            rows.append({"asset": t, "lltv": lt, "design": "UNCONSTRAINED depth (flat 5.5%)",
                         "bad_bps_yr": 1e4 * ref["loss_ratio"].sum() / years,
                         "bonus_cost_bps_yr": 1e4 * (ref["bonus_paid"] / ref["debt"]).sum() / years,
                         "worst_window_loss_pct": 100 * ref["loss_ratio"].max()})
            for d in lq.DESIGNS:
                o = lq.simulate(x, oc, [lq.Tier(lt)], d, depth[t], LAMBDA * depth[t])
                rows.append({"asset": t, "lltv": lt, "design": d.name,
                             "bad_bps_yr": 1e4 * o["loss_ratio"].sum() / years,
                             "bonus_cost_bps_yr": 1e4 * (o["bonus_paid"] / o["debt"]).sum() / years,
                             "worst_window_loss_pct": 100 * o["loss_ratio"].max()})
    out = pd.DataFrame(rows)
    pooled = out.groupby(["lltv", "design"], as_index=False)[
        ["bad_bps_yr", "bonus_cost_bps_yr", "worst_window_loss_pct"]].agg(
        {"bad_bps_yr": "mean", "bonus_cost_bps_yr": "mean", "worst_window_loss_pct": "max"})
    pooled.insert(0, "asset", "DEPLOY4 mean")
    out = pd.concat([out, pooled])
    out.to_csv(RESULTS_DIR / "liq_design_comparison.csv", index=False, float_format="%.5g")
    return out


def design_sensitivity(ev, years, depth):
    by = {d.name: d for d in lq.DESIGNS}
    rows = []
    cases = [("base", 1.0, LAMBDA, "uniform")]
    cases += [(f"concentration {c}x", c, LAMBDA, "uniform") for c in (5.0, 15.0)]
    cases += [(f"market debt {lam}xTVL", 1.0, lam, "uniform") for lam in (0.1, 1.0)]
    cases += [("borrowers near max LTV", 1.0, LAMBDA, "high")]
    for label, conc, lam, util in cases:
        for lt in (0.86, 0.93):
            for dn in BASE_DESIGNS:
                vals = []
                for t in DEPLOY_SUBSET:
                    x, oc, _, _ = _events(ev, t)
                    o = lq.simulate(x, oc, [lq.Tier(lt, util=util)], by[dn], depth[t],
                                    lam * depth[t], conc)
                    vals.append(1e4 * o["loss_ratio"].sum() / years)
                rows.append({"case": label, "lltv": lt, "design": dn,
                             "bad_bps_yr_mean_deploy4": float(np.mean(vals)),
                             "max_asset": DEPLOY_SUBSET[int(np.argmax(vals))],
                             "max_asset_bps_yr": float(np.max(vals))})
    pd.DataFrame(rows).to_csv(RESULTS_DIR / "liq_design_sensitivity.csv", index=False,
                              float_format="%.5g")


def bonus_sweep(ev, years, depth):
    """Flat bonus (CF 100 %) vs bad debt under depth constraints: participation vs insolvency."""
    rows = []
    for lam in (0.25, 1.0):
        for lt in (0.86, 0.93):
            for b in BONUS_SWEEP:
                d = lq.Design(f"flat {b:.1%}", "flat", b, 1.0)
                vals = []
                for t in DEPLOY_SUBSET:
                    x, oc, _, _ = _events(ev, t)
                    o = lq.simulate(x, oc, [lq.Tier(lt)], d, depth[t], lam * depth[t])
                    vals.append(1e4 * o["loss_ratio"].sum() / years)
                rows.append({"market_debt_x_tvl": lam, "lltv": lt, "bonus": b,
                             "bad_bps_yr_mean_deploy4": float(np.mean(vals)),
                             **{f"{t}_bps_yr": v for t, v in zip(DEPLOY_SUBSET, vals,
                                                                  strict=True)}})
    pd.DataFrame(rows).to_csv(RESULTS_DIR / "liq_bonus_sweep.csv", index=False,
                              float_format="%.5g")


def caps_table(ev, depth):
    rows = []
    for t in DEPLOY_SUBSET:
        x, oc, _, _ = _events(ev, t)
        for conc in (1.0, 5.0, 15.0):
            y = conc * depth[t] / 2
            for lt in (0.77, 0.86, 0.93):
                o = lq.simulate(x, oc, [lq.Tier(lt)], lq.Design("f", "flat", 0.055), None, 1.0)
                share = o["sold"] / o["debt"]  # seized collateral notional per unit debt
                q99, q999 = np.quantile(share, 0.99), np.quantile(share, 0.999)
                row = {"asset": t, "tvl_usd": depth[t], "concentration": conc, "quote_reserve_y": y,
                       "lltv": lt, "window_seized_per_debt_p99": q99,
                       "window_seized_per_debt_p999": q999}
                for s in (0.01, 0.03, 0.05):
                    n_max = y * s / (1 - s)
                    row[f"max_single_liquidation_usd_slip{int(s * 100)}pct"] = n_max
                    row[f"max_market_debt_usd_slip{int(s * 100)}pct_p99"] = n_max / q99
                    row[f"max_market_debt_usd_slip{int(s * 100)}pct_p999"] = n_max / q999
                rows.append(row)
    pd.DataFrame(rows).to_csv(RESULTS_DIR / "market_caps.csv", index=False, float_format="%.6g")


def two_tier(ev, years, depth, windows_per_year):
    by = {d.name: d for d in lq.DESIGNS}
    rows = []
    total_hours = years * 365.25 * 24
    for t in DEPLOY_SUBSET:
        x, oc, var, hours = _events(ev, t)
        wpy = len(x) / years
        for lb in (0.90, 0.93):
            cap = cs.stress_cap(var, lb, 0.055, cs.Params())
            red = (lb - cap) / lb
            cap_given_pp = 100 * lb * float(((hours + 24) * red).sum() / total_hours)
            for dn in ("flat 5.5% CF100", "dutch 60min"):
                for conc in (1.0, 5.0):
                    for theta in (0.1, 0.3, 0.5):
                        base = lq.simulate(x, oc, [lq.Tier(0.77)], by[dn], depth[t],
                                           LAMBDA * depth[t], conc)
                        std_bps = 1e4 * base["loss_ratio"].sum() / years
                        for util in ("high", "uniform", "conservative"):
                            for enforce in (True, False):
                                tiers = [lq.Tier(0.77, 1 - theta),
                                         lq.Tier(lb, theta, util, cap if enforce else None)]
                                o = lq.simulate(x, oc, tiers, by[dn], depth[t], LAMBDA * depth[t],
                                                conc)
                                bps = 1e4 * o["loss_ratio"].sum() / years
                                forced_per_borrower = (wpy * (1 - 0.7)
                                                       * float((o["flagged"] / theta).mean()))
                                rows.append({
                                    "asset": t, "boosted_lltv": lb, "design": dn,
                                    "concentration": conc, "boosted_debt_share": theta,
                                    "boosted_util": util, "pre_window_deleveraging": enforce,
                                    "extra_power_pp_nominal": 100 * (lb - 0.77),
                                    "capacity_given_up_pp_time_avg": cap_given_pp if enforce else 0,
                                    "forced_events_per_boosted_borrower_per_year":
                                    forced_per_borrower if enforce else 0.0,
                                    "market_bad_debt_bps_yr": bps,
                                    "standard_only_bad_debt_bps_yr": std_bps,
                                    "added_bad_debt_bps_yr": bps - std_bps,
                                    "added_bad_debt_bps_yr_per_boosted_debt":
                                    (bps - std_bps) / theta,
                                    "worst_window_lender_loss_pct": 100 * float(
                                        o["loss_ratio"].max()),
                                    "breakeven_borrow_apr_pct": 100 * (bps / 1e4 - std_bps / 1e4)
                                    / (theta * (1 - 0.77 / lb)),
                                    "extra_interest_bps_yr_assumed": 1e4 * APR_ASSUMED * theta
                                    * (1 - 0.77 / lb)})
    out = pd.DataFrame(rows)
    out.to_csv(RESULTS_DIR / "two_tier.csv", index=False, float_format="%.5g")
    return out


def main():
    panel, df, chosen, var, ev, years = m21.setup()
    depth = tvl()
    design_table(ev, years, depth)
    design_sensitivity(ev, years, depth)
    bonus_sweep(ev, years, depth)
    caps_table(ev, depth)
    two_tier(ev, years, depth, None)


if __name__ == "__main__":
    main()
