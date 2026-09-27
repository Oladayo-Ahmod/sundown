"""Write deployments/risk_params.json and sim/replay_events.json from the research results."""

from __future__ import annotations

import json
import math
from datetime import UTC, datetime

import numpy as np
import pandas as pd

import backtest as bt
import estimators as est
from config import (
    BLIND_CLASSES,
    CAL_END,
    DEPLOY_SUBSET,
    DERIVED_DIR,
    ORACLE_DEVIATION_BPS,
    RAW_DIR,
    REPLAY_EVENTS_PATH,
    RISK_PARAMS_PATH,
    SAFETY_BUFFER_BPS,
    TEST_START,
    TRAIN_END,
    UNIVERSE,
)
from data import load_raw

WAD = est.WAD
FEED_LISTED = {"AAPL", "NVDA", "TSLA", "SPY", "QQQ", "AMZN", "GOOGL", "META", "MSFT"}
LLTV_CEILING_BPS = 8600  # highest LLTV observed in the wild (Morpho on Robinhood)
LLTV_STEP_BPS = 50
STRESS_QS = [0.99, 0.995]
REPLAY_TOP_ALL = 25
REPLAY_TOP_PER_DEPLOYED = 10


def _wad(x: float) -> int:
    return int(round(x * WAD))


def _floor_step(bps: float) -> int:
    return int(math.floor(bps / LLTV_STEP_BPS) * LLTV_STEP_BPS)


def _bonus_bounds(lltv_bps: int) -> dict:
    """Design-derived (NOT calibrated: liquidation liquidity is unmeasured). min is a prior;
    max is half the largest bonus that keeps a position at its LLTV solvent (1/LLTV - 1),
    capped at 10 %."""
    lltv = max(lltv_bps, 1) / 1e4
    solvent = 1 / lltv - 1
    return {"min": 100, "max": int(min(1000, math.floor(0.5 * solvent * 1e4))),
            "basis": "design-derived prior, unvalidated"}


def deployment_fit(df: pd.DataFrame, chosen: est.Candidate) -> dict:
    """Refit scales and multipliers on the full history (structure chosen on validation,
    out-of-sample evidence comes from the train-only fit reported in results/)."""
    allm = np.ones(len(df), bool)
    sc = bt.class_scales(df)
    fit = {"scales": sc, "m": {}, "state": {}}
    for q in STRESS_QS:
        raw = bt.raw_forecasts(df, chosen, q, sc)
        fit["m"][q] = bt.calibrate_multiplier(df, raw, q, allm)
    for t, g in df.groupby("ticker"):
        k = g.cls.map(sc).to_numpy(float)
        sq = (g.loss.to_numpy(float) / k) ** 2
        num = den = 0.0
        for v in sq:
            num = chosen.lam * num + v
            den = chosen.lam * den + 1.0
        fit["state"][t] = (num, den, len(g))
    return fit


def risk_params(df: pd.DataFrame, chosen: est.Candidate, forecasts, floor: pd.DataFrame,
                data_through: str) -> dict:
    fit = deployment_fit(df, chosen)
    floor_map = {(r.ticker, r.cls): r.floor for r in floor.itertuples()}
    assets = {}
    for t in UNIVERSE:
        num, den, n_obs = fit["state"][t]
        sigma2 = num / den  # pooled-scaled variance, bps^2, in weekend units
        entry = {"deployed_market_candidate": t in DEPLOY_SUBSET,
                 "chainlink_feed_listed_in_discovery": t in FEED_LISTED,
                 "seed": {"sigma2_bps2": round(sigma2, 2), "sigma2_wad": _wad(sigma2),
                          "pseudo_count": min(10, round(den, 2)),
                          "n_obs_to_data_end": n_obs}}
        classes = {}
        for c in BLIND_CLASSES:
            k = fit["scales"][c]
            per_q = {}
            for q in STRESS_QS:
                m = fit["m"][q][c]
                var = m * est.z(q) * k * math.sqrt(sigma2)
                cap = 1e4 - var - ORACLE_DEVIATION_BPS - SAFETY_BUFFER_BPS
                rec = _floor_step(min(max(cap, 0), LLTV_CEILING_BPS))
                per_q[f"q{int(q * 1e4)}"] = {
                    "multiplier": round(m, 4), "multiplier_wad": _wad(m),
                    "z_wad": _wad(est.z(q)),
                    "gap_var_bps_at_data_end": round(var, 1),
                    "stress_ltv_cap_bps": int(max(0, min(1e4, cap))),
                    "recommended_lltv_bps": rec,
                    "cap_binds_below_lltv_ceiling": bool(cap < LLTV_CEILING_BPS),
                    "bonus_bounds_bps": _bonus_bounds(rec)}
            classes[c] = {
                "estimator": "pooled_scaled_ewma",
                "lambda": chosen.lam, "lambda_wad": _wad(chosen.lam),
                "N": None,
                "class_scale_k": round(k, 4), "class_scale_k_wad": _wad(k),
                "floor_bps_train95": round(float(floor_map.get((t, c), 0.0)), 1),
                "by_quantile": per_q}
        entry["classes"] = classes
        entry["base_lltv_bps_q9900"] = min(classes[c]["by_quantile"]["q9900"]
                                           ["recommended_lltv_bps"] for c in BLIND_CLASSES)
        assets[t] = entry
    return {
        "schema_version": 1,
        "generated_by": "research/run_backtest.py (outputs.py)",
        "generated_utc": datetime.now(UTC).isoformat(timespec="seconds"),
        "data_through": data_through,
        "status": "RESEARCH OUTPUT. Calibrated on daily proxy gaps (conservative superset of "
                  "the oracle-blind exposure); not an audited or governance-approved set.",
        "split": {"calibration_end": CAL_END, "train_end": TRAIN_END,
                  "test_start": TEST_START,
                  "note": "structure selected on 2015-2017 validation; deployment fit below is "
                          "refit on the full history; out-of-sample evidence in results/ uses "
                          "the train-only fit."},
        "units": {"gaps": "log bps, 1e4*ln(open/prev_close)",
                  "gap_var": "log bps, used as loss fraction (conservative: 1-exp(-v) < v)",
                  "wad": "1e18 fixed point"},
        "estimator": {
            "name": f"pooled-scaled EWMA, lambda={chosen.lam}",
            "recurrence": "num' = lambda*num + (loss/k_c)^2 ; den' = lambda*den + 1 ; "
                          "sigma2 = num/den (bps^2, weekend units)",
            "forecast": "gapVaR_c = multiplier_c * z_q * k_c * sqrt(sigma2)  [round up]",
            "min_prior_observations": est.K_MIN,
            "state_per_asset": "one (num, den) pair"},
        "global": {
            "stress_rule": "maxBorrowLTV = min(LLTV, 1 - gapVaR_q - oracleBuffer - safetyBuffer)",
            "quantile_default_bps": 9900,
            "oracle_buffer_bps": ORACLE_DEVIATION_BPS,
            "oracle_buffer_basis": "feed deviation threshold (irreducible allowance, N1)",
            "safety_buffer_bps": SAFETY_BUFFER_BPS,
            "lookahead_hours": 24,
            "early_close_shifts_window": False,
            "early_close_label": "UNVERIFIED (D1)",
            "multiplier_floor": bt.M_FLOOR,
            "lltv_ceiling_bps": LLTV_CEILING_BPS},
        "assets": assets}


