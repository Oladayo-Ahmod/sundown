import numpy as np
import pandas as pd

import data
import gap_stats


def _raw(rows):
    idx = pd.to_datetime([r[0] for r in rows])
    df = pd.DataFrame(
        {"Open": [r[1] for r in rows], "Close": [r[2] for r in rows],
         "Dividends": [r[3] if len(r) > 3 else 0.0 for r in rows], "Stock Splits": 0.0},
        index=idx)
    df.index.name = "date"
    return df


def test_gap_is_prev_close_to_next_open_and_classified():
    # Thu 2026-09-24, Fri 09-25, Mon 09-28 (weekend), Tue 09-29
    raw = _raw([("2026-09-24", 99, 100), ("2026-09-25", 101, 102),
                ("2026-09-28", 100, 103), ("2026-09-29", 103, 104)])
    df, q = data.derive_gaps("TEST", raw)
    by = df.set_index("d2")
    wk = by.loc["2026-09-28"]
    assert wk.cls == "Weekend" and wk.n_closed == 2
    assert np.isclose(wk.gap_bps, 1e4 * np.log(100 / 102), atol=0.01)
    assert np.isclose(wk.oc_bps, 1e4 * np.log(103 / 100), atol=0.01)
    ov = by.loc["2026-09-25"]
    assert ov.cls == "Overnight" and np.isclose(ov.gap_bps, 1e4 * np.log(101 / 100), atol=0.01)
    assert q["pairs_kept"] == 3


def test_missing_session_drops_pair_instead_of_misclassifying():
    raw = _raw([("2026-09-24", 99, 100), ("2026-09-28", 100, 103)])  # Fri 09-25 missing
    df, q = data.derive_gaps("TEST", raw)
    assert len(df) == 0 and q["pairs_dropped_missing_or_invalid"] >= 1


def test_ex_dividend_handled_explicitly():
    raw = _raw([("2026-09-24", 99, 100), ("2026-09-25", 99, 100, 1.0)])
    df, _ = data.derive_gaps("TEST", raw)
    r = df.iloc[0]
    assert r.exdiv and np.isclose(r.div_bps, 100.0)
    assert np.isclose(r.gap_bps, 1e4 * np.log(0.99), atol=0.01)
    assert np.isclose(r.gap_divneutral_bps, 0.0, atol=0.01)  # dividend added back


def test_invalid_prices_are_dropped():
    raw = _raw([("2026-09-24", 99, 100), ("2026-09-25", 0.0, 100), ("2026-09-28", 100, 103)])
    df, q = data.derive_gaps("TEST", raw)
    assert len(df) == 0 and q["invalid_ohlc_rows"] == 1


def test_class_stats_quantiles_downside_and_conservative():
    x = np.arange(-100, 100, dtype=float)  # 200 obs, worst = -100
    panel = pd.DataFrame({"ticker": "T", "cls": "Weekend", "gap_bps": x,
                          "d2": pd.date_range("2020-01-01", periods=200)})
    s = gap_stats.class_stats(panel).iloc[0]
    assert s.n == 200 and s.worst_bps == -100
    assert s["loss_q99_bps"] == 99 and s["loss_q95_bps"] == 91
    assert s["loss_q99.9_bps"] == 100  # unresolvable at n=200 -> sample worst
    assert "0.99" in s.q_resolvable and "0.999" not in s.q_resolvable


def test_variance_ratio_recovers_known_scale():
    rng = np.random.default_rng(1)
    months = pd.date_range("2010-01-01", periods=120, freq="MS")
    rows = []
    for m in months:
        for _ in range(20):
            rows.append(("T", "Overnight", rng.normal(0, 100), m))
        for _ in range(4):
            rows.append(("T", "Weekend", rng.normal(0, 200), m))  # variance ratio 4
    panel = pd.DataFrame(rows, columns=["ticker", "cls", "gap_bps", "d2"])
    vr = gap_stats.variance_ratios(panel, n_boot=500)
    r = vr[(vr.ticker == "T") & (vr.cls == "Weekend")].iloc[0]
    assert r.ci_lo < 4.0 < r.ci_hi and abs(r.vr - 4) < 0.5
