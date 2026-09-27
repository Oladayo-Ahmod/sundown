"""Credit simulation: flat-LLTV controls (real parameters in the wild, N5) versus the
session-aware stress rule, replayed over historical gaps.

Model (per event = one closed window; one isolated single-collateral market per asset):
  * Borrowers sit at utilisation u_k of the control's max LTV: debt d_k = u_k * LLTV per unit
    of feed-visible collateral value (grid of K utilisations, weighted).
  * Treatment (stress rule): max borrow LTV cap = min(LLTV, 1 - VaR_q - oracleBuffer -
    safetyBuffer) [prompt rule; VaR in log bps is used as a loss fraction, conservative].
    Debt above the cap is forced down by a fraction `enforcement` e in [0,1] before the window:
    d' = d - e * max(0, d - cap). e=1 is the best case for the treatment (hard stress-HF
    enforcement, an upper bound on benefit); e=0 is "cap applies to new borrows only and
    pre-existing positions are untouched" (no benefit by construction). The forced repayment is
    reported as a cost (`forced_delev_share`), together with capacity given up.
  * After the gap: collateral value S = exp(x) / (1 + delta) where delta is the adverse
    oracle staleness (feed overvalued collateral at window start). A position is liquidated
    if d / S >= LLTV (full close factor, instantly at the post-gap price, no slippage).
    Lender bad debt = max(0, d - S / (1 + bonus)).
  * Same bonus in both arms (the guard is the only difference). Morpho bonus follows the Morpho
    Blue LIF formula; Aave rows use the 5.5 % max bonus (secondary source).
NOT modelled: liquidation slippage / thin liquidity (see bonus sensitivity as a proxy), price
moves between reopen and liquidation, borrower behaviour changes, interest, issuer actions,
earnings foresight, and path risk inside regular hours (except the regular-hours scenario).
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from config import (
    AAVE_LLTVS,
    AAVE_MAX_BONUS,
    COUNTERFACTUAL_LLTVS,
    LOOKAHEAD_HOURS,
    MORPHO_LLTVS,
    ORACLE_DEVIATION_BPS,
    SAFETY_BUFFER_BPS,
    morpho_bonus,
)

K_GRID = 20
UTIL = np.arange(1, K_GRID + 1) / K_GRID


@dataclass(frozen=True)
class Control:
    name: str
    lltv: float
    bonus: float
    kind: str = "in_the_wild"  # "in_the_wild" (N5) | "counterfactual" (not deployed anywhere)


def controls(counterfactual: bool = True) -> list[Control]:
    out = [Control(f"morpho_{lt * 100:g}", lt, morpho_bonus(lt)) for lt in MORPHO_LLTVS]
    out += [Control(f"aave_{lt * 100:g}", lt, AAVE_MAX_BONUS) for lt in AAVE_LLTVS]
    if counterfactual:
        # Higher LLTVs than any market observed; tests the rule where it actually binds.
        out += [Control(f"cf_{lt * 100:g}", lt, morpho_bonus(lt), "counterfactual")
                for lt in COUNTERFACTUAL_LLTVS]
    return out


@dataclass(frozen=True)
class Params:
    enforcement: float = 1.0
    util_weights: str = "uniform"  # "uniform" | "high" (mass near max LTV)
    noise_bps: float = 0.0  # adverse feed staleness applied to every event
    oracle_buffer_bps: float = float(ORACLE_DEVIATION_BPS)
    safety_buffer_bps: float = float(SAFETY_BUFFER_BPS)
    bonus_aware_cap: bool = False  # cap = (1 - VaR - buffers) / (1 + bonus)
    bonus_override: float | None = None
    lookahead_h: float = float(LOOKAHEAD_HOURS)


def weights(kind: str) -> np.ndarray:
    w = UTIL**4 if kind == "high" else np.ones_like(UTIL)
    return w / w.sum()


def stress_cap(var_bps: np.ndarray, lltv: float, bonus: float, p: Params) -> np.ndarray:
    cap = 1.0 - var_bps / 1e4 - p.oracle_buffer_bps / 1e4 - p.safety_buffer_bps / 1e4
    if p.bonus_aware_cap:
        cap = cap / (1.0 + bonus)
    return np.clip(cap, 0.0, lltv)


def run_events(x_bps: np.ndarray, var_bps: np.ndarray | None, ctl: Control, p: Params
               ) -> dict[str, np.ndarray]:
    """Per-event arrays. var_bps None => control arm (no tightening)."""
    bonus = ctl.bonus if p.bonus_override is None else p.bonus_override
    w = weights(p.util_weights)[None, :]
    d0 = np.broadcast_to(UTIL[None, :] * ctl.lltv, (len(x_bps), K_GRID))
    if var_bps is None:
        cap = np.full(len(x_bps), ctl.lltv)
        d = d0
    else:
        cap = stress_cap(var_bps, ctl.lltv, bonus, p)
        d = d0 - p.enforcement * np.maximum(0.0, d0 - cap[:, None])
    s = (np.exp(x_bps / 1e4) / (1.0 + p.noise_bps / 1e4))[:, None]
    liq = (d / s >= ctl.lltv) & (d > 0)
    bad = np.where(liq, np.maximum(0.0, d - s / (1.0 + bonus)), 0.0)
    debt = (w * d).sum(1)
    base_debt = (w * d0).sum(1)
    liq_debt = (w * np.where(liq, d, 0.0)).sum(1)
    bad_w = (w * bad).sum(1)
    with np.errstate(invalid="ignore", divide="ignore"):
        loss_ratio = np.where(debt > 0, bad_w / debt, 0.0)
    return {"debt": debt, "base_debt": base_debt, "liq_debt": liq_debt, "bad": bad_w,
            "loss_ratio": loss_ratio, "cap": cap,
            "cap_reduction": (ctl.lltv - cap) / ctl.lltv,
            "forced_delev": (base_debt - debt) / base_debt}


def summarize(res: dict[str, np.ndarray], hours: np.ndarray | None, p: Params,
              years: float, total_hours: float) -> dict[str, float]:
    n = len(res["debt"])
    if n == 0:
        return {}
    out = {
        "events": n,
        "bad_debt_pct_of_outstanding": 100 * res["bad"].sum() / res["debt"].sum(),
        "liquidated_pct_of_outstanding": 100 * res["liq_debt"].sum() / res["debt"].sum(),
        "events_with_bad_debt_pct": 100 * float((res["bad"] > 0).mean()),
        "lender_loss_p99_pct": 100 * float(np.quantile(res["loss_ratio"], 0.99)),
        "lender_loss_p999_pct": 100 * float(np.quantile(res["loss_ratio"], 0.999)),
        "lender_loss_max_pct": 100 * float(res["loss_ratio"].max()),
        "annualised_bad_debt_bps": 1e4 * float(res["loss_ratio"].sum()) / years,
        "cap_reduction_at_window_pct": 100 * float(res["cap_reduction"].mean()),
        "forced_delev_share_pct": 100 * float(res["forced_delev"].mean()),
    }
    if hours is not None:
        out["capacity_given_up_time_avg_pct"] = 100 * float(
            ((hours + p.lookahead_h) * res["cap_reduction"]).sum() / total_hours)
    return out
