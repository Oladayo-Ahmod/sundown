# ruff: noqa: E501  (wide result tables; formatting them across lines would hurt readability)
"""M2.3: evidence for the SHIPPED static stress rule (SPY and AAPL at 90 % and 93 %).

Reads: results/static_gapvar.csv (+ _pre2018 for the hindsight test), results/exit_liquidity.json
(Session A direct v3 depth), results/morpho_rates_snapshot.json (measured USDG borrow APRs),
the committed derived gap series. Writes results/static_rule_*.csv.

Primary sample: all blind windows 2010-2026 (the static gapVaR is itself a full-sample number, so
this evaluation is IN-SAMPLE for the cap; the pre-2018 variant tests out-of-sample). Intervals:
window-date-clustered bootstrap (dates resampled jointly across SPY and AAPL), 2,000 resamples.
"""

from __future__ import annotations

import json

import numpy as np
import pandas as pd

import credit_sim as cs
import frontier as fr
import static_rule as sr
from config import RESULTS_DIR, SEED
from data import load_panel

ASSETS = ("AAPL", "SPY")
TIERS = (0.90, 0.93)
UTILS = ("uniform", "high", "conservative")
FLAT_GRID = np.round(np.arange(0.70, 0.9601, 0.01), 2)
N_BOOT = 2000
BLIND = ["Short", "Weekend", "Long"]


def load_inputs():
    panel = load_panel()
    ev = {}
    for t in ASSETS:
        e = panel[(panel.ticker == t) & panel.cls.isin(BLIND)].sort_values("d2").reset_index(drop=True)
        ev[t] = e
    gv = pd.read_csv(RESULTS_DIR / "static_gapvar.csv")
    gv_pre = pd.read_csv(RESULTS_DIR / "static_gapvar_pre2018.csv")
    rates = json.loads((RESULTS_DIR / "morpho_rates_snapshot.json").read_text())["markets"]
    apr = {"AAPL": rates["AAPL"]["borrow_apr_pct"], "SPY": rates["SPY"]["borrow_apr_pct"],
           "NVDA": rates["NVDA"]["borrow_apr_pct"],
           "large_usdg": rates["ref:USDe(91.5%)"]["borrow_apr_pct"]}
    return panel, ev, gv, gv_pre, apr, sr.load_v3_depth()


def gv_vector(e: pd.DataFrame, gv: pd.DataFrame, t: str) -> np.ndarray:
    m = gv[gv.ticker == t].set_index("cls").gap_var_bps_q995
    return e.cls.map(m).to_numpy(float)


NONWORSENING = False  # set by main(): True = the deployed market's liquidation bonus cap


def run(e, gvb, t, L, depth, C, **kw):
    kw.setdefault("nonworsening", NONWORSENING)
    return sr.simulate_book(e.gap_bps.to_numpy(float), e.oc_bps.to_numpy(float), gvb, L, depth, C,
                            **kw)


def weekend_cap_level(gv: pd.DataFrame, t: str, L: float) -> float:
    g = gv[(gv.ticker == t) & (gv.cls == "Weekend")].gap_var_bps_q995.iloc[0]
    return float(min(L, sr.stress_fraction(np.array([g]))[0]))


class Boot:
    """Date-clustered bootstrap: weights over the union of window dates (row 0 = point estimate)."""

    def __init__(self, ev: dict, years: float, n_boot: int = N_BOOT):
        dates = sorted(set().union(*[set(e.d2) for e in ev.values()]))
        self.idx = {d: i for i, d in enumerate(dates)}
        rng = np.random.default_rng(SEED + 53)
        nd = len(dates)
        self.W = np.vstack([np.ones(nd), rng.multinomial(nd, np.full(nd, 1 / nd), size=n_boot)]
                           ).astype(float)
        self.years = years
        self.nd = nd

    def vec(self, e: pd.DataFrame, values: np.ndarray) -> np.ndarray:
        v = np.zeros(self.nd)
        np.add.at(v, [self.idx[d] for d in e.d2], values)
        return v

    def ann(self, vec: np.ndarray, scale: float = 1e4) -> np.ndarray:
        return scale * (self.W @ vec) / self.years