# ---------------------------------------------------------------- replay events

def select_events(panel: pd.DataFrame) -> pd.DataFrame:
    blind = panel[panel.cls.isin(BLIND_CLASSES)].copy()
    blind["loss_bps"] = -blind.gap_bps
    top = blind.nlargest(REPLAY_TOP_ALL, "loss_bps")
    per = pd.concat([blind[blind.ticker == t].nlargest(REPLAY_TOP_PER_DEPLOYED, "loss_bps")
                     for t in DEPLOY_SUBSET])
    ev = pd.concat([top, per]).drop_duplicates(["ticker", "d2"])
    return ev.sort_values("loss_bps", ascending=False).reset_index(drop=True)


def _prices(ev: pd.DataFrame) -> dict[tuple[str, str], tuple[float, float]]:
    cache = DERIVED_DIR / "replay_prices.json"
    out: dict[tuple[str, str], tuple[float, float]] = {}
    if all((RAW_DIR / f"{t}_daily.csv").exists() for t in ev.ticker.unique()):
        for t, g in ev.groupby("ticker"):
            raw = load_raw(t)
            for r in g.itertuples():
                out[(t, str(r.d2.date()))] = (float(raw.Close.loc[r.d1]),
                                              float(raw.Open.loc[r.d2]))
        cache.write_text(json.dumps({f"{k[0]}|{k[1]}": v for k, v in out.items()}, indent=1)
                         + "\n")
    elif cache.exists():
        out = {tuple(k.split("|")): tuple(v) for k, v in json.loads(cache.read_text()).items()}
    else:
        raise FileNotFoundError("run `make data` once (needs raw prices) to create "
                                f"{cache}")
    return out


def replay_events(panel: pd.DataFrame) -> dict:
    import calendar_windows as cw

    ev = select_events(panel)
    px = _prices(ev)
    rows = []
    for r in ev.itertuples():
        b = cw.window_bounds(r.d1.date(), r.d2.date())
        pc, po = px[(r.ticker, str(r.d2.date()))]
        rows.append({
            "asset": r.ticker, "class": r.cls,
            "prev_close_date": str(r.d1.date()), "open_date": str(r.d2.date()),
            "prev_close": round(pc, 4), "open": round(po, 4),
            "gap_bps": round(float(r.gap_bps), 1), "loss_pct": round(float(r.loss_bps) / 100, 2),
            "n_closed_days": int(r.n_closed), "window_hours": float(r.hours),
            "window_start_utc": b[0].isoformat().replace("+00:00", "Z"),
            "window_end_utc": b[1].isoformat().replace("+00:00", "Z"),
            "ex_dividend_open": bool(r.exdiv)})
    return {
        "schema_version": 1,
        "generated_by": "research/run_backtest.py (outputs.py)",
        "kind": "replay of REAL historical gaps (daily proxy), not simulated prices",
        "basis": "previous regular close -> next regular open; conservative superset of the "
                 "oracle-blind exposure (see research/results/intraday_summary.json)",
        "price_adjustment": "split-adjusted as of retrieval date, not dividend-adjusted, not "
                            "as-traded; use the ratios, not absolute levels",
        "source": "Yahoo Finance via yfinance; excerpt of ~60 prices, see "
                  "research/DATA_PROVENANCE.md",
        "selection": f"top {REPLAY_TOP_ALL} blind-window losses across the research universe "
                     f"plus top {REPLAY_TOP_PER_DEPLOYED} for each deployed-subset asset "
                     f"({', '.join(DEPLOY_SUBSET)}), deduplicated, severity-ordered",
        "events": rows}


def write_all(panel, df, chosen, forecasts, floor) -> None:
    RISK_PARAMS_PATH.parent.mkdir(parents=True, exist_ok=True)
    through = str(panel.d2.max().date())
    RISK_PARAMS_PATH.write_text(json.dumps(risk_params(df, chosen, forecasts, floor, through),
                                           indent=2) + "\n")
    REPLAY_EVENTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPLAY_EVENTS_PATH.write_text(json.dumps(replay_events(panel), indent=2) + "\n")
