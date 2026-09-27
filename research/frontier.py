"""Equal-bad-debt frontier with clustered bootstrap CIs.

For each treatment point (stress rule on top of a base LLTV) we report
  (a) the reduction in annualised bad debt versus the flat market at the same LLTV, and
  (b) the LTV gained: base LLTV minus the flat LLTV with the same annualised bad debt, where
      the flat curve is evaluated on a fine grid (70-96 %, 1 pp, Morpho bonus formula) and the
      equivalent LLTV is the highest flat LLTV whose bad debt does not exceed the treatment's
      (linear interpolation inside the bracketing segment; clamped at the grid ends).
Resampling is by cluster: `month` (calendar month) or `date` (window date, i.e. all assets
sharing a window open date move together). Flat curve and treatment are resampled jointly.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

import credit_sim as cs
from config import SEED

FLAT_GRID = np.round(np.arange(0.70, 0.9601, 0.01), 2)
TREAT_POINTS = ["morpho_86", "cf_90", "cf_93", "cf_95"]


def equivalent_lltv(bd_flat: np.ndarray, lltvs: np.ndarray, bd: float) -> float:
    """Highest flat LLTV with bad debt <= bd (interpolated); bd_flat is monotone."""
    idx = int(np.searchsorted(bd_flat, bd, side="right")) - 1
    if idx < 0:
        return float(lltvs[0])
    if idx >= len(lltvs) - 1:
        return float(lltvs[-1])
    frac = (bd - bd_flat[idx]) / (bd_flat[idx + 1] - bd_flat[idx])
    return float(lltvs[idx] + frac * (lltvs[idx + 1] - lltvs[idx]))


def _q(a: np.ndarray) -> tuple[float, float]:
    return float(np.quantile(a[1:], 0.025)), float(np.quantile(a[1:], 0.975))


def _cluster_ids(g: pd.DataFrame, cluster: str, table: dict) -> np.ndarray:
    key = g.d2.dt.to_period("M").astype(str) if cluster == "month" else g.d2.dt.strftime("%Y-%m-%d")
    return np.array([table.setdefault(k, len(table)) for k in key])


def frontier(ev: dict, groups: dict, years: float, cluster: str = "month", n_boot: int = 2000,
             params: cs.Params | None = None):
    """Returns (points table, flat-curve table). Column 0 of the weight matrix is the point
    estimate (all weights 1)."""
    params = params or cs.Params()
    rng = np.random.default_rng(SEED + (23 if cluster == "month" else 29))
    by_name = {c.name: c for c in cs.controls()}
    flat_ctls = [cs.Control(f"flat_{lt:g}", float(lt), cs.morpho_bonus(float(lt)))
                 for lt in FLAT_GRID]
    rows, curve = [], []
    for gname in ("DEPLOY4", "UNIVERSE12"):
        tick = groups[gname]
        table: dict = {}
        data = []
        for t in tick:
            g = ev[(t, "blind")]
            if len(g):
                data.append((g.gap_bps.to_numpy(float), g["var"].to_numpy(float),
                             g.hours.to_numpy(float), _cluster_ids(g, cluster, table)))
        n_c = len(table)
        w = np.vstack([np.ones(n_c), rng.multinomial(n_c, np.full(n_c, 1 / n_c), size=n_boot)
                       ]).astype(float)
        n_assets = len(tick)

        def per_cluster(ctl, treat, data=data, n_c=n_c):
            lr, capc = np.zeros(n_c), np.zeros(n_c)
            for x, var, hours, cid in data:
                r = cs.run_events(x, var if treat else None, ctl, params)
                lr += np.bincount(cid, weights=r["loss_ratio"], minlength=n_c)
                capc += np.bincount(cid, weights=(hours + params.lookahead_h)
                                    * r["cap_reduction"], minlength=n_c)
            return lr, capc

        def ann(lr, w=w, n_assets=n_assets):
            return 1e4 * (w @ lr) / (n_assets * years)

        flat_bd = np.stack([ann(per_cluster(c, False)[0]) for c in flat_ctls], axis=1)
        flat_bd = np.maximum.accumulate(flat_bd, axis=1)  # enforce monotone in LLTV
        for j, lt in enumerate(FLAT_GRID):
            lo, hi = _q(flat_bd[:, j])
            curve.append({"group": gname, "cluster": cluster, "lltv_pct": lt * 100,
                          "annualised_bad_debt_bps": flat_bd[0, j], "ci_lo": lo, "ci_hi": hi})
        for name in TREAT_POINTS:
            ctl = by_name[name]
            lr_c, _ = per_cluster(ctl, False)
            lr_t, cap_t = per_cluster(ctl, True)
            bd_c, bd_t = ann(lr_c), ann(lr_t)
            cap_share = 100 * (w @ cap_t) / (n_assets * years * 365.25 * 24)
            eq = np.array([equivalent_lltv(flat_bd[b], FLAT_GRID * 100, bd_t[b])
                           for b in range(len(bd_t))])
            gain = ctl.lltv * 100 - eq
            net = ctl.lltv * 100 * (1 - cap_share / 100) - eq
            red = bd_c - bd_t
            with np.errstate(invalid="ignore", divide="ignore"):
                red_pct = 100 * red / bd_c
            rows.append({
                "group": gname, "cluster": cluster, "base_lltv": name, "kind": ctl.kind,
                "flat_bad_debt_bps_yr": bd_c[0], "flat_ci_lo": _q(bd_c)[0],
                "flat_ci_hi": _q(bd_c)[1],
                "treat_bad_debt_bps_yr": bd_t[0], "treat_ci_lo": _q(bd_t)[0],
                "treat_ci_hi": _q(bd_t)[1],
                "reduction_bps_yr": red[0], "reduction_ci_lo": _q(red)[0],
                "reduction_ci_hi": _q(red)[1],
                "reduction_pct": red_pct[0],
                "p_reduction_le_0": float(np.mean(red[1:] <= 0)),
                "equivalent_flat_lltv_pct": eq[0], "equiv_ci_lo": _q(eq)[0],
                "equiv_ci_hi": _q(eq)[1],
                "ltv_gain_pp": gain[0], "gain_ci_lo": _q(gain)[0], "gain_ci_hi": _q(gain)[1],
                "capacity_given_up_time_avg_pct": cap_share[0],
                "ltv_gain_net_pp": net[0], "net_ci_lo": _q(net)[0], "net_ci_hi": _q(net)[1],
                "n_clusters": n_c})
    return pd.DataFrame(rows), pd.DataFrame(curve)
