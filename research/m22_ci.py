"""M2.2 bootstrap CIs (month- and date-clustered) for the two model-based headline results:
(1) flat-bonus effect: bad debt at 5.5 % vs 2 % bonus (DEPLOY4 mean, depth-constrained);
(2) boosted-tier break-even borrow APR per asset (30 % boosted debt, deleveraging on)."""

from __future__ import annotations

import numpy as np
import pandas as pd

import credit_sim as cs
import liquidation as lq
import m21_analysis as m21
import m22_analysis as m22
from config import DEPLOY_SUBSET, RESULTS_DIR, SEED

N_BOOT = 2000


def _ids(g, cluster):
    key = g.d2.dt.to_period("M").astype(str) if cluster == "month" else g.d2.dt.strftime("%F")
    return pd.factorize(key)[0]


def main():
    panel, df, chosen, var, ev, years = m21.setup()
    depth = m22.tvl()
    rng = np.random.default_rng(SEED + 41)
    rows = []
    for cluster in ("month", "date"):
        # shared cluster structure across assets (all assets' events on a date/month together)
        keys = {}
        ids = {}
        for t in DEPLOY_SUBSET:
            g = ev[(t, "blind")]
            k = g.d2.dt.to_period("M").astype(str) if cluster == "month" else g.d2.dt.strftime("%F")
            ids[t] = np.array([keys.setdefault(v, len(keys)) for v in k])
        n_c = len(keys)
        w = np.vstack([np.ones(n_c), rng.multinomial(n_c, np.full(n_c, 1 / n_c), size=N_BOOT)
                       ]).astype(float)

        def ann(lr, t, w=w, ids=ids, n_c=n_c):
            s = np.bincount(ids[t], weights=lr, minlength=n_c)
            return 1e4 * (w @ s) / years

        def ci(a):
            return float(a[0]), float(np.quantile(a[1:], 0.025)), float(np.quantile(a[1:], 0.975))

        # (1) bonus 5.5 % vs 2 % (CF100, flat), DEPLOY4 mean
        for lt in (0.86, 0.93):
            res = {}
            for b in (0.055, 0.02):
                d = lq.Design("f", "flat", b, 1.0)
                tot = 0
                for t in DEPLOY_SUBSET:
                    g = ev[(t, "blind")]
                    o = lq.simulate(g.gap_bps.to_numpy(float), g.oc_bps.to_numpy(float),
                                    [lq.Tier(lt)], d, depth[t], 0.25 * depth[t])
                    tot = tot + ann(o["loss_ratio"], t) / len(DEPLOY_SUBSET)
                res[b] = tot
            for name, a in (("bonus 5.5%", res[0.055]), ("bonus 2%", res[0.02]),
                            ("reduction 5.5%->2%", res[0.055] - res[0.02])):
                v = ci(a)
                rows.append({"cluster": cluster, "what": name, "lltv": lt, "est": v[0],
                             "ci_lo": v[1], "ci_hi": v[2]})
        # (2) boosted tier break-even APR per asset
        for t in DEPLOY_SUBSET:
            g = ev[(t, "blind")]
            x, oc = g.gap_bps.to_numpy(float), g.oc_bps.to_numpy(float)
            vr = g["var"].to_numpy(float)
            d = lq.Design("f", "flat", 0.055, 1.0)
            for lb in (0.90, 0.93):
                cap = cs.stress_cap(vr, lb, 0.055, cs.Params())
                for util in ("uniform", "high"):
                    theta = 0.3
                    tiers = [lq.Tier(0.77, 1 - theta), lq.Tier(lb, theta, util, cap)]
                    o = lq.simulate(x, oc, tiers,
                                    d, depth[t], 0.25 * depth[t])
                    base = lq.simulate(x, oc, [lq.Tier(0.77)], d, depth[t], 0.25 * depth[t])
                    added = ann(o["loss_ratio"], t) - ann(base["loss_ratio"], t)
                    apr = added / 1e4 / (theta * (1 - 0.77 / lb)) * 100
                    v = ci(apr)
                    rows.append({"cluster": cluster, "what": f"{t} boosted {util} break-even APR %",
                                 "lltv": lb, "est": v[0], "ci_lo": v[1], "ci_hi": v[2]})
    pd.DataFrame(rows).to_csv(RESULTS_DIR / "m22_headline_ci.csv", index=False,
                              float_format="%.4g")


if __name__ == "__main__":
    main()
