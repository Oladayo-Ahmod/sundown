"""Candidate on-chain gap-VaR estimators (float reference + integer/WAD reference).

All estimators work on gap *losses* L = -x in log bps (x = 1e4 * ln(open/prev close)) and
forecast the q-quantile of L for the next window using only earlier windows.

Units note: VaR is kept in log bps and the contracts treat it directly as a loss fraction.
Since 1 - exp(-v) < v this is conservative (it overstates simple loss), and it avoids an
on-chain exp().

(a) EWMA of squared gaps, per class, normalised: sigma2 = num/den with
    num' = lam*num + x^2, den' = lam*den + 1  (two accumulators, no warm-up bias).
    VaR = m * z_q * sqrt(sigma2)  (zero-mean assumption).
(b) Rolling historical simulation over the last N gaps of the class: the ceil(q*n)-th
    smallest loss (conservative order statistic; returns the sample max when n*(1-q) < 1).
(c) Blend of (a) and (b) before the multiplier: w*EWMA + (1-w)*HS.
(d) Pooled-scaled EWMA: one EWMA over all blind windows of the asset, each squared gap
    divided by a fixed class scale k_c^2, forecast scaled back by k_c. Added because the
    Short/Long classes have far too few observations for per-class estimation.
The multiplier m is calibrated separately (backtest.calibrate_multiplier).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from scipy.stats import norm

K_MIN = 8  # minimum prior observations before a forecast is issued

WAD = 10**18


@dataclass(frozen=True)
class Candidate:
    kind: str  # "ewma" | "hs" | "blend" | "pooled"
    lam: float | None = None
    n: int | None = None
    w: float = 0.5

    @property
    def name(self) -> str:
        if self.kind == "ewma":
            return f"ewma(l={self.lam})"
        if self.kind == "hs":
            return f"hs(N={self.n})"
        if self.kind == "blend":
            return f"blend(l={self.lam},N={self.n},w={self.w})"
        return f"pooled(l={self.lam})"


def grid() -> list[Candidate]:
    lams = [0.80, 0.85, 0.90, 0.94, 0.97, 0.99]
    ns = [126, 250, 500]
    out = [Candidate("ewma", lam=lam) for lam in lams]
    out += [Candidate("hs", n=n) for n in ns]
    out += [Candidate("blend", lam=lam, n=n) for lam in (0.94, 0.97) for n in ns]
    out += [Candidate("pooled", lam=lam) for lam in lams]
    return out


def z(q: float) -> float:
    return float(norm.ppf(q))


def ewma_sigma2(sq: np.ndarray, lam: float) -> np.ndarray:
    """sigma2[t] from sq[:t] (normalised EWMA); NaN while fewer than K_MIN priors."""
    out = np.full(len(sq), np.nan)
    num = den = 0.0
    for t in range(len(sq)):
        if t >= K_MIN:
            out[t] = num / den
        num = lam * num + sq[t]
        den = lam * den + 1.0
    return out


def hs_quantile(loss: np.ndarray, n: int, q: float) -> np.ndarray:
    out = np.full(len(loss), np.nan)
    for t in range(K_MIN, len(loss)):
        past = loss[max(0, t - n):t]
        k = math.ceil(q * len(past) - 1e-12)  # 1-based rank, guards float fuzz
        out[t] = np.partition(past, k - 1)[k - 1]
    return np.maximum(out, 0.0)


def raw_forecast(cls: np.ndarray, loss: np.ndarray, cand: Candidate, q: float,
                 class_scale: dict[str, float] | None = None) -> np.ndarray:
    """Un-multiplied VaR forecast aligned to one asset's chronologically sorted blind windows."""
    out = np.full(len(loss), np.nan)
    if cand.kind == "pooled":
        assert class_scale is not None
        k = np.array([class_scale[c] for c in cls])
        sig2 = ewma_sigma2((loss / k) ** 2, cand.lam)
        return k * z(q) * np.sqrt(sig2)
    for c in np.unique(cls):
        idx = np.where(cls == c)[0]
        li = loss[idx]
        if cand.kind == "ewma":
            f = z(q) * np.sqrt(ewma_sigma2(li**2, cand.lam))
        elif cand.kind == "hs":
            f = hs_quantile(li, cand.n, q)
        else:
            f = (cand.w * z(q) * np.sqrt(ewma_sigma2(li**2, cand.lam))
                 + (1 - cand.w) * hs_quantile(li, cand.n, q))
        out[idx] = f
    return out


# ---------------------------------------------------------------- integer reference

def isqrt(n: int) -> int:
    return math.isqrt(n)


def ewma_update_int(num: int, den: int, x_bps: int, lam_wad: int) -> tuple[int, int]:
    """One accumulator step. Rounds down: slightly lowers variance, offset by ceil in VaR."""
    return (lam_wad * num) // WAD + x_bps * x_bps * WAD, (lam_wad * den) // WAD + WAD


def ewma_var_int(num: int, den: int, z_wad: int, m_wad: int) -> int:
    """VaR in bps * WAD, rounded UP (against the user, for the protocol)."""
    var_wad = (num * WAD + den - 1) // den  # bps^2 * WAD
    sigma = isqrt(var_wad * WAD)
    sigma += 1 if sigma * sigma < var_wad * WAD else 0  # ceil sqrt
    v = (z_wad * sigma + WAD - 1) // WAD
    return (m_wad * v + WAD - 1) // WAD


def hs_quantile_int(losses_bps: list[int], q_bps: int) -> int:
    n = len(losses_bps)
    k = (q_bps * n + 9999) // 10000
    return max(sorted(losses_bps)[k - 1], 0)
