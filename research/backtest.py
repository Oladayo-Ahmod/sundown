"""Estimator selection, calibration and out-of-sample VaR backtests.

Protocol (no test-set leakage):
  1. Multiplier m calibrated on [start, CAL_END]; candidates scored on the validation slice
     (CAL_END, TRAIN_END] by normalised pinball loss at the q-quantile; best per class chosen.
  2. m refit on [start, TRAIN_END] for the chosen candidate; evaluated on [TEST_START, end].
  3. The full grid is also reported on the test slice for transparency (never used to choose).
Multipliers are pooled across assets within a class (per-asset multipliers would overfit the
tiny Short/Long samples). Kupiec POF and Christoffersen independence tests are applied per
(asset, class) and pooled; pooled p-values ignore cross-asset dependence and are therefore
anti-conservative, which is why month-cluster bootstrap CIs on the pooled rate are given.
"""

from __future__ import annotations

import math

import numpy as np
import pandas as pd
from scipy.stats import chi2

import estimators as est
from config import BLIND_CLASSES, CAL_END, SEED, TEST_START, TRAIN_END

M_FLOOR = 1.0  # never tighten below the Gaussian sigma*z baseline on small samples
SELECTION_TOLERANCE = 0.02  # fixed before looking at test data: simplest within 2 % of best
COMPLEXITY = {"pooled": 0, "ewma": 1, "hs": 2, "blend": 3}  # on-chain state, low = simpler


def blind_panel(panel: pd.DataFrame) -> pd.DataFrame:
    df = panel[panel.cls.isin(BLIND_CLASSES)].copy()
    df["loss"] = -df.gap_bps.astype(float)
    return df.sort_values(["ticker", "d2"]).reset_index(drop=True)


def class_scales(df: pd.DataFrame) -> dict[str, float]:
    """k_c = sqrt(median over assets of E[x^2|c] / E[x^2|Weekend]); fixed, from `df` only."""
    ms = df.assign(sq=df.loss**2).groupby(["ticker", "cls"]).sq.mean().unstack()
    ratio = ms.div(ms["Weekend"], axis=0)
    return {c: float(np.sqrt(ratio[c].median())) for c in BLIND_CLASSES}


def raw_forecasts(df: pd.DataFrame, cand: est.Candidate, q: float,
                  scales: dict[str, float]) -> np.ndarray:
    out = np.full(len(df), np.nan)
    for _, idx in df.groupby("ticker").indices.items():
        sub = df.iloc[idx]
        out[idx] = est.raw_forecast(sub.cls.to_numpy(), sub.loss.to_numpy(), cand, q, scales)
    return out


def calibrate_multiplier(df: pd.DataFrame, raw: np.ndarray, q: float, mask: np.ndarray
                         ) -> dict[str, float]:
    """m_c = q-quantile ('higher') of L/raw over the calibration slice: violation rate on that
    slice is <= 1-q by construction. Falls back to 1.0 with < 20 observations."""
    m = {}
    for c in BLIND_CLASSES:
        sel = mask & (df.cls.to_numpy() == c) & np.isfinite(raw) & (raw > 0)
        if sel.sum() < 20:
            m[c] = 1.0
            continue
        ratio = df.loss.to_numpy()[sel] / raw[sel]
        m[c] = max(float(np.quantile(ratio, q, method="higher")), M_FLOOR)
    return m


def apply_multiplier(df: pd.DataFrame, raw: np.ndarray, m: dict[str, float]) -> np.ndarray:
    return raw * df.cls.map(m).to_numpy(dtype=float)


def pinball(loss: np.ndarray, var: np.ndarray, q: float) -> np.ndarray:
    d = loss - var
    return d * (q - (loss < var))


def _slices(df: pd.DataFrame):
    d = df.d2
    cal = (d <= CAL_END).to_numpy()
    val = ((d > CAL_END) & (d <= TRAIN_END)).to_numpy()
    train = (d <= TRAIN_END).to_numpy()
    test = (d >= TEST_START).to_numpy()
    return cal, val, train, test


