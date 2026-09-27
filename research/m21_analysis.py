"""M2.1: per-asset results, estimator heterogeneity, enforcement mechanisms, slippage grid."""

from __future__ import annotations

import numpy as np
import pandas as pd

import backtest as bt
import credit_sim as cs
import enforcement as en
import estimators as est
import run_backtest as rb
from config import BLIND_CLASSES, DEPLOY_SUBSET, RESULTS_DIR, TEST_START, UNIVERSE
from data import load_panel

CTLS = ["morpho_38.5", "morpho_62.5", "morpho_77", "morpho_86", "cf_90", "cf_93", "cf_95"]
MECH_CTLS = ["morpho_77", "morpho_86", "cf_90", "cf_93", "cf_95"]
REGIMES = {"Mar-2020": ("2020-02-20", "2020-04-30")}


def setup():
    panel = load_panel()
    df = bt.blind_panel(panel)
    _, chosen = bt.select_estimators(df, 0.99)
    var, _, _, _ = rb.final_forecast(df, chosen, 0.99)
    ev = rb._events(df, panel, var)
    end = df.d2.max()
    years = (end - pd.Timestamp(TEST_START)).days / 365.25
    return panel, df, chosen, var, ev, years


# ----------------------------------------------------------------------- part 1


def per_asset_credit(df, var, ev, years):
    by = {c.name: c for c in cs.controls()}
    rows, events = [], []
    for name in CTLS:
        ctl = by[name]
        for t in UNIVERSE:
            g = ev[(t, "blind")]
            x = g.gap_bps.to_numpy(float)
            c = cs.run_events(x, None, ctl, cs.Params())
            tr = cs.run_events(x, g["var"].to_numpy(float), ctl, cs.Params())
            ann_c = 1e4 * c["loss_ratio"].sum() / years
            ann_t = 1e4 * tr["loss_ratio"].sum() / years
            rows.append({"control": name, "kind": ctl.kind, "ticker": t, "windows": len(g),
                         "flat_bps_yr": ann_c, "stress_bps_yr": ann_t,
                         "reduction_bps_yr": ann_c - ann_t,
                         "reduction_pct": 100 * (ann_c - ann_t) / ann_c if ann_c else np.nan,
                         "windows_with_bad_debt_flat": int((c["bad"] > 0).sum()),
                         "windows_with_bad_debt_stress": int((tr["bad"] > 0).sum()),
                         "worst_window_loss_pct_flat": 100 * c["loss_ratio"].max(),
                         "worst_window_loss_pct_stress": 100 * tr["loss_ratio"].max(),
                         "windows_cap_binds": int((tr["cap_reduction"] > 0).sum())})
            if name in ("morpho_86", "cf_93"):
                events.append(pd.DataFrame({
                    "control": name, "ticker": t, "date": g.d2.dt.date.to_numpy(),
                    "cls": g.cls.to_numpy(), "gap_bps": x, "var_bps": g["var"].to_numpy(),
                    "flat_loss_pct": 100 * c["loss_ratio"],
                    "stress_loss_pct": 100 * tr["loss_ratio"]}))
    pa = pd.DataFrame(rows)
    tot = pa.groupby("control").reduction_bps_yr.transform("sum")
    pa["share_of_pooled_reduction_pct"] = np.where(tot > 0, 100 * pa.reduction_bps_yr / tot, np.nan)
    tot_f = pa.groupby("control").flat_bps_yr.transform("sum")
    pa["share_of_pooled_flat_bad_debt_pct"] = np.where(tot_f > 0, 100 * pa.flat_bps_yr / tot_f,
                                                       np.nan)
    pa["control"] = pd.Categorical(pa.control, CTLS, ordered=True)
    pa = pa.sort_values(["control", "ticker"])
    pa.to_csv(RESULTS_DIR / "per_asset_credit.csv", index=False, float_format="%.5g")
    ev_df = pd.concat(events)
    ev_df["date"] = pd.to_datetime(ev_df.date)
    top = ev_df.sort_values("flat_loss_pct", ascending=False).groupby("control").head(12)
    top.to_csv(RESULTS_DIR / "top_loss_windows.csv", index=False, float_format="%.5g")
    conc = []
    for name, g in ev_df.groupby("control"):
        for rname, (a, b) in REGIMES.items():
            m = (g.date >= a) & (g.date <= b)
            conc.append({"control": name, "regime": rname,
                         "share_of_flat_bad_debt_pct": 100 * g[m].flat_loss_pct.sum()
                         / g.flat_loss_pct.sum(),
                         "share_of_stress_bad_debt_pct": 100 * g[m].stress_loss_pct.sum()
                         / g.stress_loss_pct.sum(),
                         "windows_with_loss_in_regime": int((m & (g.flat_loss_pct > 0)).sum()),
                         "windows_with_loss_total": int((g.flat_loss_pct > 0).sum())})
    pd.DataFrame(conc).to_csv(RESULTS_DIR / "bad_debt_regime_concentration.csv", index=False,
                              float_format="%.5g")
    return pa, conc


