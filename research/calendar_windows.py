"""Blind-window derivation per decision D1, from the exchange_calendars NYSE calendar.

Rule (D1): trading day D opens 20:00 ET on the calendar day before D and closes 20:00 ET on
D; weekends and NYSE holidays are closed trading days. For consecutive sessions D1 < D2 the
blind window is [20:00 ET on D1, 20:00 ET on (D2 - 1 calendar day)). Class by closed calendar
days n = D2 - D1 - 1: n=1 Short, n=2 Weekend, n>=3 Long (calendar-day count, not hours).
n=0 is the "Overnight" reference class and has no blind window.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import exchange_calendars as xcals
import pandas as pd

from config import WINDOW_OPEN_HOUR_ET

ET = ZoneInfo("America/New_York")
UTC = ZoneInfo("UTC")


def classify(n_closed: int) -> str:
    if n_closed <= 0:
        return "Overnight"
    if n_closed == 1:
        return "Short"
    if n_closed == 2:
        return "Weekend"
    return "Long"


def _et_20h_utc(d: date) -> datetime:
    return datetime(d.year, d.month, d.day, WINDOW_OPEN_HOUR_ET, tzinfo=ET).astimezone(UTC)


def window_bounds(d1: date, d2: date) -> tuple[datetime, datetime] | None:
    """UTC [start, end) of the blind window between consecutive sessions, None if n == 0."""
    if (d2 - d1).days - 1 <= 0:
        return None
    return _et_20h_utc(d1), _et_20h_utc(d2 - timedelta(days=1))


def get_xnys(start: str = "2009-12-01", end: str | None = None):
    kwargs = {"start": pd.Timestamp(start)}
    if end is not None:
        kwargs["end"] = pd.Timestamp(end)
    return xcals.get_calendar("XNYS", **kwargs)


def session_pairs(start: str, end: str) -> pd.DataFrame:
    """All consecutive NYSE session pairs (D1, D2) with D2 in [start, end].

    Columns: d1, d2, n_closed, cls, start_utc, end_utc, hours, d1_early_close, d2_early_close.
    """
    cal = get_xnys(end=(pd.Timestamp(end) + pd.Timedelta(days=5)).strftime("%Y-%m-%d"))
    sessions = cal.sessions_in_range(
        pd.Timestamp(start) - pd.Timedelta(days=10), pd.Timestamp(end)
    )
    early = set(pd.DatetimeIndex(cal.early_closes).tz_localize(None).normalize())
    rows = []
    for a, b in zip(sessions[:-1], sessions[1:], strict=True):
        d1, d2 = a.date(), b.date()
        if b < pd.Timestamp(start):
            continue
        n = (d2 - d1).days - 1
        bounds = window_bounds(d1, d2)
        rows.append({
            "d1": d1,
            "d2": d2,
            "n_closed": n,
            "cls": classify(n),
            "start_utc": bounds[0] if bounds else None,
            "end_utc": bounds[1] if bounds else None,
            "hours": (bounds[1] - bounds[0]).total_seconds() / 3600 if bounds else 0.0,
            "d1_early_close": pd.Timestamp(a).normalize() in early,
            "d2_early_close": pd.Timestamp(b).normalize() in early,
        })
    return pd.DataFrame(rows)
