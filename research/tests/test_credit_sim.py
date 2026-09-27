import numpy as np
import pytest

import credit_sim as cs
from config import morpho_bonus

CTL = cs.Control("t86", 0.86, 0.044)


def _run(x_bps, var=None, ctl=CTL, **kw):
    p = cs.Params(**kw)
    v = None if var is None else np.array([float(var)])
    return cs.run_events(np.array([float(x_bps)]), v, ctl, p)


def test_gain_event_no_liquidation_no_bad_debt():
    r = _run(+500)
    assert r["liq_debt"][0] == 0 and r["bad"][0] == 0


def test_hand_computed_bad_debt():
    # x = -1500 bps -> S = exp(-0.15) = 0.860708. Liquidated iff u >= S: u = .90,.95,1.0.
    # Bad debt = d - S/1.044 = d - 0.824433 > 0 only for u=1.0: 0.86 - 0.824433 = 0.035567
    r = _run(-1500)
    s = np.exp(-0.15)
    assert r["bad"][0] == pytest.approx(0.05 * (0.86 - s / 1.044), rel=1e-9)
    assert r["liq_debt"][0] == pytest.approx(0.05 * 0.86 * (0.90 + 0.95 + 1.0), rel=1e-9)


def test_liquidated_share_is_scale_invariant_in_lltv():
    a = _run(-700, ctl=cs.Control("a", 0.385, 0.15))
    b = _run(-700, ctl=cs.Control("b", 0.86, 0.044))
    assert a["liq_debt"][0] / a["debt"][0] == pytest.approx(b["liq_debt"][0] / b["debt"][0])


def test_treatment_cap_formula_and_enforcement():
    # VaR 2000 bps, oracle 50, safety 100 -> cap = 1 - .20 - .005 - .01 = 0.785 (< LLTV .86)
    cap = cs.stress_cap(np.array([2000.0]), 0.86, 0.044, cs.Params())
    assert cap[0] == pytest.approx(0.785)
    full = _run(0, var=2000)
    none = _run(0, var=2000, enforcement=0.0)
    # u=.95 (d=.817) and u=1.0 (d=.86) are above the cap; e=1 cuts both to .785
    assert full["debt"][0] == pytest.approx(none["debt"][0] - 0.05 * ((0.817 - 0.785)
                                                                      + (0.86 - 0.785)))
    assert none["forced_delev"][0] == 0 and full["forced_delev"][0] > 0
    assert full["cap_reduction"][0] == pytest.approx((0.86 - 0.785) / 0.86)


def test_enforcement_zero_equals_control():
    c = _run(-1200)
    t = _run(-1200, var=500, enforcement=0.0)
    assert t["bad"][0] == c["bad"][0] and t["debt"][0] == c["debt"][0]


def test_cap_never_exceeds_lltv_nor_negative():
    cap = cs.stress_cap(np.array([0.0, 5000.0, 20000.0]), 0.86, 0.044, cs.Params())
    assert cap[0] == 0.86 and cap[1] == pytest.approx(0.485) and cap[2] == 0.0


def test_adverse_staleness_increases_losses():
    base = _run(-1400)
    stale = _run(-1400, noise_bps=50)
    assert stale["bad"][0] > base["bad"][0]


def test_treatment_reduces_bad_debt_when_binding():
    c = _run(-2000)
    t = _run(-2000, var=1500)  # cap = 1 - .15 - .015 = .835 -> top buckets cut
    assert t["bad"][0] < c["bad"][0]


def test_morpho_bonus_formula():
    assert morpho_bonus(0.86) == pytest.approx(1 / (0.3 * 0.86 + 0.7) - 1)
    assert morpho_bonus(0.385) == pytest.approx(0.15)  # capped by M = 1.15


def test_summarize_shapes():
    res = cs.run_events(np.array([-300.0, -1800.0, 100.0]), np.array([400.0, 400.0, 400.0]),
                        CTL, cs.Params())
    s = cs.summarize(res, np.array([48.0, 48.0, 72.0]), cs.Params(), 1.0, 1000.0)
    assert s["events"] == 3 and s["bad_debt_pct_of_outstanding"] >= 0
    assert 0 <= s["capacity_given_up_time_avg_pct"] <= 100
