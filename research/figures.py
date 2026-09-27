"""Static figures for docs/figures (matplotlib, rendered from results/ and derived series).

Style: one axis per chart, thin marks, recessive grid, legend whenever >= 2 series, text in ink
colours (never the series colour). Series use a fixed Okabe-Ito-derived order.
"""

from __future__ import annotations

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

import backtest as bt  # noqa: E402
from config import DEPLOY_SUBSET, FIGURES_DIR, RESULTS_DIR, TEST_START  # noqa: E402
from data import load_panel  # noqa: E402

INK, MUTED, GRID = "#1f2933", "#616e7c", "#e4e7eb"
C = {"Overnight": "#56B4E9", "Short": "#E69F00", "Weekend": "#0072B2", "Long": "#D55E00"}
SERIES = ["#0072B2", "#E69F00", "#009E73", "#D55E00"]

plt.rcParams.update({
    "figure.dpi": 130, "savefig.dpi": 160, "font.size": 9, "axes.edgecolor": GRID,
    "axes.labelcolor": INK, "text.color": INK, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
    "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
    "axes.titlesize": 10, "axes.titleweight": "bold", "axes.titlelocation": "left",
})


def _save(fig, name):
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(FIGURES_DIR / name)
    plt.close(fig)


def fig_gap_distributions(panel):
    fig, axes = plt.subplots(1, 4, figsize=(11, 3.2), sharey=False)
    for ax, t in zip(axes, DEPLOY_SUBSET, strict=True):
        g = panel[panel.ticker == t]
        bins = np.linspace(-1000, 600, 65)
        for cls in ("Overnight", "Weekend", "Long"):
            ax.hist(g[g.cls == cls].gap_bps.clip(-1000, 600), bins=bins, density=True,
                    histtype="step", linewidth=1.2, color=C[cls], label=cls)
        ax.set_yscale("log")
        ax.set_title(t)
        ax.set_xlabel("gap, bps (clipped at -1000)")
    axes[0].set_ylabel("density (log)")
    axes[0].legend(frameon=False, fontsize=8)
    fig.suptitle("Gap distributions by window class (prev close -> next open, 2010-2026)",
                 x=0.01, ha="left", fontsize=10, fontweight="bold")
    _save(fig, "m2_gap_distributions.png")


def fig_variance_ratio():
    vr = pd.read_csv(RESULTS_DIR / "variance_ratios.csv")
    fig, axes = plt.subplots(1, 3, figsize=(11, 3.6), sharey=True)
    for ax, cls in zip(axes, ("Short", "Weekend", "Long"), strict=True):
        v = vr[vr.cls == cls].copy()
        v = pd.concat([v[v.ticker == "MEDIAN"], v[v.ticker != "MEDIAN"].sort_values("vr")])
        y = np.arange(len(v))
        ax.hlines(y, v.ci_lo, v.ci_hi, color=MUTED, linewidth=1.2)
        ax.plot(v.vr, y, "o", color=C[cls], markersize=5)
        ax.axvline(1, color=INK, linewidth=0.8, linestyle=":", label="trading-time (1x)")
        ax.axvline(float(v.ref_calendar_time.iloc[0]), color=INK, linewidth=0.8,
                   linestyle="--", label="calendar-time")
        ax.set_yticks(y, v.ticker)
        ax.set_title(f"{cls} / Overnight variance ratio")
        ax.set_xlabel("E[gap^2 | class] / E[gap^2 | overnight]  (95% month-cluster CI)")
    axes[0].legend(frameon=False, fontsize=8, loc="lower right")
    _save(fig, "m2_variance_ratios.png")


def fig_backtest(df):
    import estimators as est
    from run_backtest import final_forecast

    cand = est.Candidate("pooled", lam=0.9)
    var, _, _, _ = final_forecast(df, cand, 0.99)
    fig, axes = plt.subplots(2, 1, figsize=(11, 5.6), sharex=True)
    for ax, t in zip(axes, ("SPY", "TSLA"), strict=True):
        s = (df.ticker == t) & (df.cls == "Weekend") & (df.d2 >= TEST_START)
        d = df[s]
        v = var[s.to_numpy()]
        ax.plot(d.d2, d.loss, ".", color=MUTED, markersize=3, label="realised loss (bps)")
        ax.plot(d.d2, v, "-", color=C["Weekend"], linewidth=1.2,
                label="99% gap-VaR (out of sample)")
        viol = d.loss.to_numpy() > v
        ax.plot(d.d2[viol], d.loss[viol], "o", color=C["Long"], markersize=4,
                markeredgecolor="white", markeredgewidth=0.6, label="exceedance")
        ax.set_title(f"{t} weekend windows: {int(viol.sum())} exceedances of {len(d)} "
                     f"({viol.mean():.1%}, target 1%)")
        ax.set_ylabel("bps")
    axes[0].legend(frameon=False, fontsize=8, ncol=3, loc="upper left")
    _save(fig, "m2_backtest_weekend_var.png")


