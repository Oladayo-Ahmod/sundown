"""Descriptive statistics of gaps per asset and window class, and variance-ratio tests.

Gap x = ln(open_D2 / close_D1) (log return, previous regular close -> next regular open).
Losses are reported as -x (log units). With daily data this is a conservative superset of the
true oracle-blind exposure (see intraday_study.py for the quantified difference).
"""

from __future__ import annotations

import numpy as np
import pandas as pd
from scipy import stats

from config import ALL_CLASSES, BLIND_CLASSES, QUANTILES, SEED


def class_stats(panel: pd.DataFrame, col: str = "gap_bps") -> pd.DataFrame:
    rows = []
    for (tkr, cls), g in panel.groupby(["ticker", "cls"]):
        x = g[col].to_numpy(dtype=float)
        row = {"ticker": tkr, "cls": cls, "n": len(x), "mean_bps": x.mean(),
               "std_bps": x.std(ddof=1) if len(x) > 1 else np.nan,
               "rms_bps": float(np.sqrt(np.mean(x**2))),
               "skew": stats.skew(x) if len(x) > 2 else np.nan,
               "excess_kurtosis": stats.kurtosis(x) if len(x) > 3 else np.nan,
               "worst_bps": x.min()}
        for q in QUANTILES:
            # downside quantile reported as a positive loss; 'higher' = conservative order stat
            row[f"loss_q{q * 100:g}_bps"] = -float(np.quantile(x, 1 - q, method="lower"))
        row["q_resolvable"] = "|".join(str(q) for q in QUANTILES if len(x) * (1 - q) >= 1)
        rows.append(row)
    out = pd.DataFrame(rows)
    out["cls"] = pd.Categorical(out.cls, ALL_CLASSES, ordered=True)
    return out.sort_values(["ticker", "cls"]).reset_index(drop=True)


def _month_sufficient_stats(panel: pd.DataFrame):
    """Per (ticker, class, month): count and sum of squared gaps -> arrays for fast bootstrap."""
    p = panel.assign(month=panel.d2.dt.to_period("M"), sq=panel.gap_bps**2)
    months = sorted(p.month.unique())
    midx = {m: i for i, m in enumerate(months)}
    tickers = sorted(p.ticker.unique())
    tidx = {t: i for i, t in enumerate(tickers)}
    cidx = {c: i for i, c in enumerate(ALL_CLASSES)}
    cnt = np.zeros((len(tickers), len(ALL_CLASSES), len(months)))
    s2 = np.zeros_like(cnt)
    for r in p.itertuples():
        i, j, k = tidx[r.ticker], cidx[r.cls], midx[r.month]
        cnt[i, j, k] += 1
        s2[i, j, k] += r.sq
    return tickers, months, cnt, s2


def variance_ratios(panel: pd.DataFrame, n_boot: int = 4000) -> pd.DataFrame:
    """Second-moment ratio E[x^2 | class] / E[x^2 | Overnight] with month-cluster bootstrap CI.

    Resampling whole calendar months (jointly across assets) keeps volatility clustering and
    cross-asset dependence intact. Per-asset ratios and the cross-asset median are reported.
    Reference lines: 1.0 (trading-time scaling) and calendar-time scaling n_cal/1 where
    n_cal = closed days + 1 (Short 2, Weekend 3, Long >=4: reported for Long as 4).
    """
    tickers, months, cnt, s2 = _month_sufficient_stats(panel)
    rng = np.random.default_rng(SEED)
    n_m = len(months)
    w = rng.multinomial(n_m, np.full(n_m, 1 / n_m), size=n_boot).astype(float)  # (B, M)

    def ratios(weights):
        # weights: (B, M) -> (B, T, C) of class second moment / overnight second moment
        c = np.einsum("tcm,bm->btc", cnt, weights)
        s = np.einsum("tcm,bm->btc", s2, weights)
        with np.errstate(invalid="ignore", divide="ignore"):
            m2 = s / c
            return m2 / m2[:, :, [0]]

    point = ratios(np.ones((1, n_m)))[0]
    boot = ratios(w)
    ref_cal = {"Short": 2.0, "Weekend": 3.0, "Long": 4.0}
    rows = []
    for j, cls in enumerate(ALL_CLASSES):
        if cls == "Overnight":
            continue
        for i, t in enumerate(tickers):
            b = boot[:, i, j]
            b = b[np.isfinite(b)]
            rows.append({"ticker": t, "cls": cls, "vr": point[i, j],
                         "ci_lo": np.quantile(b, 0.025) if len(b) else np.nan,
                         "ci_hi": np.quantile(b, 0.975) if len(b) else np.nan,
                         "n_blind": int(cnt[i, j].sum()), "n_overnight": int(cnt[i, 0].sum()),
                         "ref_trading_time": 1.0, "ref_calendar_time": ref_cal[cls]})
        pooled = np.nanmedian(boot[:, :, j], axis=1)
        rows.append({"ticker": "MEDIAN", "cls": cls, "vr": np.nanmedian(point[:, j]),
                     "ci_lo": np.quantile(pooled, 0.025), "ci_hi": np.quantile(pooled, 0.975),
                     "n_blind": int(cnt[:, j].sum()), "n_overnight": int(cnt[:, 0].sum()),
                     "ref_trading_time": 1.0, "ref_calendar_time": ref_cal[cls]})
    out = pd.DataFrame(rows)
    out["cls"] = pd.Categorical(out.cls, BLIND_CLASSES, ordered=True)
    return out.sort_values(["cls", "ticker"]).reset_index(drop=True)