def validation_score(df, var, q, mask, cls) -> float:
    """Mean over assets of sum(pinball)/sum(|gap|) on the slice, for one class."""
    vals = []
    for _, idx in df.groupby("ticker").indices.items():
        sel = np.zeros(len(df), bool)
        sel[idx] = True
        sel &= mask & (df.cls.to_numpy() == cls) & np.isfinite(var)
        if sel.sum() < 5:
            continue
        pb = pinball(df.loss.to_numpy()[sel], var[sel], q).sum()
        vals.append(pb / np.abs(df.loss.to_numpy()[sel]).sum())
    return float(np.mean(vals)) if vals else np.nan


def select_estimators(df: pd.DataFrame, q: float = 0.99):
    """Returns (validation table for all candidates, chosen global Candidate).

    One estimator for all classes (fewer parameters, less on-chain state, less selection noise
    on the tiny Short/Long samples). Score = mean over classes of the normalised validation
    pinball loss; the simplest candidate within SELECTION_TOLERANCE of the best score wins
    (complexity order: pooled < ewma < hs < blend), ties broken by score.
    """
    cal, val, _, _ = _slices(df)
    sc = class_scales(df[cal])
    rows = []
    for cand in est.grid():
        raw = raw_forecasts(df, cand, q, sc)
        m = calibrate_multiplier(df, raw, q, cal)
        var = apply_multiplier(df, raw, m)
        for c in BLIND_CLASSES:
            sel = val & (df.cls.to_numpy() == c) & np.isfinite(var)
            viol = (df.loss.to_numpy()[sel] > var[sel]).mean() if sel.any() else np.nan
            rows.append({"candidate": cand.name, "cls": c, "m": m[c],
                         "n_val": int(sel.sum()), "val_violation_rate": viol,
                         "val_pinball_norm": validation_score(df, var, q, val, c)})
    tab = pd.DataFrame(rows)
    agg = tab.groupby("candidate").val_pinball_norm.mean().rename("score")
    by_name = {c.name: c for c in est.grid()}
    best = agg.min()
    ok = agg[agg <= best * (1 + SELECTION_TOLERANCE)].index
    chosen = sorted(ok, key=lambda n: (COMPLEXITY[by_name[n].kind], agg[n]))[0]
    tab = tab.merge(agg, left_on="candidate", right_index=True)
    return tab, by_name[chosen]


# ------------------------------------------------------------------ statistical tests

def _xlogy(x, y):
    return 0.0 if x == 0 else x * math.log(y)


def kupiec(n: int, x: int, p: float) -> tuple[float, float]:
    if n == 0:
        return np.nan, np.nan
    ph = x / n
    ll0 = _xlogy(n - x, 1 - p) + _xlogy(x, p)
    ll1 = _xlogy(n - x, 1 - ph) + _xlogy(x, ph)
    lr = max(-2.0 * (ll0 - ll1), 0.0)
    return lr, float(chi2.sf(lr, 1))


def christoffersen_independence(seqs: list[np.ndarray]) -> tuple[float, float]:
    """LR_ind from first-order transition counts pooled over sequences (NaN if undefined)."""
    n = np.zeros((2, 2))
    for s in seqs:
        s = s.astype(int)
        for a, b in zip(s[:-1], s[1:], strict=True):
            n[a, b] += 1
    n00, n01, n10, n11 = n[0, 0], n[0, 1], n[1, 0], n[1, 1]
    if n00 + n01 == 0 or n10 + n11 == 0 or (n01 + n11) == 0:
        return np.nan, np.nan  # no (or only) violations: independence untestable
    p01, p11 = n01 / (n00 + n01), n11 / (n10 + n11)
    p = (n01 + n11) / n.sum()
    ll1 = (_xlogy(n00, 1 - p01) + _xlogy(n01, p01) + _xlogy(n10, 1 - p11) + _xlogy(n11, p11))
    ll0 = _xlogy(n00 + n10, 1 - p) + _xlogy(n01 + n11, p)
    lr = max(-2.0 * (ll0 - ll1), 0.0)
    return lr, float(chi2.sf(lr, 1))