def ci(a: np.ndarray) -> tuple[float, float, float]:
    return float(a[0]), float(np.quantile(a[1:], 0.025)), float(np.quantile(a[1:], 0.975))


# ----------------------------------------------------------------------------- (a) binding

def table_binding(gv, gv_pre) -> pd.DataFrame:
    rows = []
    for name, g in (("full (shipped)", gv), ("pre-2018 (hindsight test)", gv_pre)):
        for r in g[g.ticker.isin(ASSETS)].itertuples():
            for tier in TIERS:
                cap = min(tier * 1e4, r.stress_fraction_bps)
                rows.append({"gapvar_sample": name, "ticker": r.ticker, "cls": r.cls, "n": r.n,
                             "gap_var_bps_q995": r.gap_var_bps_q995,
                             "stress_fraction_pct": r.stress_fraction_bps / 100,
                             "tier_lltv_pct": tier * 100, "effective_cap_pct": cap / 100,
                             "binds": bool(r.stress_fraction_bps < tier * 1e4),
                             "tightening_pp": max(0.0, tier * 1e4 - r.stress_fraction_bps) / 100,
                             "windows_in_class_pct": None})
    out = pd.DataFrame(rows)
    return out


# ----------------------------------------------------------------------------- (b)(c) main

def main_tables(ev, gv, apr, depth):
    years = (max(e.d2.max() for e in ev.values()) - min(e.d2.min() for e in ev.values())).days / 365.25
    boot = Boot(ev, years)
    lender, borrower, equal = [], [], []
    for t in ASSETS:
        e = ev[t]
        gvb = gv_vector(e, gv, t)
        C = sr.collateral_cap_usd(depth[t])
        wpy = len(e) / years
        hours = e.hours.to_numpy(float)
        stress_share = float((hours + sr.HORIZON_H).sum() / (years * 365.25 * 24))
        for L in TIERS:
            L_c = weekend_cap_level(gv, t, L)
            binds_any = bool((sr.stress_fraction(gvb) < L).any())
            for util in UTILS:
                w = cs.weights(util)
                arms = {
                    "A flat at tier LLTV": run(e, gvb, t, L, depth[t], C, util=util, rule=False),
                    "B boosted + rule, naive borrowers": run(e, gvb, t, L, depth[t], C, util=util,
                                                            rule=True, behaviour="naive"),
                    "B boosted + rule, rational borrowers": run(e, gvb, t, L, depth[t], C, util=util,
                                                               rule=True, behaviour="rational"),
                    "C flat at weekend-cap level": run(e, gvb, t, L, depth[t], C, util=util,
                                                      rule=False, lltv_override=L_c),
                }
                vecs = {k: boot.vec(e, r.loss_ratio) for k, r in arms.items()}
                anns = {k: boot.ann(v) for k, v in vecs.items()}
                for k, r in arms.items():
                    p, lo, hi = ci(anns[k])
                    lender.append({
                        "ticker": t, "tier_lltv_pct": L * 100, "borrowers": util, "arm": k,
                        "arm_lltv_pct": (L_c if k.startswith("C") else L) * 100,
                        "bad_debt_bps_yr": p, "ci_lo": lo, "ci_hi": hi,
                        "windows_with_bad_debt": int((r.bad > 1e-9).sum()),
                        "worst_window_loss_pct": 100 * float(r.loss_ratio.max()),
                        "rule_binds_in_some_class": binds_any})
                for a, b, lab in (("A flat at tier LLTV", "B boosted + rule, naive borrowers",
                                   "A minus B(naive)"),
                                  ("A flat at tier LLTV", "B boosted + rule, rational borrowers",
                                   "A minus B(rational)"),
                                  ("B boosted + rule, naive borrowers", "C flat at weekend-cap level",
                                   "B(naive) minus C"),
                                  ("B boosted + rule, rational borrowers", "C flat at weekend-cap level",
                                   "B(rational) minus C")):
                    p, lo, hi = ci(anns[a] - anns[b])
                    lender.append({"ticker": t, "tier_lltv_pct": L * 100, "borrowers": util,
                                   "arm": "DIFF " + lab, "arm_lltv_pct": None,
                                   "bad_debt_bps_yr": p, "ci_lo": lo, "ci_hi": hi,
                                   "windows_with_bad_debt": None, "worst_window_loss_pct": None,
                                   "rule_binds_in_some_class": binds_any})
                # equal-bad-debt: flat curve on the same windows and borrowers
                curve = []
                for lt in FLAT_GRID:
                    r = run(e, gvb, t, float(lt), depth[t], C, util=util, rule=False)
                    curve.append(boot.ann(boot.vec(e, r.loss_ratio)))
                curve = np.maximum.accumulate(np.stack(curve, axis=1), axis=1)  # (B+1, grid)
                for key in ("B boosted + rule, naive borrowers", "B boosted + rule, rational borrowers"):
                    eq = np.array([fr.equivalent_lltv(curve[b], FLAT_GRID * 100, anns[key][b])
                                   for b in range(curve.shape[0])])
                    gain = L * 100 - eq
                    ep, elo, ehi = ci(eq)
                    gp, glo, ghi = ci(gain)
                    equal.append({
                        "ticker": t, "tier_lltv_pct": L * 100, "borrowers": util, "arm": key,
                        "bad_debt_bps_yr": ci(anns[key])[0],
                        "equivalent_flat_lltv_pct": ep, "equiv_ci_lo": elo, "equiv_ci_hi": ehi,
                        "ltv_gain_pp_at_equal_bad_debt": gp, "gain_ci_lo": glo, "gain_ci_hi": ghi,
                        "weekend_cap_level_pct": L_c * 100,
                        "extra_weekday_capacity_vs_weekend_cap_pp": (L - L_c) * 100,
                        "flat_curve_clamped_at_grid_top": bool(ep >= FLAT_GRID[-1] * 100 - 1e-9)})
                # borrower metrics (naive and rational)
                u = sr.UTIL
                above_c = float((w * (u * L > L_c + 1e-12)).sum())
                used_extra = float((w * np.maximum(0.0, u * L - L_c)).sum()) * 100  # pp of collateral
                avg_unused = float((w * (L - u * L)).sum()) * 100
                top_flag_windows = float((sr.stress_fraction(gvb) < L).mean())
                for beh, key in (("naive", "B boosted + rule, naive borrowers"),
                                 ("rational", "B boosted + rule, rational borrowers")):
                    r = arms[key]
                    fee_pct_debt_yr = 100 * float((r.fee_paid / r.debt_pre).sum()) / years
                    trimmed_pct = 100 * float((r.trimmed_debt / r.debt_pre).sum()) / years
                    extra_usd = float((C * w * np.maximum(0.0, u * L - L_c)).sum())
                    cost_usd_yr = float(r.fee_paid.sum()) / years
                    borrow_apr = apr[t]
                    req_ret = (borrow_apr + (100 * cost_usd_yr / extra_usd if extra_usd > 0 else 0.0)
                               if extra_usd > 0 else None)
                    borrower.append({
                        "ticker": t, "tier_lltv_pct": L * 100, "borrowers": util, "behaviour": beh,
                        "windows_per_year": wpy,
                        "borrowers_above_weekend_cap_pct": 100 * above_c,
                        "flagged_events_per_borrower_yr_avg": wpy * float(r.flagged_share.mean()),
                        "executed_events_per_borrower_yr_avg": wpy * float(r.executed_share.mean()),
                        "flagged_events_per_yr_top_bucket": wpy * top_flag_windows if beh == "naive"
                        else 0.0,
                        "fee_cost_pct_of_debt_per_yr_APR_equiv": fee_pct_debt_yr,
                        "trimmed_notional_pct_of_debt_per_yr": trimmed_pct,
                        "share_flagged_debt_not_trimmed_pct": 100 * float(r.unexecuted_debt.sum()
                                                                          / max(r.flagged_debt.sum(), 1e-9))
                        if r.flagged_debt.sum() > 0 else 0.0,
                        "extra_weekday_capacity_offered_pp": (L - L_c) * 100,
                        "extra_weekday_capacity_used_pp_of_collateral": used_extra,
                        "avg_unused_weekday_headroom_pp": avg_unused,
                        "share_of_time_in_stress_period_pct": 100 * stress_share,
                        "measured_borrow_apr_pct": borrow_apr,
                        "required_gross_return_on_extra_debt_pct": req_ret,
                        "measured_large_usdg_market_apr_pct": apr["large_usdg"]})
    return pd.DataFrame(lender), pd.DataFrame(borrower), pd.DataFrame(equal), boot, years


