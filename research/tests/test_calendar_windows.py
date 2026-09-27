from datetime import UTC, date, datetime, timedelta

import pandas as pd
import pytest

import calendar_windows as cw
from config import CALENDAR_FIXTURE

UTC = UTC


@pytest.fixture(scope="module")
def pairs():
    return cw.session_pairs("2010-01-01", "2026-12-31")


def _row(pairs, d2):
    r = pairs[pairs.d2 == d2]
    assert len(r) == 1
    return r.iloc[0]


def test_classify():
    assert [cw.classify(n) for n in (0, 1, 2, 3, 4, 5)] == [
        "Overnight", "Short", "Weekend", "Long", "Long", "Long"]


def test_plain_weekend_is_weekend_class_48h(pairs):
    r = _row(pairs, date(2026, 9, 28))  # Fri 09-25 -> Mon 09-28, EDT both ends
    assert (r.d1, r.n_closed, r.cls) == (date(2026, 9, 25), 2, "Weekend")
    assert r.start_utc == datetime(2026, 9, 26, 0, 0, tzinfo=UTC)  # Fri 20:00 EDT
    assert r.end_utc == datetime(2026, 9, 28, 0, 0, tzinfo=UTC)  # Sun 20:00 EDT
    assert r.hours == 48


def test_consecutive_weekdays_have_no_window(pairs):
    r = _row(pairs, date(2026, 9, 30))
    assert r.cls == "Overnight" and r.n_closed == 0 and pd.isna(r.start_utc) and r.hours == 0


def test_labor_day_2026_matches_onchain_observation(pairs):
    # DISCOVERY.md: feeds resumed Tue 09-08 00:00Z = Mon 09-07 20:00 ET.
    r = _row(pairs, date(2026, 9, 8))
    assert (r.d1, r.n_closed, r.cls) == (date(2026, 9, 4), 3, "Long")
    assert r.end_utc == datetime(2026, 9, 8, 0, 0, tzinfo=UTC)


def test_independence_day_observed_2026_matches_onchain_observation(pairs):
    # DISCOVERY.md: Fri 2026-07-03 holiday; feeds resumed Mon 07-06 00:00Z = Sun 07-05 20:00 ET.
    r = _row(pairs, date(2026, 7, 6))
    assert (r.d1, r.n_closed, r.cls) == (date(2026, 7, 2), 3, "Long")
    assert r.end_utc == datetime(2026, 7, 6, 0, 0, tzinfo=UTC)


def test_midweek_holiday_is_short(pairs):
    r = _row(pairs, date(2026, 11, 27))  # Thanksgiving Thu 11-26: Wed -> Fri
    assert (r.d1, r.n_closed, r.cls) == (date(2026, 11, 25), 1, "Short")
    assert r.hours == 24
    assert r.d2_early_close  # day after Thanksgiving closes early


def test_good_friday_weekend_is_long(pairs):
    r = _row(pairs, date(2026, 4, 6))  # Good Friday 2026-04-03: Thu -> Mon
    assert (r.d1, r.n_closed, r.cls) == (date(2026, 4, 2), 3, "Long")


def test_dst_makes_weekends_47_or_49_hours(pairs):
    spring = _row(pairs, date(2026, 3, 9))  # clocks forward Sun 2026-03-08
    fall = _row(pairs, date(2026, 11, 2))  # clocks back Sun 2026-11-01
    assert spring.cls == fall.cls == "Weekend"
    assert (spring.hours, fall.hours) == (47, 49)


def test_independent_day_walk_rederivation(pairs):
    """Re-derive every window by walking calendar days (no session diffs)."""
    cal = cw.get_xnys(end="2026-12-31")
    start, end = date(2010, 1, 4), date(2026, 9, 30)
    got = {r.d2: r for r in pairs.itertuples() if start <= r.d2 <= end}
    last_open = None
    closed = 0
    checked = 0
    day = date(2009, 12, 28)
    while day <= end:
        if cal.is_session(day.isoformat()):
            if last_open is not None and day >= start:
                r = got[day]
                assert r.d1 == last_open and r.n_closed == closed
                expected_cls = "Overnight" if closed == 0 else (
                    "Short" if closed == 1 else "Weekend" if closed == 2 else "Long")
                assert r.cls == expected_cls
                if closed:
                    # open of D2 = 20:00 ET on D2-1; close of D1 = 20:00 ET on D1
                    assert r.end_utc == cw._et_20h_utc(day - timedelta(days=1))
                    assert r.start_utc == cw._et_20h_utc(last_open)
                checked += 1
            last_open, closed = day, 0
        else:
            closed += 1
        day += timedelta(days=1)
    assert checked == len(got) > 4000


def test_windows_never_overlap_and_are_ordered(pairs):
    w = pairs[pairs.n_closed > 0].reset_index(drop=True)
    assert (w.end_utc > w.start_utc).all()
    assert (w.start_utc.iloc[1:].values >= w.end_utc.iloc[:-1].values).all()


@pytest.mark.skipif(not CALENDAR_FIXTURE.exists(),
                    reason="Session A has not produced calendar_cases.json yet")
def test_matches_session_a_fixture(pairs):
    # Schema unknown until Session A ships the fixture; reconcile when it lands.
    import json

    cases = json.loads(CALENDAR_FIXTURE.read_text())
    assert cases, "fixture is empty"
    pytest.skip("fixture present: add schema-specific comparison (starts, ends, classes)")
