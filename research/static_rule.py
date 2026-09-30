"""Simulation of the SHIPPED static stress rule (GUARD_DESIGN section 11, D18-D29), boosted tier.

Rule (per asset and window class c): from H = 6 h before a blind window starts until it ends, a
boosted account's borrow cap is min(tierLLTV, 1 - gapVaR[c] - 0.5 % - 1 %), with gapVaR[c] the
STATIC full-sample q99.5 downside gap (`static_gapvar.py`). Accounts above the stress fraction
get a 3 h cure window; afterwards anyone can deleverage them (a guard-authorised market
liquidation) to target = cap - 0.5 %, charging a fee f in [2 %, 5.5 %]. Standard-tier accounts are
never touched (so this module simulates the boosted-tier book only).

Reuses the M2.2 liquidation model: convex depth-based slippage, rational-liquidator participation
(execute only while average slippage + gas <= bonus or fee), 30-minute rounds with a full pool
refill between rounds (ASSUMPTION), the same-day open-to-close return as the delay drift, terminal
settlement of anything still liquidatable. Differences, stated: flat 4 % bonus (the market default,
D15) and a close factor of 50 % rising to 100 % below health 0.95 (market rule), instead of the
M2.2 grid; depth can be the exact Uniswap v3 curve from `results/exit_liquidity.json` (Session A,
direct reads) or the M2.2 constant-product-on-TVL model.

Borrower behaviours: "naive" (never adjusts, sits at u x tierLLTV) and "rational" (repays to the
cap before each horizon at no fee; assumes the funds are at hand, which is the optimistic case).
Time ordering inside a window event: pre-window deleveraging at the pre-gap price, then the gap.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

import numpy as np

import credit_sim as cs
import liquidation as lq
from config import RESULTS_DIR

K = cs.K_GRID
UTIL = cs.UTIL
GAS = lq.GAS
BONUS = 0.04  # market default flat bonus (D15)
CF_NORMAL, CF_CRITICAL, CRITICAL_HEALTH = 0.5, 1.0, 0.95
ORACLE_BUFFER = 0.005
SAFETY_BUFFER = 0.01
MARGIN = 0.005  # deleverage target = cap - margin (GUARD_DESIGN section 3)
HORIZON_H, CURE_H = 6, 3
PRE_ROUNDS = 6  # 30-minute rounds inside the 3 h deleverage zone
FEE_FLOOR, FEE_CAP = 0.02, 0.055
ROUND_STEP = lq.ROUND_STEP
SESSION_MIN = lq.SESSION_MIN
COLLATERAL_CAP_ALPHA = 0.5  # DISCOVERY section g: cap = 0.5 x max notional at 3 % slippage


# ------------------------------------------------------------------------- depth models

class DepthV3:
    """Capacity from Session A's exact v3 reads: aggregate max notional at 1/3/5 % average slippage.

    capacity(b) = notional that can be sold while average slippage <= b - gas, interpolated
    linearly in slippage between (0, 0), (1 %, N1), (3 %, N3), (5 %, N5) and saturating at N5
    (no depth beyond the scanned ticks is assumed: conservative)."""

    name = "v3_exact"

    def __init__(self, n1: float, n3: float, n5: float):
        self.s = np.array([0.0, 0.01, 0.03, 0.05])
        self.n = np.array([0.0, n1, n3, n5])
        self.n3 = n3

    def capacity(self, b):
        m = np.maximum(np.asarray(b, float) - GAS, 0.0)
        return np.interp(m, self.s, self.n)  # np.interp clamps at the last point

    def slippage_for(self, notional: float) -> float:
        """Average slippage needed to sell `notional` (inf beyond the modelled depth)."""
        if notional > self.n[-1]:
            return float("inf")
        return float(np.interp(notional, self.n, self.s))


class DepthCP:
    """M2.2 model: constant product on half the TVL (pessimistic anchor), concentration c."""

    name = "cp_tvl"

    def __init__(self, tvl: float, concentration: float = 1.0):
        self.y = concentration * tvl / 2.0
        self.n3 = self.y * 0.03 / 0.97

    def capacity(self, b):
        return lq.capacity(b, self.y)

    def slippage_for(self, notional: float) -> float:
        return notional / (notional + self.y)


class DepthInfinite:
    name = "infinite"
    n3 = float("inf")

    def capacity(self, b):
        return np.full(np.shape(b), 1e18)

    def slippage_for(self, notional: float) -> float:
        return 0.0


def load_v3_depth() -> dict[str, DepthV3]:
    d = json.loads((RESULTS_DIR / "exit_liquidity.json").read_text())["assets"]
    out = {}
    for t, a in d.items():
        m = a["aggregate_max_notional_usd"]
        out[t] = DepthV3(m["1pct"], m["3pct"], m["5pct"])
    return out


# ------------------------------------------------------------------------- rule helpers

def stress_fraction(gap_var_bps: np.ndarray) -> np.ndarray:
    return np.maximum(0.0, 1.0 - gap_var_bps / 1e4 - ORACLE_BUFFER - SAFETY_BUFFER)


def required_repay(d, t_val, target, fee):
    """Debt R to repay (collateral seized R(1+fee)) so that (D-R) <= target*(T-R(1+fee))."""
    denom = 1.0 - target * (1.0 + fee)
    return np.clip((d - target * t_val) / np.maximum(denom, 1e-9), 0.0, d)


@dataclass
class Result:
    loss_ratio: np.ndarray  # lender loss per window / outstanding debt after pre-phase
    debt_pre: np.ndarray
    debt_post: np.ndarray
    bad: np.ndarray
    flagged_share: np.ndarray  # borrower-weight share above the stress fraction at horizon
    executed_share: np.ndarray  # borrower-weight share actually trimmed pre-window
    trimmed_debt: np.ndarray  # R executed (USD)
    fee_paid: np.ndarray  # USD paid by borrowers as deleverage fees
    flagged_debt: np.ndarray  # USD of debt above target of flagged accounts (before trimming)
    unexecuted_debt: np.ndarray  # USD of excess still above the trigger after the pre-phase
    pre_notional: np.ndarray  # USD of collateral sold pre-window
    peak_round_notional: np.ndarray  # largest single-round notional demanded pre-window


def simulate_book(x_bps, oc_bps, gap_var_bps, tier_lltv, depth, collateral_usd, *,
                  util="uniform", rule=True, behaviour="naive", fee=FEE_FLOOR, bonus=BONUS,
                  lltv_override=None, pre_depth=None, population=None,
                  nonworsening=False) -> Result:
    """One boosted-tier (or flat) book per window event.

    rule=False: flat market at `tier_lltv` (no stress cap, no deleverage). lltv_override lets the
    caller run a flat market at a different LLTV (e.g. the weekend cap level)."""
    n = len(x_bps)
    L = tier_lltv if lltv_override is None else lltv_override
    u_grid, w = population if population is not None else (UTIL, cs.weights(util))
    k = len(u_grid)
    coll = collateral_usd * w[None, :] * np.ones((n, 1))  # collateral USD per bucket, price 1
    D = coll * (u_grid[None, :] * L)
    T = coll.copy()
    debt_pre = D.sum(1)
    sf = stress_fraction(gap_var_bps)  # (n,)
    flagged_share = np.zeros(n)
    executed_share = np.zeros(n)
    trimmed = np.zeros(n)
    fee_paid = np.zeros(n)
    flagged_debt = np.zeros(n)
    pre_notional = np.zeros(n)
    peak_round = np.zeros(n)
    pre_depth = pre_depth or depth

    if rule:
        capfrac = np.minimum(L, sf)
        if behaviour == "rational":  # repay to the cap before the horizon, no fee
            D = np.minimum(D, capfrac[:, None] * T)
        trig = sf[:, None] * T
        flagged0 = D > trig + 1e-9
        flagged_share = (w[None, :] * flagged0).sum(1)
        target = np.maximum(capfrac - MARGIN, 0.0)[:, None] * np.ones((1, k))
        r_full = required_repay(D, T, target, fee)
        flagged_debt = (np.where(flagged0, r_full, 0.0)).sum(1)
        order = np.argsort(-(D / np.maximum(T, 1e-12)), axis=1, kind="stable")
        Ds, Ts = np.take_along_axis(D, order, 1).copy(), np.take_along_axis(T, order, 1).copy()
        tg = np.take_along_axis(target, order, 1)
        trig_s = np.take_along_axis(trig, order, 1)
        fl_s = np.take_along_axis(flagged0, order, 1)
        trimmed_any = np.zeros_like(Ds, dtype=bool)
        cap_round = float(pre_depth.capacity(np.array([fee]))[0])
        for _ in range(PRE_ROUNDS):
            sold = np.zeros(n)
            for j in range(Ds.shape[1]):
                dj, tj = Ds[:, j], Ts[:, j]
                elig = fl_s[:, j] & (dj > trig_s[:, j] + 1e-9) & (tj > 1e-12)
                req = required_repay(dj, tj, tg[:, j], fee)
                seize_want = np.minimum(req * (1.0 + fee), tj)
                avail = np.maximum(cap_round - sold, 0.0)
                seize = np.where(elig, np.minimum(seize_want, avail), 0.0)
                repay = seize / (1.0 + fee)
                Ds[:, j] = dj - repay
                Ts[:, j] = tj - seize
                sold += seize
                trimmed += repay
                fee_paid += seize - repay
                pre_notional += seize
                trimmed_any[:, j] |= seize > 0
            peak_round = np.maximum(peak_round, sold)
        # borrower-weight share trimmed (weights follow the sorted order)
        ws = np.take_along_axis(np.broadcast_to(w[None, :], (n, k)), order, 1)
        executed_share = (ws * trimmed_any).sum(1)
        order = np.argsort(-(Ds / np.maximum(Ts, 1e-12)), axis=1, kind="stable")
        D, T = np.take_along_axis(Ds, order, 1).copy(), np.take_along_axis(Ts, order, 1).copy()
        L_arr = np.full_like(D, L)
    else:
        order = np.argsort(-(D / np.maximum(T, 1e-12)), axis=1, kind="stable")
        D, T = np.take_along_axis(D, order, 1), np.take_along_axis(T, order, 1)
        L_arr = np.full_like(D, L)

    unexec = np.where((D > sf[:, None] * T + 1e-9) & rule, D - sf[:, None] * T, 0.0).sum(1)
    debt_post = D.sum(1)

    # ---- gap phase (M2.2 rounds, flat bonus, market close-factor rule)
    round_min = np.arange(0, 361, ROUND_STEP)
    s_gap = np.exp(x_bps / 1e4)
    drift = oc_bps / 1e4
    prices = np.stack([s_gap * np.exp(drift * min(t, SESSION_MIN) / SESSION_MIN)
                       for t in round_min], axis=1)
    P = D.shape[1]
    for r in range(len(round_min)):
        px = prices[:, r]
        sold = np.zeros(n)
        cap_r = float(depth.capacity(np.array([bonus]))[0])
        for j in range(P):
            Dj, Tj = D[:, j], T[:, j]
            coll_val = Tj * px
            with np.errstate(divide="ignore", invalid="ignore"):
                ltv = np.where(coll_val > 1e-12, Dj / coll_val, np.where(Dj > 1e-12, np.inf, 0.0))
            liq = (Dj > 1e-12) & (ltv >= L_arr[:, j])
            cf = np.where(L_arr[:, j] / np.maximum(ltv, 1e-12) < CRITICAL_HEALTH, CF_CRITICAL,
                          CF_NORMAL)
            avail = np.maximum(cap_r - sold, 0.0)
            b_eff = _bonus_eff(bonus, coll_val, Dj, nonworsening)
            want = np.minimum(cf * Dj * (1.0 + b_eff), coll_val)
            seize = np.where(liq, np.minimum(want, avail), 0.0)
            repay = seize / (1.0 + b_eff)
            D[:, j] = Dj - repay
            T[:, j] = Tj - seize / px
            sold += seize
    px_last = prices[:, -1]
    coll_val = T * px_last[:, None]
    with np.errstate(divide="ignore", invalid="ignore"):
        ltv = np.where(coll_val > 1e-12, D / coll_val, np.where(D > 1e-12, np.inf, 0.0))
    liq = (D > 1e-12) & (ltv >= L_arr)
    b_fin = _bonus_eff(bonus, coll_val, D, nonworsening)
    bad = np.where(liq, np.maximum(0.0, D - coll_val / (1.0 + b_fin)),
                   np.maximum(0.0, D - coll_val)).sum(1)
    with np.errstate(invalid="ignore", divide="ignore"):
        lr = np.where(debt_post > 0, bad / debt_post, 0.0)
    return Result(lr, debt_pre, debt_post, bad, flagged_share, executed_share, trimmed, fee_paid,
                  flagged_debt, unexec, pre_notional, peak_round)


def _bonus_eff(bonus, coll_val, debt, nonworsening):
    """Market rule (SundownMarket._planLiquidation): when collateral still exceeds debt the bonus is
    capped at collateral/debt - 1 so a liquidation never raises the loan-to-value. The M2.2/M2.3
    default (nonworsening=False) charges the full bonus, which overstates losses on accounts that
    are liquidated between 1/(1+b) and 100 % LTV."""
    if not nonworsening:
        return bonus
    with np.errstate(divide="ignore", invalid="ignore"):
        cap = np.where(debt > 1e-12, coll_val / np.maximum(debt, 1e-12) - 1.0, bonus)
    return np.where(coll_val > debt, np.minimum(bonus, cap), bonus)


def collateral_cap_usd(depth) -> float:
    """Demonstration market scale: collateral = 0.5 x notional sellable at 3 % (DISCOVERY g)."""
    return COLLATERAL_CAP_ALPHA * depth.n3