# ----------------------------------------------------------------------------- (e) keeper

def table_keeper(ev, gv, depth, years):
    rows = []
    for t in ASSETS:
        d = depth[t]
        for n in (5_000, 10_000, 25_000, 50_000, 100_000, 150_000, 200_000):
            s = d.slippage_for(n)
            need = s + sr.GAS
            rows.append({"ticker": t, "row": "position notional sold", "notional_usd": n,
                         "avg_slippage_pct": None if np.isinf(s) else 100 * s,
                         "breakeven_fee_pct": None if np.isinf(s) else 100 * need,
                         "fee_2pct_default_covers": bool(need <= sr.FEE_FLOOR),
                         "within_5_5pct_cap": bool(need <= sr.FEE_CAP),
                         "note": "v3 depth exhausted: no fee within the 5.5% cap covers this size"
                         if np.isinf(s) or need > sr.FEE_CAP else ""})
        for f in (0.02, 0.03, 0.04, 0.055):
            cap = float(d.capacity(np.array([f]))[0])
            rows.append({"ticker": t, "row": "max notional per round at fee", "notional_usd": cap,
                         "avg_slippage_pct": None, "breakeven_fee_pct": 100 * f,
                         "fee_2pct_default_covers": None, "within_5_5pct_cap": True, "note": ""})
        # demand actually generated by the rule in the simulation (naive borrowers, collateral cap)
        e = ev[t]
        gvb = gv_vector(e, gv, t)
        C = sr.collateral_cap_usd(d)
        for L in TIERS:
            for util in ("uniform", "high"):
                for f in (0.02, 0.04, 0.055):
                    r = run(e, gvb, t, L, d, C, util=util, rule=True, behaviour="naive", fee=f)
                    need = r.pre_notional[r.flagged_share > 0]
                    cap_f = float(d.capacity(np.array([f]))[0])
                    rows.append({
                        "ticker": t, "row": f"sim: tier {int(L*100)} % naive {util}, fee {f:.1%}",
                        "notional_usd": float(np.median(need)) if len(need) else 0.0,
                        "avg_slippage_pct": None, "breakeven_fee_pct": 100 * f,
                        "fee_2pct_default_covers": None, "within_5_5pct_cap": True,
                        "note": (f"flagged windows {100*float((r.flagged_share>0).mean()):.0f}%; "
                                 f"median/p95/max pre-window notional ${np.median(need):,.0f}/"
                                 f"${np.quantile(need, .95):,.0f}/${need.max():,.0f}; "
                                 f"per-round capacity ${cap_f:,.0f}; flagged excess not trimmed "
                                 f"{100*float(r.unexecuted_debt.sum()/max(r.flagged_debt.sum(),1e-9)):.1f}%")
                        if len(need) else "never flagged"})
    return pd.DataFrame(rows)


