"""Intraday subset study (last ~730 days, hourly bars incl. pre/post market, Yahoo).

Three questions:
 1. How conservative is the daily proxy (prev regular close -> next regular open) versus an
    extended-hours bracket of the real blind window?
 2. Oracle noise (N1): with a 0.5 % deviation / 24 h heartbeat push feed, how far can the
    published price be from the true price at window start, in the adverse direction?
 3. Censoring (N2): if no update is pushed at reopen, how late and how biased is the first
    post-window observation?

LIMITS (read before quoting numbers): Yahoo hourly bars cover 04:00-20:00 ET only. The real
24/5 feed also sees the 20:00-04:00 overnight session, which we cannot. So the extended
bracket Fri 19:00-bar close -> Mon 04:00-bar open spans the blind window [Fri 20:00, Sun 20:00]
plus the visible Sun 20:00 -> Mon 04:00 stretch, i.e. it is still a superset of the blind
exposure. Feed behaviour is simulated on hourly samples (using bar high/low for deviation
crossings), not read from the chain. Raw intraday data is git-ignored; the 730-day Yahoo
window rolls, so re-running later yields different numbers (results/ holds the snapshot).
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta

import numpy as np
import pandas as pd

import calendar_windows as cw
from config import (
    BLIND_CLASSES,
    ORACLE_DEVIATION_BPS,
    ORACLE_HEARTBEAT_S,
    RAW_DIR,
    RESULTS_DIR,
    UNIVERSE,
)

DEV = ORACLE_DEVIATION_BPS / 1e4
BAND = float(np.log1p(DEV))


def download(ticker: str) -> pd.DataFrame:
    import yfinance as yf

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    start = (datetime.now(UTC) - timedelta(days=728)).strftime("%Y-%m-%d")
    h = yf.Ticker(ticker).history(start=start, interval="1h", prepost=True, auto_adjust=False)
    h = h[["Open", "High", "Low", "Close", "Volume"]].dropna(subset=["Open", "Close"])
    h.to_csv(RAW_DIR / f"{ticker}_1h.csv", float_format="%.6f")
    return h


def load(ticker: str) -> pd.DataFrame:
    h = pd.read_csv(RAW_DIR / f"{ticker}_1h.csv", index_col=0)
    h.index = pd.to_datetime(h.index, utc=True).tz_convert("America/New_York")
    return h


def simulate_feed(h: pd.DataFrame) -> pd.DataFrame:
    """Push-feed simulation over hourly bars. Returns one row per bar with the published
    price in force at the *end* of that bar and the publish time of that price."""
    t = h.index.tz_convert("UTC").to_numpy()
    o, hi, lo, c = (h[k].to_numpy(float) for k in ("Open", "High", "Low", "Close"))
    pub = np.empty(len(h))
    pub_t = np.empty(len(h), dtype="datetime64[ns]")
    last_p, last_t = o[0], t[0]
    for i in range(len(h)):
        # opening sample (catches overnight jumps) then intrabar extremes then close
        for price in (o[i],):
            if abs(np.log(price / last_p)) >= BAND:
                last_p, last_t = price, t[i]
        for _ in range(4):  # a crossing can repeat within a bar; bounded loop
            up, dn = np.log(hi[i] / last_p), np.log(last_p / lo[i])
            if max(up, dn) >= BAND:
                last_p = last_p * np.exp(BAND if up >= dn else -BAND)
                last_t = t[i]
            else:
                break
        if abs(np.log(c[i] / last_p)) >= BAND:
            last_p, last_t = c[i], t[i]
        elif (t[i] - last_t) / np.timedelta64(1, "s") >= ORACLE_HEARTBEAT_S:
            last_p, last_t = c[i], t[i]
        pub[i], pub_t[i] = last_p, last_t
    out = pd.DataFrame({"pub": pub, "pub_t": pub_t}, index=h.index)
    return out


def _last_regular_close(day_bars: pd.DataFrame, early: bool) -> float | None:
    cutoff = 13 if early else 16
    reg = day_bars[(day_bars.index.hour + day_bars.index.minute / 60 >= 9.5)
                   & (day_bars.index.hour + day_bars.index.minute / 60 < cutoff)]
    return float(reg.Close.iloc[-1]) if len(reg) else None


def study_asset(ticker: str, pairs: pd.DataFrame) -> list[dict]:
    h = load(ticker)
    feed = simulate_feed(h)
    by_day = {d: g for d, g in h.groupby(h.index.date)}
    feed_by_day = {d: g for d, g in feed.groupby(feed.index.date)}
    rows = []
    for r in pairs.itertuples():
        if r.d1 not in by_day or r.d2 not in by_day:
            continue
        a, b = by_day[r.d1], by_day[r.d2]
        fa = feed_by_day[r.d1]
        p_close = _last_regular_close(a, r.d1_early_close)
        reg_b = b[(b.index.hour + b.index.minute / 60) >= 9.5]
        if p_close is None or not len(reg_b) or not len(b):
            continue
        p_open = float(reg_b.Open.iloc[0])
        p_fri20 = float(a.Close.iloc[-1])  # last print before 20:00 ET
        p_mon04 = float(b.Open.iloc[0])  # first print of the extended session
        f_start = float(fa.pub.iloc[-1])  # published price when the window starts
        # true price at window start vs feed: positive err = feed overvalues collateral
        err_adverse = float(np.log(f_start / p_fri20))
        # N2 variant B': heartbeat timer restarts at reopen, no push on reopen itself
        reopen = b.index[0]
        post = b.copy()
        lag_h, rec_price, trig = np.nan, np.nan, "none"
        for ts, row in post.iterrows():
            up, dn = np.log(row.High / f_start), np.log(f_start / row.Low)
            if np.log(row.Open / f_start) >= BAND or np.log(f_start / row.Open) >= BAND:
                rec_price, trig, lag_h = row.Open, "deviation", (ts - reopen).total_seconds() / 3600
                break
            if max(up, dn) >= BAND:
                rec_price = f_start * np.exp(BAND if up >= dn else -BAND)
                trig, lag_h = "deviation", (ts - reopen).total_seconds() / 3600
                break
            if (ts - reopen).total_seconds() >= ORACLE_HEARTBEAT_S:
                rec_price, trig, lag_h = row.Open, "heartbeat", (ts - reopen).total_seconds() / 3600
                break
        if trig == "none":  # no trigger within the observed days: heartbeat price at 24 h
            tail = h[h.index >= reopen + timedelta(seconds=ORACLE_HEARTBEAT_S)]
            if len(tail):
                rec_price, trig = float(tail.Open.iloc[0]), "heartbeat"
                lag_h = (tail.index[0] - reopen).total_seconds() / 3600
        rows.append({
            "ticker": ticker, "d1": r.d1, "d2": r.d2, "cls": r.cls,
            "proxy_bps": 1e4 * np.log(p_open / p_close),
            "ext_bps": 1e4 * np.log(p_mon04 / p_fri20),
            "post_visible_bps": 1e4 * np.log(p_fri20 / p_close),
            "pre_visible_bps": 1e4 * np.log(p_open / p_mon04),
            "feed_err_adverse_bps": 1e4 * err_adverse,
            "reopen_ref_bps_vs_feed": 1e4 * np.log(p_mon04 / f_start),
            "n2_lag_h": lag_h,
            "n2_trigger": trig,
            "n2_recorded_bps": 1e4 * np.log(rec_price / f_start) if np.isfinite(rec_price)
            else np.nan,
        })
    return rows


def summarize(df: pd.DataFrame) -> dict:
    q = [0.5, 0.9, 0.95, 0.99, 1.0]
    out: dict = {"n_windows": int(len(df)),
                 "span": [str(df.d1.min()), str(df.d2.max())],
                 "by_class": df.groupby("cls").size().to_dict()}
    # 1. proxy superset
    out["proxy_vs_extended"] = {
        "rms_proxy_bps": float(np.sqrt((df.proxy_bps**2).mean())),
        "rms_extended_bps": float(np.sqrt((df.ext_bps**2).mean())),
        "var_ratio_ext_over_proxy": float((df.ext_bps**2).mean() / (df.proxy_bps**2).mean()),
        "rms_visible_post_16_20_bps": float(np.sqrt((df.post_visible_bps**2).mean())),
        "rms_visible_premarket_04_0930_bps": float(np.sqrt((df.pre_visible_bps**2).mean())),
        "q99_loss_proxy_bps": float(-np.quantile(df.proxy_bps, 0.01)),
        "q99_loss_extended_bps": float(-np.quantile(df.ext_bps, 0.01)),
        "corr_proxy_ext": float(np.corrcoef(df.proxy_bps, df.ext_bps)[0, 1]),
    }
    # 2. oracle noise
    adv = df.feed_err_adverse_bps.clip(lower=0)
    out["oracle_noise"] = {
        "abs_err_bps_quantiles": {str(k): float(np.quantile(df.feed_err_adverse_bps.abs(), k))
                                  for k in q},
        "adverse_err_bps_quantiles": {str(k): float(np.quantile(adv, k)) for k in q},
        "share_adverse_gt_25bps": float((adv > 25).mean()),
        "share_adverse_gt_40bps": float((adv > 40).mean()),
        "deviation_bound_bps": ORACLE_DEVIATION_BPS,
    }
    # 3. censoring
    ok = df.dropna(subset=["n2_lag_h", "n2_recorded_bps"])
    err = ok.n2_recorded_bps - ok.reopen_ref_bps_vs_feed
    out["censoring_B_prime_no_reopen_push"] = {
        "n": int(len(ok)),
        "share_deviation_triggered": float((ok.n2_trigger == "deviation").mean()),
        "share_heartbeat_triggered": float((ok.n2_trigger == "heartbeat").mean()),
        "lag_hours_quantiles": {str(k): float(np.quantile(ok.n2_lag_h, k)) for k in q},
        "recorded_minus_reference_bps_mean": float(err.mean()),
        "recorded_minus_reference_bps_abs_q90": float(np.quantile(err.abs(), 0.9)),
        "share_reference_below_threshold": float((ok.reopen_ref_bps_vs_feed.abs()
                                                  < ORACLE_DEVIATION_BPS).mean()),
        "recorded_downside_understates_reference_by_gt_50bps": float((err > 50).mean()),
    }
    return out


def run(refresh: bool = False, tickers: list[str] | None = None) -> dict:
    tickers = tickers or UNIVERSE
    if refresh:
        for t in tickers:
            download(t)
    pairs = cw.session_pairs((datetime.now(UTC) - timedelta(days=740)).strftime("%Y-%m-%d"),
                             (datetime.now(UTC) - timedelta(days=1)).strftime("%Y-%m-%d"))
    pairs = pairs[pairs.cls.isin(BLIND_CLASSES)]
    rows = []
    for t in tickers:
        rows += study_asset(t, pairs)
    df = pd.DataFrame(rows)
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    df.round(2).to_csv(RESULTS_DIR / "intraday_windows.csv", index=False)
    summ = summarize(df)
    per_asset = {}
    for t, g in df.groupby("ticker"):
        adv = g.feed_err_adverse_bps.clip(lower=0)
        per_asset[t] = {"n": len(g), "rms_proxy_bps": float(np.sqrt((g.proxy_bps**2).mean())),
                        "var_ratio_ext_over_proxy":
                        float((g.ext_bps**2).mean() / (g.proxy_bps**2).mean()),
                        "adverse_feed_err_q99_bps": float(np.quantile(adv, 0.99)),
                        "adverse_feed_err_max_bps": float(adv.max())}
    summ["per_asset"] = per_asset
    summ["generated_utc"] = datetime.now(UTC).isoformat(timespec="seconds")
    (RESULTS_DIR / "intraday_summary.json").write_text(json.dumps(summ, indent=2) + "\n")
    return summ


if __name__ == "__main__":
    import sys

    print(json.dumps(run(refresh="--refresh" in sys.argv), indent=2))