def quantile_cis(panel: pd.DataFrame, level: float = 0.99, n_boot: int = 1000) -> pd.DataFrame:
    """Month-cluster bootstrap CI of the empirical downside quantile per asset/class."""
    rng = np.random.default_rng(SEED + 1)
    p = panel.assign(month=panel.d2.dt.to_period("M"))
    rows = []
    for (tkr, cls), g in p.groupby(["ticker", "cls"]):
        if cls == "Overnight":
            continue
        groups = [grp.gap_bps.to_numpy() for _, grp in g.groupby("month")]
        point = -np.quantile(np.concatenate(groups), 1 - level, method="lower")
        reps = []
        for _ in range(n_boot):
            pick = rng.integers(0, len(groups), len(groups))
            reps.append(-np.quantile(np.concatenate([groups[k] for k in pick]), 1 - level,
                                     method="lower"))
        rows.append({"ticker": tkr, "cls": cls, "q": level, "n": int(sum(map(len, groups))),
                     "loss_bps": point, "ci_lo": np.quantile(reps, 0.025),
                     "ci_hi": np.quantile(reps, 0.975)})
    return pd.DataFrame(rows)


def dividend_sensitivity(panel: pd.DataFrame) -> pd.DataFrame:
    """Effect of ex-dividend handling on the 99% blind-window loss quantile."""
    rows = []
    blind = panel[panel.cls.isin(BLIND_CLASSES)]
    for tkr, g in blind.groupby("ticker"):
        a = -np.quantile(g.gap_bps, 0.01, method="lower")
        b = -np.quantile(g.gap_divneutral_bps, 0.01, method="lower")
        rows.append({"ticker": tkr, "blind_windows": len(g), "exdiv_windows": int(g.exdiv.sum()),
                     "mean_div_bps_on_exdiv": float(g.loc[g.exdiv, "div_bps"].mean()),
                     "q99_loss_raw_bps": a, "q99_loss_divneutral_bps": b})
    return pd.DataFrame(rows)


def censoring_daily(panel: pd.DataFrame, threshold_bps: float = 50.0) -> pd.DataFrame:
    """N2 daily-data part: how many gaps sit below the oracle deviation threshold (would not
    by themselves trigger a post-window push update) and how dropping them biases tail
    estimates. 'implied_conf' is the full-sample confidence level whose quantile equals the
    nominal-99% quantile of the censored (|gap| >= threshold) sample."""
    rows = []
    blind = panel[panel.cls.isin(BLIND_CLASSES)]
    for (tkr, cls), g in blind.groupby(["ticker", "cls"]):
        x = g.gap_bps.to_numpy()
        keep = np.abs(x) >= threshold_bps
        if keep.sum() < 20:
            continue
        q_cens = np.quantile(x[keep], 0.01, method="lower")
        implied = float(np.mean(x <= q_cens))  # tail mass in the full sample beyond that point
        rows.append({"ticker": tkr, "cls": cls, "n": len(x),
                     "share_below_threshold": 1 - keep.mean(),
                     "q99_loss_full_bps": -np.quantile(x, 0.01, method="lower"),
                     "q99_loss_censored_bps": -q_cens,
                     "implied_full_sample_conf": 1 - implied})
    return pd.DataFrame(rows)