# ----------------------------------------------------------------------------- sensitivity

def table_sensitivity(ev, gv, gv_pre, depth, years_full):
    snap = json.loads((RESULTS_DIR / "pool_depth_snapshot.json").read_text())["per_asset_summary"]
    rows = []

    def add(label, t, L, util, e, gvb, dep, C, years, **kw):
        wk = gvb[(e.cls == "Weekend").to_numpy()]
        L_c = float(min(L, sr.stress_fraction(np.array([wk[0]]))[0]))
        bonus = kw.pop("bonus", sr.BONUS)
        a = run(e, gvb, t, L, dep, C, util=util, rule=False, bonus=bonus)
        bn = run(e, gvb, t, L, dep, C, util=util, rule=True, behaviour="naive", bonus=bonus, **kw)
        br = run(e, gvb, t, L, dep, C, util=util, rule=True, behaviour="rational", bonus=bonus, **kw)
        c = run(e, gvb, t, L, dep, C, util=util, rule=False, lltv_override=L_c, bonus=bonus)
        f = lambda r: 1e4 * float(r.loss_ratio.sum()) / years  # noqa: E731
        rows.append({"case": label, "ticker": t, "tier_lltv_pct": L * 100, "borrowers": util,
                     "A_flat_tier": f(a), "B_naive": f(bn), "B_rational": f(br), "C_flat_weekend_cap": f(c),
                     "naive_fee_pct_debt_yr": 100 * float((bn.fee_paid / bn.debt_pre).sum()) / years,
                     "rule_binds": bool((gvb < 0).any() or (sr.stress_fraction(gvb) < L).any())})

    for t in ASSETS:
        e_full = ev[t]
        gvb_full = gv_vector(e_full, gv, t)
        d = depth[t]
        C = sr.collateral_cap_usd(d)
        e18 = e_full[e_full.d2 >= "2018-01-01"].reset_index(drop=True)
        y18 = (e18.d2.max() - e18.d2.min()).days / 365.25
        for L in TIERS:
            for util in ("uniform", "high"):
                add("base (full sample, v3 depth, fee 2%, bonus 4%)", t, L, util, e_full, gvb_full, d, C, years_full)
                add("2018+ windows, shipped full-sample gapVaR (in-sample cap)", t, L, util, e18,
                    gv_vector(e18, gv, t), d, C, y18)
                add("2018+ windows, pre-2018 gapVaR (out-of-sample cap)", t, L, util, e18,
                    gv_vector(e18, gv_pre, t), d, C, y18)
                add("constant-product depth on DexScreener TVL (M2.2 model)", t, L, util, e_full, gvb_full,
                    sr.DepthCP(snap[t]["usdg_pool_tvl_usd"]), C, years_full)
                add("market 4x the collateral cap", t, L, util, e_full, gvb_full, d, 4 * C, years_full)
                add("market 0.25x the collateral cap", t, L, util, e_full, gvb_full, d, 0.25 * C, years_full)
                add("bonus 3%", t, L, util, e_full, gvb_full, d, C, years_full, bonus=0.03)
                add("bonus 5.5%", t, L, util, e_full, gvb_full, d, C, years_full, bonus=0.055)
                for fee in (0.03, 0.055):
                    add(f"deleverage fee {fee:.1%}", t, L, util, e_full, gvb_full, d, C, years_full, fee=fee)
    return pd.DataFrame(rows)


