"""Export committed research outputs to web/src/data/*.json for the research pages.

Every block carries `source` (the file(s) it was read from) so the UI can tag each number.
No value is computed here that is not either read from a results file or (gap histograms,
VaR series) recomputed from the committed derived series with the committed code.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime

import numpy as np
import pandas as pd

import backtest as bt
import run_backtest as rb
from config import DEPLOY_SUBSET, REPLAY_EVENTS_PATH, REPO, RESULTS_DIR, RISK_PARAMS_PATH
from data import load_panel

OUT = REPO / "web" / "src" / "data"
R = "research/results/"


def w(name: str, obj: dict) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    obj["generated_utc"] = datetime.now(UTC).isoformat(timespec="seconds")
    (OUT / name).write_text(json.dumps(obj, indent=1, default=float) + "\n")


def r(name: str) -> pd.DataFrame:
    return pd.read_csv(RESULTS_DIR / name)


def num(x):
    return None if pd.isna(x) else round(float(x), 4)


def headline() -> dict:
    fr = r("credit_frontier_datecluster.csv")
    fm = r("credit_frontier_month.csv")
    cs = r("credit_summary.csv")
    bt_ = r("backtest_test_chosen.csv")
    ci22 = r("m22_headline_ci.csv")
    rates = json.loads((RESULTS_DIR / "morpho_rates_snapshot.json").read_text())
    conc = r("bad_debt_regime_concentration.csv")
    u = fr[fr.group == "UNIVERSE12"].set_index("base_lltv")
    um = fm[fm.group == "UNIVERSE12"].set_index("base_lltv")

    def row(g, lt):
        return cs[(cs.group == g) & (cs.control == lt) & (cs.scenario == "blind")
                  & (cs.arm == "control")].iloc[0]

    c86, c77 = row("UNIVERSE12", "morpho_86"), row("UNIVERSE12", "morpho_77")
    weekend = bt_[(bt_.cls == "Weekend") & (bt_.ticker == "ALL") & (bt_.q == 0.99)].iloc[0]

    def cirow(cluster, what, lltv):
        s = ci22[(ci22.cluster == cluster) & (ci22.what == what) & (ci22.lltv == lltv)].iloc[0]
        return {"est": num(s.est), "lo": num(s.ci_lo), "hi": num(s.ci_hi)}

    def apr(asset, util, lltv):
        return cirow("date", f"{asset} boosted {util} break-even APR %", lltv)

    mk = rates["markets"]
    return {
        "source": [R + n for n in ("credit_frontier_datecluster.csv", "credit_summary.csv",
                                   "bad_debt_regime_concentration.csv", "backtest_test_chosen.csv",
                                   "m22_headline_ci.csv", "morpho_rates_snapshot.json")],
        "flat": {
            "bps_yr_86": {"est": num(c86.annualised_bad_debt_bps),
                          "lo": num(u.loc["morpho_86"].flat_ci_lo),
                          "hi": num(u.loc["morpho_86"].flat_ci_hi)},
            "bps_yr_77": num(c77.annualised_bad_debt_bps),
            "worst_window_pct_86": num(c86.lender_loss_max_pct),
            "mar2020_share_pct_86": num(conc[conc.control == "morpho_86"]
                                        .share_of_flat_bad_debt_pct.iloc[0]),
            "ci_cluster": "date (window open date), 2,000 resamples",
        },
        "stress": {name: {
            "flat_bps_yr": num(u.loc[name].flat_bad_debt_bps_yr),
            "stress_bps_yr": num(u.loc[name].treat_bad_debt_bps_yr),
            "reduction_bps_yr": num(u.loc[name].reduction_bps_yr),
            "reduction_ci": [num(u.loc[name].reduction_ci_lo), num(u.loc[name].reduction_ci_hi)],
            "reduction_pct": num(u.loc[name].reduction_pct),
            "ltv_gain_pp": num(u.loc[name].ltv_gain_pp),
            "ltv_gain_ci": [num(u.loc[name].gain_ci_lo), num(u.loc[name].gain_ci_hi)],
            "ltv_gain_ci_month": [num(um.loc[name].gain_ci_lo), num(um.loc[name].gain_ci_hi)],
        } for name in ("morpho_86", "cf_90", "cf_93", "cf_95")},
        "bonus": {"lltv86": {"reduction": cirow("date", "reduction 5.5%->2%", 0.86),
                             "at_5_5": cirow("date", "bonus 5.5%", 0.86),
                             "at_2": cirow("date", "bonus 2%", 0.86)},
                  "lltv93": {"reduction": cirow("date", "reduction 5.5%->2%", 0.93),
                             "at_5_5": cirow("date", "bonus 5.5%", 0.93),
                             "at_2": cirow("date", "bonus 2%", 0.93)}},
        "boosted_breakeven_apr_pct": {
            a: {f"{int(lt * 100)}": {"uniform": apr(a, "uniform", lt),
                                     "clustered": apr(a, "high", lt)} for lt in (0.90, 0.93)}
            for a in ("SPY", "AAPL", "TSLA", "NVDA")},
        "measured_borrow_apr_pct": {
            "block": rates["block"], "retrieved_utc": rates["retrieved_utc"],
            "AAPL": num(mk["AAPL"]["borrow_apr_pct"]), "SPY": num(mk["SPY"]["borrow_apr_pct"]),
            "NVDA": num(mk["NVDA"]["borrow_apr_pct"]),
            "large_usdg_markets": num(mk["ref:USDe(91.5%)"]["borrow_apr_pct"]),
            "spy_util": num(mk["SPY"]["utilisation"]), "aapl_util": num(mk["AAPL"]["utilisation"]),
        },
        "var99_weekend": {"rate_pct": num(100 * weekend.rate),
                          "ci": [num(100 * weekend.rate_ci_lo), num(100 * weekend.rate_ci_hi)],
                          "n": int(weekend.n), "target_pct": 1.0},
    }


def gap_hists(panel: pd.DataFrame) -> dict:
    edges = np.arange(-1000, 626, 25)
    out = {}
    for t in DEPLOY_SUBSET:
        g = panel[panel.ticker == t]
        per = {}
        for cls in ("Overnight", "Weekend", "Long"):
            x = np.clip(g[g.cls == cls].gap_bps.to_numpy(float), edges[0], edges[-1] - 1)
            h, _ = np.histogram(x, bins=edges)
            per[cls] = {"n": int(len(x)), "density": [round(float(v), 6) for v in h / h.sum()]}
        out[t] = per
    stats = r("class_stats.csv")
    stats = stats[stats.ticker.isin(DEPLOY_SUBSET)]
    return {"source": ["research/data/derived/<TICKER>.csv (histograms)", R + "class_stats.csv"],
            "bin_edges_bps": edges.tolist(), "clipped": "values clipped to [-1000, +600) bps",
            "hist": out,
            "stats": [{k: (num(v) if isinstance(v, float) else v) for k, v in rec.items()}
                      for rec in stats.to_dict("records")]}


def backtest(panel: pd.DataFrame) -> dict:
    df = bt.blind_panel(panel)
    _, chosen = bt.select_estimators(df, 0.99)
    var, _, _, _ = rb.final_forecast(df, chosen, 0.99)
    series = {}
    for t in ("SPY", "TSLA"):
        s = ((df.ticker == t) & (df.cls == "Weekend") & (df.d2 >= "2018-01-01")).to_numpy()
        d = df[s]
        series[t] = {"date": d.d2.dt.strftime("%Y-%m-%d").tolist(),
                     "loss_bps": [round(float(v), 1) for v in d.loss],
                     "var99_bps": [round(float(v), 1) for v in var[s]]}
    ev = r("backtest_test_chosen.csv")
    allrows = ev[ev.ticker == "ALL"]
    het = r("estimator_heterogeneity.csv")
    het = het[(het.cls == "Weekend") & (het.variant == "pooled_scales")]
    return {
        "source": [R + "backtest_test_chosen.csv", R + "backtest_regimes_test.csv",
                   R + "estimator_heterogeneity.csv", "research/run_backtest.py (VaR series)"],
        "chosen": chosen.name,
        "coverage": [{k: (num(v) if isinstance(v, float) else v) for k, v in rec.items()}
                     for rec in allrows[["cls", "q", "n", "violations", "rate", "target",
                                         "kupiec_p", "christoffersen_ind_p", "rate_ci_lo",
                                         "rate_ci_hi", "es_over_var", "multiplier"]]
                     .to_dict("records")],
        "regimes": [{k: (num(v) if isinstance(v, float) else v) for k, v in rec.items()}
                    for rec in r("backtest_regimes_test.csv").query("q == 0.99")
                    .to_dict("records")],
        "weekend_rate_by_asset": [{"ticker": x.ticker, "rate_pct": num(100 * x.rate), "n": int(x.n),
                                   "kupiec_p": num(x.kupiec_p)} for x in het.itertuples()],
        "series": series,
    }


def frontier() -> dict:
    cur = r("credit_frontier_curve_datecluster.csv")
    pts = r("credit_frontier_datecluster.csv")
    out = {}
    for g in ("UNIVERSE12", "DEPLOY4"):
        c = cur[cur.group == g]
        p = pts[pts.group == g]
        out[g] = {
            "curve": {"lltv_pct": c.lltv_pct.tolist(),
                      "bps": [num(v) for v in c.annualised_bad_debt_bps],
                      "lo": [num(v) for v in c.ci_lo], "hi": [num(v) for v in c.ci_hi]},
            "points": [{"base": x.base_lltv, "kind": x.kind,
                        "lltv_pct": {"morpho_86": 86, "cf_90": 90, "cf_93": 93,
                                     "cf_95": 95}[x.base_lltv],
                        "flat_bps": num(x.flat_bad_debt_bps_yr),
                        "treat_bps": num(x.treat_bad_debt_bps_yr),
                        "treat_ci": [num(x.treat_ci_lo), num(x.treat_ci_hi)],
                        "reduction_bps": num(x.reduction_bps_yr),
                        "reduction_ci": [num(x.reduction_ci_lo), num(x.reduction_ci_hi)],
                        "gain_pp": num(x.ltv_gain_pp),
                        "gain_ci": [num(x.gain_ci_lo), num(x.gain_ci_hi)]} for x in p.itertuples()]}
    return {"source": [R + "credit_frontier_curve_datecluster.csv",
                       R + "credit_frontier_datecluster.csv"],
            "cluster": "window open date, 2,000 resamples, 2018-2026", "groups": out}


def params() -> dict:
    p = json.loads(RISK_PARAMS_PATH.read_text())
    keep = {}
    for t in DEPLOY_SUBSET:
        a = p["assets"][t]
        keep[t] = {"seed_sigma2_bps2": a["seed"]["sigma2_bps2"], "classes": {
            c: {"class_scale_k": v["class_scale_k"], "floor_bps_train95": v["floor_bps_train95"],
                "q9900": {k: v["by_quantile"]["q9900"][k] for k in
                          ("multiplier", "gap_var_bps_at_data_end", "stress_ltv_cap_bps")},
                "q9950": {k: v["by_quantile"]["q9950"][k] for k in
                          ("multiplier", "gap_var_bps_at_data_end", "stress_ltv_cap_bps")}}
            for c, v in a["classes"].items()}}
    return {"source": ["deployments/risk_params.json"], "data_through": p["data_through"],
            "estimator": p["estimator"], "global": p["global"], "status": p["status"],
            "assets": keep}


def replay() -> dict:
    ev = json.loads(REPLAY_EVENTS_PATH.read_text())
    top = r("top_loss_windows.csv")
    pa = r("per_asset_credit.csv")
    pa = pa[pa.ticker.isin(DEPLOY_SUBSET) & pa.control.isin(["morpho_86", "cf_90", "cf_93"])]
    return {
        "source": ["sim/replay_events.json", R + "top_loss_windows.csv",
                   R + "per_asset_credit.csv"],
        "events_meta": {k: ev[k] for k in ("kind", "basis", "price_adjustment", "source",
                                           "selection")},
        "events": ev["events"],
        "top_windows": [{"control": x.control, "ticker": x.ticker, "date": str(x.date)[:10],
                         "cls": x.cls, "gap_bps": num(x.gap_bps), "var_bps": num(x.var_bps),
                         "flat_loss_pct": num(x.flat_loss_pct),
                         "stress_loss_pct": num(x.stress_loss_pct)} for x in top.itertuples()],
        "per_asset": [{"control": x.control, "ticker": x.ticker, "flat_bps_yr": num(x.flat_bps_yr),
                       "stress_bps_yr": num(x.stress_bps_yr),
                       "reduction_pct": num(x.reduction_pct),
                       "windows_cap_binds": int(x.windows_cap_binds),
                       "worst_window_loss_pct_flat": num(x.worst_window_loss_pct_flat),
                       "worst_window_loss_pct_stress": num(x.worst_window_loss_pct_stress)}
                      for x in pa.itertuples()],
    }


def main() -> None:
    panel = load_panel()
    w("headline.json", headline())
    w("gaps.json", gap_hists(panel))
    w("backtest.json", backtest(panel))
    w("frontier.json", frontier())
    w("params.json", params())
    w("replay.json", replay())
    print("wrote", sorted(p.name for p in OUT.glob("*.json")))


if __name__ == "__main__":
    main()