def fig_oracle_noise():
    d = pd.read_csv(RESULTS_DIR / "intraday_windows.csv")
    adv = d.feed_err_adverse_bps.clip(lower=0)
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.4))
    axes[0].hist(adv, bins=np.arange(0, 52, 2), color=C["Weekend"], alpha=0.85)
    axes[0].axvline(50, color=C["Long"], linewidth=1.2)
    axes[0].text(49, axes[0].get_ylim()[1] * 0.9, "50 bps deviation bound ", ha="right",
                 color=INK, fontsize=8)
    axes[0].set_xlabel("feed overvalues collateral at window start, bps (simulated)")
    axes[0].set_ylabel("windows")
    axes[0].set_title("Adverse oracle staleness at window start")
    ok = d.dropna(subset=["n2_lag_h"])
    axes[1].hist(ok.n2_lag_h.clip(upper=30), bins=np.arange(0, 31, 1), color=C["Short"],
                 alpha=0.9)
    axes[1].set_yscale("log")
    axes[1].set_xlabel("first post-window update lag, hours (no push at reopen; clipped at 30)")
    axes[1].set_title("N2 censoring: lag of first observation")
    _save(fig, "m2_oracle_noise_censoring.png")


def fig_credit():
    c = pd.read_csv(RESULTS_DIR / "credit_summary.csv")
    f = pd.read_csv(RESULTS_DIR / "credit_frontier.csv")
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))
    ax = axes[0]
    sub = c[(c.group == "UNIVERSE12") & (c.scenario == "blind")
            & c.control.isin(["morpho_77", "morpho_86", "cf_90", "cf_93", "cf_95"])]
    x = np.arange(5)
    names = ["77%", "86%", "90%*", "93%*", "95%*"]
    for i, (arm, lab, col) in enumerate((("control", "flat LLTV", SERIES[1]),
                                         ("treat_e1", "stress rule (full enforcement)",
                                          SERIES[0]))):
        s = sub[sub.arm == arm].set_index("control").loc[
            ["morpho_77", "morpho_86", "cf_90", "cf_93", "cf_95"]]
        ax.bar(x + (i - 0.5) * 0.38, s.annualised_bad_debt_bps, 0.36, color=col, label=lab)
    ax.set_xticks(x, names)
    ax.set_xlabel("base LLTV (* = counterfactual, not observed in the wild)")
    ax.set_ylabel("annualised bad debt, bps of outstanding")
    ax.set_title("Window-gap bad debt, 2018-2026, 12 assets")
    ax.legend(frameon=False, fontsize=8)
    ax = axes[1]
    s = c[(c.group == "UNIVERSE12") & (c.arm == "control") & (c.control == "morpho_86")]
    order = ["Weekend", "Long", "Short", "overnight", "regular"]
    s = s.set_index("scenario").loc[order]
    cols = [C["Weekend"], C["Long"], C["Short"], MUTED, "#999999"]
    ax.bar(range(5), s.annualised_bad_debt_bps, color=cols)
    ax.set_xticks(range(5), ["Weekend", "Long", "Short", "Overnight\n(n=0)", "Regular\nhours"])
    ax.set_title("Flat-86% bad debt by gap source")
    ax.set_ylabel("annualised bad debt, bps of outstanding")
    _save(fig, "m2_credit_sim.png")
    fig, ax = plt.subplots(figsize=(6.2, 3.8))
    g = f[(f.group == "UNIVERSE12") & (f.kind == "counterfactual")]
    ax.bar(range(3), g.ltv_gain_pp_gross, color=SERIES[0], label="gross LTV gain at equal risk")
    ax.plot(range(3), g.ltv_gain_pp_net_of_capacity, "o", color=SERIES[3], markersize=6,
            label="net of capacity given up")
    ax.set_xticks(range(3), ["90%", "93%", "95%"])
    ax.set_xlabel("treatment base LLTV (counterfactual)")
    ax.set_ylabel("percentage points of LTV")
    ax.set_title("Equal-bad-debt frontier gain vs flat LLTV")
    ax.legend(frameon=False, fontsize=8)
    _save(fig, "m2_frontier.png")


def main():
    panel = load_panel()
    df = bt.blind_panel(panel)
    fig_gap_distributions(panel)
    fig_variance_ratio()
    fig_backtest(df)
    fig_oracle_noise()
    fig_credit()


if __name__ == "__main__":
    main()