def main():
    global NONWORSENING
    panel, ev, gv, gv_pre, apr, depth = load_inputs()
    table_binding(gv, gv_pre).drop(columns=["windows_in_class_pct"]).to_csv(
        RESULTS_DIR / "static_rule_binding.csv", index=False, float_format="%.6g")
    for nonworsening, suffix in ((False, ""), (True, "_marketrule")):
        NONWORSENING = nonworsening
        lender, borrower, equal, boot, years = main_tables(ev, gv, apr, depth)
        lender.to_csv(RESULTS_DIR / f"static_rule_lender{suffix}.csv", index=False, float_format="%.5g")
        borrower.to_csv(RESULTS_DIR / f"static_rule_borrower{suffix}.csv", index=False,
                        float_format="%.5g")
        equal.to_csv(RESULTS_DIR / f"static_rule_equal_risk{suffix}.csv", index=False,
                     float_format="%.5g")
        table_sensitivity(ev, gv, gv_pre, depth, years).to_csv(
            RESULTS_DIR / f"static_rule_sensitivity{suffix}.csv", index=False, float_format="%.5g")
        if not nonworsening:
            table_keeper(ev, gv, depth, years).to_csv(RESULTS_DIR / "static_rule_keeper.csv",
                                                      index=False, float_format="%.5g")
    NONWORSENING = False
    print("done")


if __name__ == "__main__":
    main()
