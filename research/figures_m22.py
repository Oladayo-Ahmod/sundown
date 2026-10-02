"""M2.2 figures."""

from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from config import RESULTS_DIR  # noqa: E402
from figures import SERIES, C, _save  # noqa: E402


def fig_designs():
    d = pd.read_csv(RESULTS_DIR / "liq_design_comparison.csv")
    d = d[d.asset == "DEPLOY4 mean"]
    names = ["flat 4.4% CF100", "flat 5.5% CF100", "flat 5.5% CF50", "dutch 60min",
             "cap 5% of depth", "dutch 60min bmax=formula"]
    labels = ["flat 4.4%", "flat 5.5%", "flat 5.5%\nCF50", "Dutch 1-5.5%\n(60 min)",
              "cap 5% of\ndepth", "Dutch to\nbmax=formula*"]
    fig, axes = plt.subplots(1, 3, figsize=(12.5, 3.8))
    for ax, lt in zip(axes[:2], (0.86, 0.93), strict=True):
        v = [float(d[(d.design == n) & (d.lltv == lt)].bad_bps_yr.iloc[0]) for n in names]
        ax.bar(range(len(names)), v, color=[SERIES[0], SERIES[1], SERIES[1], SERIES[2], C["Short"],
                                            "#999999"])
        ax.set_xticks(range(len(names)), labels, fontsize=7)
        ax.set_title(f"Bad debt by liquidation design, flat LLTV {lt:.0%}")
        ax.set_ylabel("bps/yr (DEPLOY4 mean)")
    b = pd.read_csv(RESULTS_DIR / "liq_bonus_sweep.csv")
    ax = axes[2]
    for (lam, lt), g in b.groupby(["market_debt_x_tvl", "lltv"]):
        ax.plot(g.bonus * 100, g.bad_bps_yr_mean_deploy4, "o-", markersize=4,
                label=f"LLTV {lt:.0%}, debt {lam}x TVL",
                linestyle="-" if lam == 0.25 else "--")
    ax.set_yscale("log")
    ax.set_xlabel("flat liquidation bonus, %")
    ax.set_title("Bad debt vs bonus (depth-constrained)")
    ax.legend(frameon=False, fontsize=7)
    _save(fig, "m22_liquidation_designs.png")


def fig_two_tier():
    t = pd.read_csv(RESULTS_DIR / "two_tier.csv")
    t = t[(t.design == "flat 5.5% CF100") & (t.concentration == 1.0)
          & (t.boosted_debt_share == 0.3) & t.pre_window_deleveraging]
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.8), sharey=True)
    for ax, lb in zip(axes, (0.90, 0.93), strict=True):
        g = t[t.boosted_lltv == lb]
        x = np.arange(4)
        for i, (u, col) in enumerate((("uniform", SERIES[0]), ("high", SERIES[3]))):
            v = [float(g[(g.asset == a) & (g.boosted_util == u)].breakeven_borrow_apr_pct.iloc[0])
                 for a in ("SPY", "AAPL", "NVDA", "TSLA")]
            ax.bar(x + (i - 0.5) * 0.38, v, 0.36, color=col,
                   label=f"borrowers: {u}")
        ax.axhline(5.0, color="#444444", linewidth=0.9, linestyle=":")
        ax.text(3.45, 5.2, "5% assumed APR", ha="right", fontsize=7)
        ax.set_xticks(x, ["SPY", "AAPL", "NVDA", "TSLA"])
        ax.set_title(f"Boosted tier {lb:.0%}: break-even borrow APR")
    axes[0].set_ylabel("APR needed to cover added lender bad debt, %")
    axes[0].legend(frameon=False, fontsize=8)
    _save(fig, "m22_two_tier_breakeven.png")


if __name__ == "__main__":
    fig_designs()
    fig_two_tier()