def estimator_heterogeneity(df, chosen):
    """Does one pooled class-scale vector hide per-asset differences? Compare exceedance rates
    per asset for (i) the chosen estimator (pooled scales) and (ii) the same EWMA with
    asset-specific class scales estimated on the training slice."""
    q = 0.99
    _, _, train, test = bt._slices(df)
    var_pool, _, _, raw_pool = rb.final_forecast(df, chosen, q)
    raw_own = np.full(len(df), np.nan)
    for t, idx in df.groupby("ticker").indices.items():
        sub = df.iloc[idx]
        sc = bt.class_scales(df[(df.ticker == t) & train])
        raw_own[idx] = est.raw_forecast(sub.cls.to_numpy(), sub.loss.to_numpy(), chosen, q, sc)
    m_own = bt.calibrate_multiplier(df, raw_own, q, train)
    var_own = bt.apply_multiplier(df, raw_own, m_own)
    rows = []
    loss = df.loss.to_numpy()
    for t, idx in df.groupby("ticker").indices.items():
        for c in BLIND_CLASSES + ["ALL"]:
            sel = np.zeros(len(df), bool)
            sel[idx] = True
            sel &= test
            if c != "ALL":
                sel &= df.cls.to_numpy() == c
            for name, v in (("pooled_scales", var_pool), ("asset_scales", var_own)):
                ok = sel & np.isfinite(v)
                n = int(ok.sum())
                x = int((loss[ok] > v[ok]).sum())
                rows.append({"ticker": t, "cls": c, "variant": name, "n": n, "exceed": x,
                             "rate": x / n if n else np.nan,
                             "mean_var_bps": float(v[ok].mean()) if n else np.nan,
                             "kupiec_p": bt.kupiec(n, x, 1 - q)[1]})
    out = pd.DataFrame(rows)
    out.to_csv(RESULTS_DIR / "estimator_heterogeneity.csv", index=False, float_format="%.5g")
    return out


# ----------------------------------------------------------------------- part 3


def mechanisms(ev, years):
    by = {c.name: c for c in cs.controls()}
    groups = {"DEPLOY4": DEPLOY_SUBSET, "UNIVERSE12": UNIVERSE}
    a_rows, b_rows, c_rows, c2_rows = [], [], [], []
    for gname, tick in groups.items():
        for name in MECH_CTLS:
            ctl = by[name]
            for turn in (0.0, 0.05):
                a_rows.append({"group": gname, "control": name, **en.mech_a(ev, tick, ctl, years,
                                                                          turnover=turn)})
            for util in en.UTIL_KINDS:
                b_rows.append({"group": gname, "control": name,
                               **en.mech_b(ev, tick, ctl, years, util)})
                c_rows.append({"group": gname, "control": name,
                               **en.mech_c(ev, tick, ctl, years, util)})
                c2_rows.append({"group": gname, "control": name,
                                **en.mech_c_all_debt(ev, tick, ctl, years, util)})
            for fail in (0.1, 0.3):
                b_rows.append({"group": gname, "control": name,
                               **en.mech_b(ev, tick, ctl, years, "uniform", fail=fail)})
    pd.DataFrame(a_rows).to_csv(RESULTS_DIR / "mech_a_new_borrows_only.csv", index=False,
                                float_format="%.5g")
    pd.DataFrame(b_rows).to_csv(RESULTS_DIR / "mech_b_hard_deleveraging.csv", index=False,
                                float_format="%.5g")
    pd.DataFrame(c_rows).to_csv(RESULTS_DIR / "mech_c_priced_premium.csv", index=False,
                                float_format="%.5g")
    pd.DataFrame(c2_rows).to_csv(RESULTS_DIR / "mech_c2_all_debt_premium.csv", index=False,
                                 float_format="%.5g")


# ----------------------------------------------------------------------- part 4

BONUSES = [0.01, 0.02, 0.03, 0.044, 0.055, 0.08, 0.10, 0.15]
SLIPPAGES = [0.0, 0.01, 0.03, 0.05]


def slippage_grid(ev, years):
    by = {c.name: c for c in cs.controls()}
    rows = []
    for gname, tick in (("UNIVERSE12", UNIVERSE), ("DEPLOY4", DEPLOY_SUBSET)):
        for name in ("morpho_77", "morpho_86"):
            ctl = by[name]
            for b in BONUSES:
                for s in SLIPPAGES:
                    p = cs.Params(bonus_override=b, slippage=s)
                    c = en._res(ev, tick, ctl, p, False)
                    t = en._res(ev, tick, ctl, p, True)
                    n = len(tick)
                    rows.append({
                        "group": gname, "lltv": ctl.lltv, "bonus": b, "slippage": s,
                        "liquidator_margin_positive": bool((1 + b) * (1 - s) > 1),
                        "effective_discount_pct": 100 * ((1 + b) / (1 - s) - 1),
                        "flat_bps_yr": 1e4 * c["loss_ratio"].sum() / (n * years),
                        "stress_bps_yr": 1e4 * t["loss_ratio"].sum() / (n * years),
                        "flat_p999_window_loss_pct": 100 * float(np.quantile(c["loss_ratio"],
                                                                            0.999)),
                        "flat_worst_window_loss_pct": 100 * float(c["loss_ratio"].max()),
                        "windows_with_bad_debt_flat": int((c["bad"] > 0).sum())})
    out = pd.DataFrame(rows)
    out.to_csv(RESULTS_DIR / "slippage_grid.csv", index=False, float_format="%.5g")
    return out


def main():
    panel, df, chosen, var, ev, years = setup()
    per_asset_credit(df, var, ev, years)
    estimator_heterogeneity(df, chosen)
    mechanisms(ev, years)
    slippage_grid(ev, years)


if __name__ == "__main__":
    main()
