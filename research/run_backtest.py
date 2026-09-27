"""One-command pipeline: gap statistics -> estimator selection/backtest -> credit simulation ->
outputs (results/, deployments/risk_params.json, sim/replay_events.json, docs/figures).

Reads only committed derived series (research/data/derived) so it runs offline and
reproducibly; `make data` / `make intraday` are the network steps.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

import backtest as bt
import credit_sim as cs
import estimators as est
import frontier as fr
import gap_stats
from config import (
    BLIND_CLASSES,
    CAL_END,
    DEPLOY_SUBSET,
    ORACLE_DEVIATION_BPS,
    QUANTILES,
    RESULTS_DIR,
    SAFETY_BUFFER_BPS,
    SEED,
    TEST_START,
    TRAIN_END,
    UNIVERSE,
)
from data import load_panel

STRESS_Q = 0.99
EVAL_QS = [0.95, 0.99, 0.995, 0.999]


def save(df: pd.DataFrame, name: str) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    df.to_csv(RESULTS_DIR / name, index=False, float_format="%.6g")


def final_forecast(df, cand, q):
    _, _, train, _ = bt._slices(df)
    sc = bt.class_scales(df[train])
    raw = bt.raw_forecasts(df, cand, q, sc)
    m = bt.calibrate_multiplier(df, raw, q, train)
    return bt.apply_multiplier(df, raw, m), m, sc, raw


# ---------------------------------------------------------------- stage 1: descriptive stats

def stage_stats(panel: pd.DataFrame) -> dict:
    save(gap_stats.class_stats(panel), "class_stats.csv")
    save(gap_stats.class_stats(panel[panel.d2 >= TEST_START]), "class_stats_test_period.csv")
    vr = gap_stats.variance_ratios(panel)
    save(vr, "variance_ratios.csv")
    save(gap_stats.quantile_cis(panel, 0.99), "q99_loss_cis.csv")
    save(gap_stats.dividend_sensitivity(panel), "dividend_sensitivity.csv")
    save(gap_stats.censoring_daily(panel), "censoring_daily.csv")
    # sample counts per class (shows why Short/Long cannot be estimated per class)
    cnt = panel.groupby(["ticker", "cls"]).size().unstack()
    save(cnt.reset_index(), "window_counts.csv")
    # does early close at D1 change the picture? (UNVERIFIED rule, D1)
    blind = panel[panel.cls.isin(BLIND_CLASSES)]
    ec = blind.groupby(["d1_early_close"]).gap_bps.agg(["count", "std"]).reset_index()
    save(ec, "early_close_check.csv")
    return {"variance_ratios_median": vr[vr.ticker == "MEDIAN"].to_dict("records")}


# ---------------------------------------------------------------- stage 2: estimators

def stage_estimators(df: pd.DataFrame):
    tab, chosen = bt.select_estimators(df, STRESS_Q)
    save(tab, "estimator_validation.csv")
    _, _, train, test = bt._slices(df)

    # report-only: the whole grid on the test slice (never used for selection)
    rows = []
    for cand in est.grid():
        var, m, _, _ = final_forecast(df, cand, STRESS_Q)
        ev = bt.evaluate(df, var, STRESS_Q, test, n_boot=0)
        ev = ev[ev.ticker == "ALL"]
        for r in ev.itertuples():
            rows.append({"candidate": cand.name, "cls": r.cls, "m": m[r.cls], "n": r.n,
                         "violations": r.violations, "rate": r.rate, "kupiec_p": r.kupiec_p,
                         "christoffersen_ind_p": r.christoffersen_ind_p,
                         "es_over_var": r.es_over_var, "mean_var_bps": r.mean_var_bps})
    save(pd.DataFrame(rows), "estimator_grid_test.csv")

    ev_all, reg_all, forecasts = [], [], {}
    for q in EVAL_QS:
        var, m, sc, _ = final_forecast(df, chosen, q)
        forecasts[q] = (var, m, sc)
        e = bt.evaluate(df, var, q, test)
        e["multiplier"] = e.cls.map(m)
        ev_all.append(e)
        reg_all.append(bt.regime_breakdown(df, var, q, test))
        if q == STRESS_Q:
            save(bt.exceedance_clusters(df, var, test), "exceedance_clusters_test_q99.csv")
    save(pd.concat(ev_all), "backtest_test_chosen.csv")
    save(pd.concat(reg_all), "backtest_regimes_test.csv")

    # in-sample + validation coverage of the chosen estimator for context
    cov = []
    cal, val, trn, tst = bt._slices(df)
    var99 = forecasts[STRESS_Q][0]
    for name, mask in (("train(<=2017, in-sample m)", trn), ("test(>=2018)", tst)):
        e = bt.evaluate(df, var99, STRESS_Q, mask, n_boot=0)
        e = e[e.ticker == "ALL"].assign(slice=name)
        cov.append(e)
    save(pd.concat(cov), "backtest_slices_chosen_q99.csv")

    # floor variant (governance sanity floor = training 95% empirical loss per asset/class)
    floor = (df[trn].groupby(["ticker", "cls"]).loss.quantile(0.95).clip(lower=0)
             .rename("floor").reset_index())
    fl = df.merge(floor, on=["ticker", "cls"], how="left").floor.to_numpy()
    var_f = np.maximum(var99, np.nan_to_num(fl))
    e = bt.evaluate(df, var_f, STRESS_Q, tst, n_boot=0)
    save(e[e.ticker == "ALL"], "backtest_test_with_floor_q99.csv")
    return chosen, forecasts, floor


# ---------------------------------------------------------------- stage 3: credit sim

def _events(df, panel, forecasts_q99, full: bool = False):
    """Event tables keyed by ticker and scenario (test period, or full history if )."""
    _, _, _, test = bt._slices(df)
    if full:
        test = np.ones(len(df), bool)
    start = pd.Timestamp("1900-01-01") if full else pd.Timestamp(TEST_START)
    var99 = forecasts_q99
    ev = {}
    d = df[test].assign(var=var99[test])
    d = d[np.isfinite(d["var"])]
    for t in UNIVERSE:
        g = d[d.ticker == t]
        ev[(t, "blind")] = g
        for c in BLIND_CLASSES:
            ev[(t, c)] = g[g.cls == c]
        p = panel[(panel.ticker == t) & (panel.d2 >= start)]
        ev[(t, "regular")] = p.assign(var=np.nan)
    return ev


def _x_of(scn, g):
    if scn == "regular":
        return g.oc_bps.to_numpy(float)
    return g.gap_bps.to_numpy(float)


def run_group(ev, tickers, scn, ctl, p, arm, years, total_hours):
    """Aggregate event results over a set of tickers for one scenario/arm."""
    parts, hours = [], []
    for t in tickers:
        g = ev[(t, scn)]
        if not len(g):
            continue
        var = g["var"].to_numpy(float) if (arm != "control" and scn in
                                           ("blind", *BLIND_CLASSES)) else None
        parts.append(cs.run_events(_x_of(scn, g), var, ctl, p))
        hours.append(g.hours.to_numpy(float) if "hours" in g else np.zeros(len(g)))
    if not parts:
        return None, None
    res = {k: np.concatenate([r[k] for r in parts]) for k in parts[0]}
    h = np.concatenate(hours) if scn in ("blind", *BLIND_CLASSES) else None
    n_assets = len(tickers)
    return res, cs.summarize(res, h, p, years * n_assets, total_hours * n_assets)


def stage_credit(df, panel, chosen, forecasts):
    _, _, _, test = bt._slices(df)
    test_start, end = pd.Timestamp(TEST_START), df.d2.max()
    years = (end - test_start).days / 365.25
    total_hours = (end - test_start).total_seconds() / 3600
    groups = {"DEPLOY4": DEPLOY_SUBSET, "UNIVERSE12": UNIVERSE, **{t: [t] for t in UNIVERSE}}
    ev99 = _events(df, panel, forecasts[STRESS_Q][0])
    base = cs.Params()
    arms = {"control": cs.Params(), "treat_e1": base, "treat_e0.5": cs.Params(enforcement=0.5)}
    scns = ["blind", *BLIND_CLASSES, "regular"]
    rows = []
    for gname, tick in groups.items():
        for ctl in cs.controls():
            for scn in scns:
                for aname, p in arms.items():
                    arm = "control" if aname == "control" else "treat"
                    _, s = run_group(ev99, tick, scn, ctl, p, arm, years, total_hours)
                    if s:
                        rows.append({"group": gname, "control": ctl.name, "kind": ctl.kind,
                                     "lltv": ctl.lltv, "bonus": ctl.bonus, "scenario": scn,
                                     "arm": aname, **s})
    main = pd.DataFrame(rows)
    save(main, "credit_summary.csv")

    # ---- robustness: full history (2010+). Estimator parameters are in-sample before 2018. ----
    ev_full = _events(df, panel, forecasts[STRESS_Q][0], full=True)
    start_full = df.d2.min()
    years_f = (end - start_full).days / 365.25
    hours_f = (end - start_full).total_seconds() / 3600
    rows_f = []
    for gname in ("DEPLOY4", "UNIVERSE12"):
        for ctl in cs.controls():
            for scn in ("blind", "regular"):
                for aname in ("control", "treat_e1"):
                    arm = "control" if aname == "control" else "treat"
                    _, s = run_group(ev_full, groups[gname], scn, ctl, cs.Params(), arm,
                                     years_f, hours_f)
                    if s:
                        rows_f.append({"group": gname, "control": ctl.name, "kind": ctl.kind,
                                       "scenario": scn, "arm": aname,
                                       "period": "2010+ (in-sample before 2018)", **s})
    save(pd.DataFrame(rows_f), "credit_summary_full_history.csv")

    # ---- sensitivity (pooled groups, blind windows) ----
    sens = []
    var_by_q = {q: _events(df, panel, forecasts[q][0]) for q in EVAL_QS}
    cases = [("baseline", STRESS_Q, cs.Params())]
    cases += [(f"VaR quantile {q}", q, cs.Params()) for q in EVAL_QS if q != STRESS_Q]
    cases += [(f"adverse oracle staleness {n}bps", STRESS_Q, cs.Params(noise_bps=n))
              for n in (25, 50)]
    cases += [("no oracle buffer in cap (staleness 50bps hits)", STRESS_Q,
               cs.Params(oracle_buffer_bps=0.0, noise_bps=50.0))]
    cases += [("oracle buffer 50 + staleness 50 (cap covers it)", STRESS_Q,
               cs.Params(noise_bps=50.0))]
    cases += [(f"safety buffer {s}bps", STRESS_Q, cs.Params(safety_buffer_bps=float(s)))
              for s in (0, 200, 500)]
    cases += [("bonus-aware cap", STRESS_Q, cs.Params(bonus_aware_cap=True))]
    cases += [(f"liquidation bonus {b:.1%} (slippage proxy)", STRESS_Q,
               cs.Params(bonus_override=b)) for b in (0.10, 0.15)]
    cases += [("borrowers concentrated near max LTV", STRESS_Q, cs.Params(util_weights="high"))]
    cases += [("enforcement 0 (cap on new borrows only)", STRESS_Q, cs.Params(enforcement=0.0)),
              ("enforcement 0.5", STRESS_Q, cs.Params(enforcement=0.5))]
    cases += [(f"lookahead {h}h", STRESS_Q, cs.Params(lookahead_h=float(h))) for h in (0, 48)]
    for gname in ("DEPLOY4", "UNIVERSE12"):
        for label, q, p in cases:
            for ctl in cs.controls():
                # control arm shares the sensitivity's staleness/bonus/utilisation settings
                pc = cs.Params(noise_bps=p.noise_bps, bonus_override=p.bonus_override,
                               util_weights=p.util_weights)
                _, sc_ = run_group(var_by_q[q], groups[gname], "blind", ctl, pc, "control",
                                   years, total_hours)
                _, st_ = run_group(var_by_q[q], groups[gname], "blind", ctl, p, "treat",
                                   years, total_hours)
                sens.append({"group": gname, "case": label, "control": ctl.name,
                             "kind": ctl.kind,
                             "control_bad_debt_pct": sc_["bad_debt_pct_of_outstanding"],
                             "treat_bad_debt_pct": st_["bad_debt_pct_of_outstanding"],
                             "control_p99_pct": sc_["lender_loss_p99_pct"],
                             "treat_p99_pct": st_["lender_loss_p99_pct"],
                             "control_p999_pct": sc_["lender_loss_p999_pct"],
                             "treat_p999_pct": st_["lender_loss_p999_pct"],
                             "cap_reduction_at_window_pct": st_["cap_reduction_at_window_pct"],
                             "capacity_given_up_time_avg_pct":
                             st_.get("capacity_given_up_time_avg_pct", np.nan),
                             "forced_delev_share_pct": st_["forced_delev_share_pct"]})
    save(pd.DataFrame(sens), "credit_sensitivity.csv")

    # ---- month-cluster bootstrap CIs for the headline contrast ----
    rng = np.random.default_rng(SEED + 11)
    ci_rows = []
    for gname in ("DEPLOY4", "UNIVERSE12"):
        tick = groups[gname]
        months_all = pd.concat([ev99[(t, "blind")] for t in tick]).d2.dt.to_period("M")
        uniq = sorted(months_all.unique())
        midx = {m: i for i, m in enumerate(uniq)}
        for ctl in cs.controls():
            parts_c, parts_t, mi = [], [], []
            for t in tick:
                g = ev99[(t, "blind")]
                if not len(g):
                    continue
                parts_c.append(cs.run_events(g.gap_bps.to_numpy(float), None, ctl, cs.Params()))
                parts_t.append(cs.run_events(g.gap_bps.to_numpy(float),
                                             g["var"].to_numpy(float), ctl, cs.Params()))
                mi.append(g.d2.dt.to_period("M").map(midx).to_numpy())
            mi = np.concatenate(mi)
            C = {k: np.concatenate([r[k] for r in parts_c]) for k in parts_c[0]}
            T = {k: np.concatenate([r[k] for r in parts_t]) for k in parts_t[0]}
            M = len(uniq)

            def msum(a, mi=mi, M=M):
                return np.bincount(mi, weights=a, minlength=M)

            bc, dc, bt_, dt_ = msum(C["bad"]), msum(C["debt"]), msum(T["bad"]), msum(T["debt"])
            cr = msum(T["cap_reduction"])
            ne = np.bincount(mi, minlength=M).astype(float)
            w = rng.multinomial(M, np.full(M, 1 / M), size=2000).astype(float)
            pc_ = 100 * (w @ bc) / (w @ dc)
            pt_ = 100 * (w @ bt_) / (w @ dt_)
            cap_ = 100 * (w @ cr) / (w @ ne)
            q = lambda a: (float(np.quantile(a, 0.025)), float(np.quantile(a, 0.975)))  # noqa: E731
            ci_rows.append({
                "group": gname, "control": ctl.name,
                "control_bad_debt_pct": 100 * bc.sum() / dc.sum(),
                "control_ci": q(pc_),
                "treat_bad_debt_pct": 100 * bt_.sum() / dt_.sum(), "treat_ci": q(pt_),
                "reduction_pp": 100 * (bc.sum() / dc.sum() - bt_.sum() / dt_.sum()),
                "reduction_ci": q(pc_ - pt_),
                "cap_reduction_at_window_pct": 100 * cr.sum() / ne.sum(), "cap_ci": q(cap_)})
    ci = pd.DataFrame(ci_rows)
    for c in ("control_ci", "treat_ci", "reduction_ci", "cap_ci"):
        ci[c] = ci[c].map(lambda t: f"[{t[0]:.4g}, {t[1]:.4g}]")
    save(ci, "credit_headline_ci.csv")
    for cl, fname in (("month", "credit_frontier_month.csv"),
                      ("date", "credit_frontier_datecluster.csv")):
        pts, curve = fr.frontier(ev99, groups, years, cl)
        save(pts, fname)
        save(curve, fname.replace("frontier", "frontier_curve"))
    return main, ci


def main() -> None:
    panel = load_panel()
    stage_stats(panel)
    df = bt.blind_panel(panel)
    chosen, forecasts, floor = stage_estimators(df)
    stage_credit(df, panel, chosen, forecasts)
    import outputs  # risk_params.json, replay_events.json

    outputs.write_all(panel, df, chosen, forecasts, floor)
    print("chosen estimator:", chosen.name)
    print("train end", TRAIN_END, "cal end", CAL_END, "test start", TEST_START,
          "| oracle buffer", ORACLE_DEVIATION_BPS, "safety", SAFETY_BUFFER_BPS,
          "| quantiles", QUANTILES)


if __name__ == "__main__":
    main()
