# ruff: noqa: E501, B023, E731  (lambdas are called in the same loop iteration that defines them)
"""Before/after of every headline number: older liquidation convention (results/older_convention/,
pre-M2.4 files, an upper bound) versus the deployed market's rule (the default since M2.4).

Writes results/convention_before_after.csv: claim, metric, older, market, change, rel_change_pct,
and a verdict column computed mechanically (strengthened / weakened / unchanged / flipped) from the
quantity's meaning (lower bad debt is not "stronger" by itself, so each metric carries a direction:
`bad_debt` lower = lender-safer, `benefit` higher = rule helps more, `cost` higher = worse).
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from config import OLDER_DIR, RESULTS_DIR


def rd(d, name):
    return pd.read_csv(d / name)


def main() -> None:
    rows = []

    def add(claim, metric, old, new, kind):
        old, new = float(old), float(new)
        rel = 100 * (new - old) / old if old else np.nan
        if kind == "benefit":  # higher = the rule helps more
            v = "unchanged" if abs(new - old) <= 0.05 * max(abs(old), 1e-9) else (
                "strengthened" if new > old else "weakened")
        elif kind == "bad_debt":
            v = "unchanged" if abs(new - old) <= 0.05 * max(abs(old), 1e-9) else "lower loss"
        else:
            v = "unchanged" if abs(new - old) <= 0.05 * max(abs(old), 1e-9) else (
                "cost lower" if new < old else "cost higher")
        rows.append({"claim": claim, "metric": metric, "older_upper_bound": old, "market_rule": new,
                     "change": new - old, "rel_change_pct": rel, "reading": v})

    both = {k: (rd(OLDER_DIR, k), rd(RESULTS_DIR, k)) for k in (
        "credit_frontier_datecluster.csv", "credit_summary.csv", "bad_debt_regime_concentration.csv",
        "mech_b_hard_deleveraging.csv", "mech_c_priced_premium.csv", "mech_c2_all_debt_premium.csv",
        "slippage_grid.csv", "liq_design_comparison.csv", "liq_bonus_sweep.csv", "m22_headline_ci.csv",
        "per_asset_credit.csv", "two_tier.csv")}

    # claim 7: flat markets at real LLTVs
    o, n = both["credit_frontier_datecluster.csv"]
    for g in ("UNIVERSE12", "DEPLOY4"):
        for lt in ("morpho_86", "cf_90", "cf_93", "cf_95"):
            ro = o[(o.group == g) & (o.base_lltv == lt)].iloc[0]
            rn = n[(n.group == g) & (n.base_lltv == lt)].iloc[0]
            c = "7 flat" if lt == "morpho_86" else "9/10 counterfactual"
            add(f"{c} ({g})", f"{lt} flat bad debt bps/yr", ro.flat_bad_debt_bps_yr, rn.flat_bad_debt_bps_yr, "bad_debt")
            add(f"{c} ({g})", f"{lt} flat CI high", ro.flat_ci_hi, rn.flat_ci_hi, "bad_debt")
            add(f"8/9 time-varying rule ({g})", f"{lt} rule bad debt bps/yr", ro.treat_bad_debt_bps_yr,
                rn.treat_bad_debt_bps_yr, "bad_debt")
            add(f"8/9 time-varying rule ({g})", f"{lt} reduction bps/yr", ro.reduction_bps_yr, rn.reduction_bps_yr, "benefit")
            add(f"8/9 time-varying rule ({g})", f"{lt} reduction CI low", ro.reduction_ci_lo, rn.reduction_ci_lo, "benefit")
            if lt != "morpho_86":
                add(f"10 equal-risk gain ({g})", f"{lt} LTV gain pp", ro.ltv_gain_pp, rn.ltv_gain_pp, "benefit")
    o, n = both["credit_summary.csv"]

    def cs_(d, lt, col):
        r = d[(d.group == "UNIVERSE12") & (d.control == lt) & (d.scenario == "blind") & (d.arm == "control")]
        return r.iloc[0][col]

    add("7 flat", "77% flat bad debt bps/yr", cs_(o, "morpho_77", "annualised_bad_debt_bps"),
        cs_(n, "morpho_77", "annualised_bad_debt_bps"), "bad_debt")
    add("7 flat", "86% worst window loss %", cs_(o, "morpho_86", "lender_loss_max_pct"),
        cs_(n, "morpho_86", "lender_loss_max_pct"), "bad_debt")
    o, n = both["bad_debt_regime_concentration.csv"]
    add("7 flat", "86% share of loss in March 2020 %", o[o.control == "morpho_86"].share_of_flat_bad_debt_pct.iloc[0],
        n[n.control == "morpho_86"].share_of_flat_bad_debt_pct.iloc[0], "bad_debt")
    # claim 12: hard deleveraging
    o, n = both["mech_b_hard_deleveraging.csv"]
    for lt in ("morpho_86", "cf_93"):
        q = lambda d: d[(d.group == "UNIVERSE12") & (d.control == lt) & (d.util == "uniform")
                        & (d.enforcement_fail == 0.0)].iloc[0]  # noqa: E731
        add("12 hard deleveraging", f"{lt} control bps/yr", q(o).control_bps_yr, q(n).control_bps_yr, "bad_debt")
        add("12 hard deleveraging", f"{lt} deleveraged bps/yr", q(o).treat_bps_yr, q(n).treat_bps_yr, "bad_debt")
    # claim 13: premium reserve
    o, n = both["mech_c_priced_premium.csv"]
    for lt in ("morpho_86", "cf_93"):
        q = lambda d: d[(d.group == "UNIVERSE12") & (d.control == lt) & (d.util == "uniform")].iloc[0]  # noqa: E731
        add("13 priced premium", f"{lt} break-even bps of excess per window", q(o).breakeven_pi_bps_per_window,
            q(n).breakeven_pi_bps_per_window, "cost")
        add("13 priced premium", f"{lt} P(reserve exhausted 10y) at 25x", q(o).pi_x25_p_exhausted_10y,
            q(n).pi_x25_p_exhausted_10y, "cost")
    o, n = both["mech_c2_all_debt_premium.csv"]
    for lt in ("morpho_86", "cf_93"):
        q = lambda d: d[(d.group == "UNIVERSE12") & (d.control == lt) & (d.util == "uniform")].iloc[0]  # noqa: E731
        add("13b reserve on all debt", f"{lt} seed reserve p95 bps of debt", q(o).x1_seed_reserve_p95_bps_of_debt,
            q(n).x1_seed_reserve_p95_bps_of_debt, "cost")
    # claim 14: slippage grid
    o, n = both["slippage_grid.csv"]
    for lt, b, sl in ((0.86, 0.044, 0.0), (0.86, 0.044, 0.05), (0.86, 0.10, 0.03), (0.86, 0.15, 0.0),
                      (0.77, 0.08, 0.03), (0.77, 0.15, 0.0)):
        q = lambda d: d[(d.group == "UNIVERSE12") & (d.lltv == lt) & np.isclose(d.bonus, b)
                        & np.isclose(d.slippage, sl)].iloc[0]  # noqa: E731
        add("14 bonus x slippage", f"flat {lt:.0%} b={b:.1%} s={sl:.0%} bps/yr", q(o).flat_bps_yr, q(n).flat_bps_yr, "bad_debt")
        add("14 bonus x slippage", f"stress {lt:.0%} b={b:.1%} s={sl:.0%} bps/yr", q(o).stress_bps_yr, q(n).stress_bps_yr, "bad_debt")
    # claims 16-19: designs and bonus
    o, n = both["liq_design_comparison.csv"]
    for d_ in ("flat 5.5% CF100", "flat 4.4% CF100", "dutch 60min", "cap 5% of depth", "UNCONSTRAINED depth (flat 5.5%)"):
        for lt in (0.86, 0.90, 0.93):
            q = lambda d: d[(d.asset == "DEPLOY4 mean") & (d.design == d_) & np.isclose(d.lltv, lt)].iloc[0]  # noqa: E731
            add("16-18 designs (DEPLOY4 mean)", f"{d_} at {lt:.0%} bps/yr", q(o).bad_bps_yr, q(n).bad_bps_yr, "bad_debt")
    o, n = both["liq_bonus_sweep.csv"]
    for lt in (0.86, 0.93):
        for b in (0.01, 0.02, 0.055 if False else 0.06, 0.08):
            q = lambda d: d[(d.market_debt_x_tvl == 0.25) & np.isclose(d.lltv, lt)
                            & np.isclose(d.bonus, b, atol=0.006)].iloc[0]  # noqa: E731
            add("19 bonus sweep", f"flat {lt:.0%} bonus ~{b:.0%} bps/yr", q(o).bad_bps_yr_mean_deploy4,
                q(n).bad_bps_yr_mean_deploy4, "bad_debt")
    o, n = both["m22_headline_ci.csv"]
    for lt in (0.86, 0.93):
        q = lambda d: d[(d.cluster == "date") & (d.what == "reduction 5.5%->2%") & np.isclose(d.lltv, lt)].iloc[0]  # noqa: E731
        add("19 bonus 5.5% to 2%", f"{lt:.0%} reduction bps/yr", q(o).est, q(n).est, "benefit")
        add("19 bonus 5.5% to 2%", f"{lt:.0%} reduction CI low", q(o).ci_lo, q(n).ci_lo, "benefit")
    # claims 21/23 (time-varying two-tier) break-even APR
    for asset in ("AAPL", "SPY", "TSLA", "NVDA"):
        for lt, util in ((0.90, "uniform"), (0.90, "high"), (0.93, "uniform"), (0.93, "high")):
            w = f"{asset} boosted {util} break-even APR %"
            q = lambda d: d[(d.cluster == "date") & (d.what == w) & np.isclose(d.lltv, lt)].iloc[0]  # noqa: E731
            add("21/23 break-even APR (time-varying)", f"{asset} {lt:.0%} {util} %", q(o).est, q(n).est, "cost")
    # per asset at 86% (which assets drive the rule's benefit)
    o, n = both["per_asset_credit.csv"]
    for t in ("TSLA", "NVDA", "JPM"):
        q = lambda d: d[(d.control == "morpho_86") & (d.ticker == t)].iloc[0]  # noqa: E731
        add("7/8 per asset at 86%", f"{t} flat bps/yr", q(o).flat_bps_yr, q(n).flat_bps_yr, "bad_debt")
        add("7/8 per asset at 86%", f"{t} reduction bps/yr", q(o).reduction_bps_yr, q(n).reduction_bps_yr, "benefit")

    out = pd.DataFrame(rows)
    out.to_csv(RESULTS_DIR / "convention_before_after.csv", index=False, float_format="%.5g")
    print(out.round(3).to_string(index=False))


if __name__ == "__main__":
    main()