def evaluate(df: pd.DataFrame, var: np.ndarray, q: float, mask: np.ndarray,
             n_boot: int = 1000) -> pd.DataFrame:
    """Per-class and per-(asset, class) violation statistics on `mask`."""
    rng = np.random.default_rng(SEED + 7)
    p = 1 - q
    rows = []
    loss = df.loss.to_numpy()
    ok = mask & np.isfinite(var)
    month = df.d2.dt.to_period("M").astype(str).to_numpy()
    for c in BLIND_CLASSES:
        sel = ok & (df.cls.to_numpy() == c)
        n, x = int(sel.sum()), int((loss[sel] > var[sel]).sum())
        seqs = [(loss[s] > var[s]) for _, idx in df.groupby("ticker").indices.items()
                for s in [np.isin(np.arange(len(df)), idx) & sel] if s.sum() > 1]
        lr_pof, p_pof = kupiec(n, x, p)
        lr_ind, p_ind = christoffersen_independence(seqs)
        exc = sel & (loss > var)
        es = float(np.mean(loss[exc] / var[exc])) if exc.any() else np.nan
        # month-cluster bootstrap of the pooled violation rate
        months = pd.unique(month[sel])
        viol_by_m = {m: (loss[sel & (month == m)] > var[sel & (month == m)]) for m in months}
        reps = []
        if len(months) > 1:
            for _ in range(n_boot):
                pick = rng.integers(0, len(months), len(months))
                arr = np.concatenate([viol_by_m[months[k]] for k in pick])
                reps.append(arr.mean())
        rows.append({"cls": c, "ticker": "ALL", "q": q, "n": n, "violations": x,
                     "rate": x / n if n else np.nan, "target": p, "kupiec_p": p_pof,
                     "christoffersen_ind_p": p_ind,
                     "rate_ci_lo": np.quantile(reps, 0.025) if reps else np.nan,
                     "rate_ci_hi": np.quantile(reps, 0.975) if reps else np.nan,
                     "es_over_var": es, "mean_var_bps": float(np.mean(var[sel])) if n else np.nan})
        for t, idx in df.groupby("ticker").indices.items():
            s = np.isin(np.arange(len(df)), idx) & sel
            nt, xt = int(s.sum()), int((loss[s] > var[s]).sum())
            if nt == 0:
                continue
            _, pp = kupiec(nt, xt, p)
            _, pi = christoffersen_independence([loss[s] > var[s]]) if nt > 1 else (np.nan, np.nan)
            exc = s & (loss > var)
            rows.append({"cls": c, "ticker": t, "q": q, "n": nt, "violations": xt,
                         "rate": xt / nt, "target": p, "kupiec_p": pp,
                         "christoffersen_ind_p": pi, "rate_ci_lo": np.nan, "rate_ci_hi": np.nan,
                         "es_over_var": float(np.mean(loss[exc] / var[exc])) if exc.any()
                         else np.nan,
                         "mean_var_bps": float(np.mean(var[s]))})
    return pd.DataFrame(rows)


REGIMES = {
    "Aug-2015 China devaluation/flash crash": ("2015-08-15", "2015-09-30"),
    "Dec-2018 selloff": ("2018-12-01", "2019-01-15"),
    "Mar-2020 COVID": ("2020-02-20", "2020-04-30"),
    "2022 rate shock (full year)": ("2022-01-01", "2022-12-31"),
    "Apr-2025 tariff shock": ("2025-03-25", "2025-05-15"),
}


def regime_breakdown(df: pd.DataFrame, var: np.ndarray, q: float, mask: np.ndarray
                     ) -> pd.DataFrame:
    loss = df.loss.to_numpy()
    ok = mask & np.isfinite(var)
    viol = loss > var
    rows = []
    in_any = np.zeros(len(df), bool)
    for name, (a, b) in REGIMES.items():
        r = ((df.d2 >= a) & (df.d2 <= b)).to_numpy()
        in_any |= r
        s = ok & r
        rows.append({"regime": name, "q": q, "n": int(s.sum()), "violations": int(viol[s].sum()),
                     "rate": float(viol[s].mean()) if s.any() else np.nan})
    s = ok & ~in_any
    rows.append({"regime": "all other test windows", "q": q, "n": int(s.sum()),
                 "violations": int(viol[s].sum()), "rate": float(viol[s].mean())})
    return pd.DataFrame(rows)


def exceedance_clusters(df: pd.DataFrame, var: np.ndarray, mask: np.ndarray, top: int = 12
                        ) -> pd.DataFrame:
    """Months with the most cross-asset exceedances (flags regimes without pre-selecting)."""
    viol = (df.loss.to_numpy() > var) & mask & np.isfinite(var)
    m = df.d2.dt.to_period("M").astype(str)
    t = pd.DataFrame({"month": m[viol]}).groupby("month").size().sort_values(ascending=False)
    return t.head(top).rename("exceedances").reset_index()
