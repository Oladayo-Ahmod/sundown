"""Liquidation-design simulator with convex, depth-driven slippage (M2.2).

Model (per event = one closed window; one isolated market per asset):
  * Pool: Uniswap-v3-in-range constant-product approximation. Selling collateral worth N USD
    into a pool whose quote-side reserve is y USD has average slippage N / (N + y). y =
    concentration * TVL / 2, TVL from a SINGLE secondary-source snapshot (DexScreener, see
    pool_depth_snapshot.json). concentration = 1 is the pessimistic anchor (CP on TVL).
  * Participation (rational liquidators): a liquidation round executes only as much seized
    notional as keeps average slippage <= bonus - gas, i.e. N <= y * (b - g) / (1 - b + g).
    Bonus <= gas => nobody liquidates. Un-executed demand is DELAYED to the next round.
  * Timeline: rounds every 30 min from the reopen (t = 0 .. 360 min); the pool refills fully
    between rounds (ASSUMPTION). The price drifts from the gap price S along the same day's
    regular-hours return: P(t) = S * exp(oc * t / 390) (proxy; real intraday paths differ).
  * Positions: buckets on a 20-point utilisation grid per tier, processed highest-LTV first.
    A liquidation repays rho and seizes rho*(1+b) of collateral value (capped at available
    collateral and at the round capacity). Close factor limits rho per call to CF * debt.
  * Bad debt: after the last round, sum of max(0, debt - collateral value at the last price).
  * Designs: flat bonus (CF 50/100 %), Dutch ramp bmin->bmax over T minutes with a
    deep-insolvency override (positions that cannot cover debt*(1+bmax) get bmax at once), and a
    flat bonus with a protocol cap of phi * y notional per round.
NOT modelled: MEV/competition beyond rationality, partial pool refill, CEX hedging by liquidators,
intraday volatility inside the drift path, liquidations during the blind window itself.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

import credit_sim as cs

K = cs.K_GRID
UTIL = cs.UTIL
ROUND_STEP = 30  # minutes between liquidation rounds (pool refills fully between rounds)
SESSION_MIN = 390.0
GAS = 0.0005  # ASSUMPTION: 5 bps of repaid amount (gas + keeper margin)
HUGE_DEPTH = 1e18


@dataclass(frozen=True)
class Design:
    name: str
    kind: str  # "flat" | "dutch" | "cap"
    bonus: float = 0.055
    cf: float = 1.0
    bmin: float = 0.01
    bmax: float | None = None  # None => min(10 %, 0.5 * (1/LLTV - 1)) per group
    settle_min: float = 60.0
    phi: float | None = None  # protocol cap as a fraction of pool reserve y per round


DESIGNS = [
    Design("flat 4.4% CF50", "flat", 0.044, 0.5),
    Design("flat 4.4% CF100", "flat", 0.044, 1.0),
    Design("flat 5.5% CF50", "flat", 0.055, 0.5),
    Design("flat 5.5% CF100", "flat", 0.055, 1.0),
    Design("dutch 30min", "dutch", bmax=0.055, settle_min=30),
    Design("dutch 60min", "dutch", bmax=0.055, settle_min=60),
    Design("dutch 120min", "dutch", bmax=0.055, settle_min=120),
    Design("dutch 60min bmax=formula", "dutch", settle_min=60),
    Design("cap 2% of depth", "cap", 0.055, 1.0, phi=0.02),
    Design("cap 5% of depth", "cap", 0.055, 1.0, phi=0.05),
]


def capacity(b: np.ndarray | float, y: float) -> np.ndarray:
    """Max seized notional (USD) per round with average slippage + gas <= bonus."""
    m = np.maximum(np.asarray(b, float) - GAS, 0.0)
    return y * m / (1.0 - np.minimum(m, 0.99))


@dataclass
class Tier:
    lltv: float
    debt_share: float = 1.0
    util: str = "uniform"
    cap: np.ndarray | None = None  # per-event stressed cap (enforced: debt above is repaid)
    p_cure: float = 0.7


def simulate(x_bps: np.ndarray, oc_bps: np.ndarray, tiers: list[Tier], design: Design,
             depth_tvl: float, debt_usd: float, concentration: float = 1.0,
             round_step: int = ROUND_STEP) -> dict:
    n = len(x_bps)
    round_min = np.arange(0, 361, round_step)
    y = HUGE_DEPTH if depth_tvl is None else concentration * depth_tvl / 2.0
    s_gap = np.exp(x_bps / 1e4)
    drift = oc_bps / 1e4
    prices = np.stack([s_gap * np.exp(drift * min(t, SESSION_MIN) / SESSION_MIN)
                       for t in round_min], axis=1)  # (n, R)
    # --- positions (n, P): debt (USD), collateral tokens (USD at pre-gap price), lltv, group
    Ds, Ts, Ls, Bmax = [], [], [], []
    flagged = np.zeros(n)
    base_total = np.zeros(n)
    for tr in tiers:
        w = cs.weights(tr.util)
        d0 = np.broadcast_to(UTIL[None, :] * tr.lltv, (n, K)).copy()
        if tr.cap is not None:
            d_eff = np.minimum(d0, tr.cap[:, None])
            flagged += tr.debt_share * (w[None, :] * (d0 > tr.cap[:, None] + 1e-12)).sum(1)
        else:
            d_eff = d0
        # tier debt scaled so that sum over tier = debt_usd * share (pre-enforcement)
        norm = (w[None, :] * d0).sum(1, keepdims=True)
        coll = debt_usd * tr.debt_share * w[None, :] / norm  # collateral USD per bucket
        Ds.append(coll * d_eff)
        Ts.append(coll.copy())
        Ls.append(np.full((n, K), tr.lltv))
        bm = design.bmax if design.bmax is not None else min(0.10, 0.5 * (1 / tr.lltv - 1))
        Bmax.append(np.full((n, K), bm))
        base_total += (coll * d0).sum(1)
    D, T, L, BM = (np.concatenate(a, axis=1) for a in (Ds, Ts, Ls, Bmax))
    debt_after = D.sum(1)
    order = np.argsort(-(D / np.maximum(T, 1e-12)), axis=1, kind="stable")
    D, T, L, BM = (np.take_along_axis(a, order, 1) for a in (D, T, L, BM))
    P = D.shape[1]
    sold_rounds = 0.0
    bonus_paid = np.zeros(n)
    for r, t in enumerate(round_min):
        px = prices[:, r]
        sold = np.zeros(n)
        for j in range(P):
            Dj, Tj, Lj, bmj = D[:, j], T[:, j], L[:, j], BM[:, j]
            coll_val = Tj * px
            with np.errstate(divide="ignore", invalid="ignore"):
                ltv = np.where(coll_val > 1e-12, Dj / coll_val, np.where(Dj > 1e-12, np.inf, 0.0))
            liq = (Dj > 1e-12) & (ltv >= Lj)
            if design.kind == "dutch":
                ramp = design.bmin + (bmj - design.bmin) * min(1.0, t / design.settle_min)
                deep = ltv >= 1.0 / (1.0 + bmj)
                b = np.where(deep, bmj, ramp)
            else:
                b = np.full(n, design.bonus)
            avail = np.maximum(capacity(b, y) - sold, 0.0)
            if design.phi is not None:
                avail = np.minimum(avail, np.maximum(design.phi * y - sold, 0.0))
            want = np.minimum(design.cf * Dj * (1.0 + b), coll_val)
            seize = np.where(liq, np.minimum(want, avail), 0.0)
            repay = seize / (1.0 + b)
            D[:, j] = Dj - repay
            T[:, j] = Tj - seize / px
            sold += seize
            bonus_paid += seize * b / (1.0 + b)
        sold_rounds = sold_rounds + sold
    px_last = prices[:, -1]
    # Terminal settlement: whatever is still liquidatable is liquidated eventually (unlimited
    # depth, closing price) with the design's final bonus; otherwise delay would look free.
    coll_val = T * px_last[:, None]
    with np.errstate(divide="ignore", invalid="ignore"):
        ltv = np.where(coll_val > 1e-12, D / coll_val, np.where(D > 1e-12, np.inf, 0.0))
    b_final = BM if design.kind == "dutch" else design.bonus
    liq = (D > 1e-12) & (ltv >= L)
    bad = np.where(liq, np.maximum(0.0, D - coll_val / (1.0 + b_final)),
                   np.maximum(0.0, D - coll_val)).sum(1)
    with np.errstate(invalid="ignore", divide="ignore"):
        loss_ratio = np.where(debt_after > 0, bad / debt_after, 0.0)
    return {"bad": bad, "debt": debt_after, "loss_ratio": loss_ratio, "flagged": flagged,
            "base_debt": base_total, "sold": sold_rounds,
            "bonus_paid": bonus_paid}
