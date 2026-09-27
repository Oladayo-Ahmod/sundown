"""M2.1 figures: frontier with bootstrap bands, slippage/bonus heatmaps, per-asset benefit."""

from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from config import RESULTS_DIR  # noqa: E402
from figures import GRID, INK, MUTED, SERIES, C, _save  # noqa: E402,F401


def fig_frontier():
    fig, axes = plt.subplots(2, 2, figsize=(11, 7), sharey=True)
    for r, cluster in enumerate(("month", "date")):
        pts = pd.read_csv(RESULTS_DIR / f"credit_frontier_{cluster}.csv" if cluster == "month"
                          else RESULTS_DIR / "credit_frontier_datecluster.csv")
        cur = pd.read_csv(RESULTS_DIR / ("credit_frontier_curve_month.csv" if cluster == "month"
                                         else "credit_frontier_curve_datecluster.csv"))
        for c, grp in enumerate(("UNIVERSE12", "DEPLOY4")):
            ax = axes[r, c]
            k = cur[cur.group == grp]
            ax.fill_betweenx(k.lltv_pct, k.ci_lo, k.ci_hi, color=SERIES[1], alpha=0.25,
                             linewidth=0, label="flat LLTV, 95% band")
            ax.plot(k.annualised_bad_debt_bps, k.lltv_pct, color=SERIES[1], linewidth=1.6,
                    label="flat LLTV")
            p = pts[pts.group == grp]
            ax.errorbar(p.treat_bad_debt_bps_yr, p.base_lltv.map(
                {"morpho_86": 86, "cf_90": 90, "cf_93": 93, "cf_95": 95}),
                xerr=[p.treat_bad_debt_bps_yr - p.treat_ci_lo,
                      p.treat_ci_hi - p.treat_bad_debt_bps_yr],
                fmt="o", color=SERIES[0], markersize=6, capsize=3, linewidth=1,
                label="stress rule (hard deleveraging), 95% CI")
            ax.set_title(f"{grp}, clustered by {cluster}")
            ax.set_xlabel("annualised bad debt, bps of outstanding")
            if c == 0:
                ax.set_ylabel("base LLTV, %")
            ax.set_ylim(76, 96)
    axes[0, 0].legend(frameon=False, fontsize=8, loc="lower right")
    _save(fig, "m21_frontier_bands.png")


def fig_slippage():
    s = pd.read_csv(RESULTS_DIR / "slippage_grid.csv")
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))
    for ax, lt in zip(axes, (0.77, 0.86), strict=True):
        x = s[(s.group == "UNIVERSE12") & (s.lltv == lt)]
        m = x.pivot(index="bonus", columns="slippage", values="flat_bps_yr")
        ax.imshow(np.log10(m.to_numpy() + 0.1), cmap="Blues", aspect="auto", origin="lower")
        ax.set_xticks(range(m.shape[1]), [f"{v:.0%}" for v in m.columns])
        ax.set_yticks(range(m.shape[0]), [f"{v:.1%}" for v in m.index])
        for i in range(m.shape[0]):
            for j in range(m.shape[1]):
                v = m.to_numpy()[i, j]
                ax.text(j, i, f"{v:.1f}" if v < 100 else f"{v:.0f}", ha="center", va="center",
                        fontsize=7, color="white" if np.log10(v + 0.1) > 0.9 else INK)
        ax.set_xlabel("liquidation slippage")
        ax.set_ylabel("liquidation bonus")
        ax.set_title(f"Flat LLTV {lt:.0%}: bad debt, bps/yr (12 assets, 2018-26)")
        ax.grid(False)
    _save(fig, "m21_slippage_bonus.png")


def fig_per_asset():
    pa = pd.read_csv(RESULTS_DIR / "per_asset_credit.csv")
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.8), sharey=True)
    for ax, name, lab in zip(axes, ("morpho_86", "cf_93"), ("86% (in the wild)", "93% (cf)"),
                             strict=True):
        d = pa[pa.control == name].sort_values("flat_bps_yr", ascending=False)
        y = np.arange(len(d))
        ax.barh(y - 0.2, d.flat_bps_yr, 0.38, color=SERIES[1], label="flat")
        ax.barh(y + 0.2, d.stress_bps_yr, 0.38, color=SERIES[0], label="stress rule")
        ax.set_yticks(y, d.ticker)
        ax.invert_yaxis()
        ax.set_title(f"Annualised bad debt by asset, base LLTV {lab}")
        ax.set_xlabel("bps of outstanding per year")
    axes[0].legend(frameon=False, fontsize=8)
    _save(fig, "m21_per_asset.png")


def main():
    fig_frontier()
    fig_slippage()
    fig_per_asset()


if __name__ == "__main__":
    main()
