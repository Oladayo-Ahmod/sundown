"""Enforcement mechanisms for the stressed cap (M2.1), simulated on the same event tables.

(a) cap on new borrows only: enforcement e = 0 (baseline) or a small turnover share.
(b) hard pre-window deleveraging: positions above the stressed cap get a cure window; a share
    `p_cure` of flagged borrowers repays/tops up voluntarily (cost: none modelled beyond the
    forgone leverage), the rest are deleveraged by the protocol down to the cap at a reduced
    fee plus collateral-sale slippage. Bad-debt effect equals enforcement e = 1 - failure.
(c) priced gap premium: borrowers may stay above the cap but pay `pi` (bps of the excess debt
    per window) into a gap reserve that absorbs bad debt before lenders. Reserve path is
    simulated chronologically per asset (isolated markets); exhaustion is measured in-sample
    and by a month-block bootstrap of 10-year paths.
Everything is per unit of outstanding debt (book of constant size); assumptions that are NOT
estimated from data (p_cure, fees, slippage) are parameters and are labelled as such.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

import credit_sim as cs
from config import SEED

P_CURE = 0.7  # ASSUMPTION: share of flagged borrowers who cure voluntarily in the cure window
FEE_REDUCED = 0.01  # ASSUMPTION: protocol fee on forced deleveraging (vs 1.5-4.4 % normal bonus)
SELL_SLIP = 0.01  # ASSUMPTION: slippage when the protocol sells collateral to deleverage
UTIL_KINDS = ["high", "uniform", "conservative"]  # clustered near max / uniform / conservative
PATH_YEARS = 10
N_PATHS = 400


def _res(ev, tick, ctl, p, treat):
    out = []
    for t in tick:
        g = ev[(t, "blind")]
        if len(g):
            out.append(cs.run_events(g.gap_bps.to_numpy(float),
                                     g["var"].to_numpy(float) if treat else None, ctl, p))
    return {k: np.concatenate([o[k] for o in out]) for k in out[0]}


def mech_a(ev, tick, ctl, years, util="uniform", turnover=0.0):
    p = cs.Params(util_weights=util, enforcement=turnover)
    c, t = _res(ev, tick, ctl, p, False), _res(ev, tick, ctl, p, True)
    n = len(tick)
    return {"mechanism": "a_new_borrows_only", "param": f"turnover={turnover}",
            "control_bps_yr": 1e4 * c["loss_ratio"].sum() / (n * years),
            "treat_bps_yr": 1e4 * t["loss_ratio"].sum() / (n * years)}


def mech_b(ev, tick, ctl, years, util, fail=0.0, p_cure=P_CURE, fee=FEE_REDUCED,
           slip=SELL_SLIP):
    p = cs.Params(util_weights=util, enforcement=1.0 - fail)
    c, t = _res(ev, tick, ctl, p, False), _res(ev, tick, ctl, p, True)
    n = len(tick)
    flagged = t["flagged"]
    forced = flagged * (1 - p_cure)
    excess_ratio = t["excess"] / t["base_debt"]
    cost_per_window = (1 - p_cure) * excess_ratio * (fee + slip)  # share of debt paid as cost
    return {
        "mechanism": "b_hard_deleveraging", "util": util, "enforcement_fail": fail,
        "control_bps_yr": 1e4 * c["loss_ratio"].sum() / (n * years),
        "treat_bps_yr": 1e4 * t["loss_ratio"].sum() / (n * years),
        "windows_with_flagged_pct": 100 * float((flagged > 0).mean()),
        "flagged_borrowers_per_100_per_window": 100 * float(flagged.mean()),
        "forced_borrowers_per_100_per_window": 100 * float(forced.mean()),
        "forced_per_100_in_windows_with_flags": 100 * float(forced[flagged > 0].mean())
        if (flagged > 0).any() else 0.0,
        "deleveraged_debt_pct_per_window": 100 * float(excess_ratio.mean()),
        "borrower_cost_bps_of_debt_per_year": 1e4 * float(cost_per_window.sum()) / (n * years),
        "forced_cost_bps_per_forced_borrower": 1e4 * (fee + slip),
    }


# ----------------------------------------------------------------------------- (c)

def reserve_residual(bad: np.ndarray, exc: np.ndarray, pi: float) -> np.ndarray:
    """Lender loss per event after the reserve absorbs what it can (reserve >= 0)."""
    r = 0.0
    out = np.zeros(len(bad))
    for i in range(len(bad)):
        r += pi * exc[i]
        take = min(r, bad[i])
        r -= take
        out[i] = bad[i] - take
    return out


def _asset_series(ev, t, ctl, util):
    g = ev[(t, "blind")]
    r = cs.run_events(g.gap_bps.to_numpy(float), g["var"].to_numpy(float), ctl,
                      cs.Params(util_weights=util, enforcement=0.0))
    months = g.d2.dt.to_period("M").astype(str).to_numpy()
    return r["loss_ratio"], r["excess"] / r["base_debt"], months


def mech_c(ev, tick, ctl, years, util, multiples=(1, 2, 5, 10, 25), seed=SEED):
    rng = np.random.default_rng(seed + 31)
    series = {t: _asset_series(ev, t, ctl, util) for t in tick if len(ev[(t, "blind")])}
    tot_bad = sum(s[0].sum() for s in series.values())
    tot_exc = sum(s[1].sum() for s in series.values())
    n = len(series)
    windows_per_year = sum(len(s[0]) for s in series.values()) / n / years
    out = {"mechanism": "c_priced_premium", "util": util,
           "flat_bad_debt_bps_yr": 1e4 * tot_bad / (n * years),
           "excess_exposure_pct_of_debt_per_window": 100 * tot_exc / sum(len(s[0]) for s
                                                                         in series.values()),
           "windows_per_year": windows_per_year}
    if tot_bad == 0:
        out.update({"breakeven_pi_bps_per_window": 0.0, "note": "no bad debt in sample"})
        return out
    if tot_exc == 0:
        out.update({"breakeven_pi_bps_per_window": float("inf"),
                    "note": "bad debt but zero exposure above the cap: premium cannot fund it"})
        return out
    pi_be = tot_bad / tot_exc
    out["breakeven_pi_bps_per_window"] = 1e4 * pi_be
    # sparse month blocks per asset for the bootstrap (zero events never matter)
    blocks = {}
    for t, (bad, exc, months) in series.items():
        keep = (bad > 0) | (exc > 0)
        mlist = sorted(set(months))
        per_m = {m: [] for m in mlist}
        for b, e, m in zip(bad[keep], exc[keep], months[keep], strict=True):
            per_m[m].append((b, e))
        blocks[t] = (mlist, per_m)
    for mult in multiples:
        pi = pi_be * mult
        # in-sample (single chronological path per asset)
        resid = np.concatenate([reserve_residual(s[0], s[1], pi) for s in series.values()])
        exhausted_events = float((resid > 0).sum())
        # bootstrap paths of PATH_YEARS years of random months
        any_exh, lend_loss = [], []
        for mlist, per_m in blocks.values():
            for _ in range(N_PATHS):
                picks = rng.integers(0, len(mlist), PATH_YEARS * 12)
                r = 0.0
                loss = 0.0
                for k in picks:
                    for b, e in per_m[mlist[k]]:
                        r += pi * e
                        take = min(r, b)
                        r -= take
                        loss += b - take
                any_exh.append(loss > 0)
                lend_loss.append(loss)
        out[f"pi_x{mult}_bps_per_window"] = 1e4 * pi
        out[f"pi_x{mult}_insample_exhausted_events"] = exhausted_events
        out[f"pi_x{mult}_p_exhausted_{PATH_YEARS}y"] = float(np.mean(any_exh))
        out[f"pi_x{mult}_lender_loss_bps_yr"] = 1e4 * float(np.mean(lend_loss)) / PATH_YEARS
        out[f"pi_x{mult}_borrower_cost_bps_of_excess_per_year"] = 1e4 * pi * windows_per_year
    ok = [m for m in multiples if out[f"pi_x{m}_p_exhausted_{PATH_YEARS}y"] <= 0.05]
    out["pi_for_p_exhausted_le_5pct_bps_per_window"] = (1e4 * pi_be * ok[0]) if ok else None
    out["multiple_for_p_le_5pct"] = ok[0] if ok else None
    return out


def to_frame(rows: list[dict]) -> pd.DataFrame:
    return pd.DataFrame(rows)


def mech_c_all_debt(ev, tick, ctl, years, util, multiples=(1, 2, 3, 5), seed=SEED):
    """Variant (c2): the premium accrues on ALL outstanding debt (no cap involved), flat per
    window, into the gap reserve; month-block bootstrap of PATH_YEARS-year paths, reserve starts
    empty. Monthly netting (accrual and losses inside a month are netted) is an approximation.
    Reports the premium for P(reserve exhausted) <= 5 % and the seed reserve needed at
    break-even premium (95th percentile of the worst cumulative shortfall)."""
    rng = np.random.default_rng(seed + 37)
    p = cs.Params(util_weights=util, enforcement=0.0)
    bad_m, win_m = [], []
    for t in tick:
        g = ev[(t, "blind")]
        if not len(g):
            continue
        r = cs.run_events(g.gap_bps.to_numpy(float), None, ctl, p)
        key = g.d2.dt.to_period("M").astype(str).to_numpy()
        s = pd.DataFrame({"m": key, "b": r["loss_ratio"], "w": 1.0}).groupby("m").sum()
        bad_m.append(s.b.to_numpy())
        win_m.append(s.w.to_numpy())
    tot_bad = sum(b.sum() for b in bad_m)
    tot_win = sum(w.sum() for w in win_m)
    n = len(bad_m)
    out = {"mechanism": "c2_premium_on_all_debt", "util": util,
           "flat_bad_debt_bps_yr": 1e4 * tot_bad / (n * years),
           "breakeven_bps_per_window_on_debt": 1e4 * tot_bad / tot_win,
           "breakeven_bps_per_year_on_debt": 1e4 * tot_bad / (n * years)}
    if tot_bad == 0:
        return out
    pi_be = tot_bad / tot_win
    steps = PATH_YEARS * 12
    for mult in multiples:
        exh, shortfall = [], []
        for b, w in zip(bad_m, win_m, strict=True):
            idx = rng.integers(0, len(b), (N_PATHS, steps))
            d = np.cumsum(b[idx] - mult * pi_be * w[idx], axis=1)  # cumulative net loss
            shortfall.append(np.maximum(d.max(axis=1), 0.0))
            # residual loss with a floored reserve starting at 0
            r = np.zeros(N_PATHS)
            lost = np.zeros(N_PATHS)
            for k in range(steps):
                r = r + mult * pi_be * w[idx[:, k]]
                take = np.minimum(r, b[idx[:, k]])
                r -= take
                lost += b[idx[:, k]] - take
            exh.append(lost > 0)
        sf = np.concatenate(shortfall)
        out[f"x{mult}_premium_bps_per_year_on_debt"] = 1e4 * mult * tot_bad / (n * years)
        out[f"x{mult}_p_exhausted_{PATH_YEARS}y"] = float(np.mean(np.concatenate(exh)))
        out[f"x{mult}_seed_reserve_p95_bps_of_debt"] = 1e4 * float(np.quantile(sf, 0.95))
        out[f"x{mult}_seed_reserve_p99_bps_of_debt"] = 1e4 * float(np.quantile(sf, 0.99))
    return out
