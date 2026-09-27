"""Independent oracle for UsMarketCalendar (offline analysis, not production).

Builds contracts/test/fixtures/calendar_cases.json from exchange_calendars (XNYS sessions, holidays,
early closes, regular open/close) and zoneinfo (America/New_York DST). The window model is the D1
decision in docs/DESIGN.md section 8, derived here from the *session list*, never from Solidity:

    consecutive open trading days D1 < D2 -> blind window [20:00 ET on D1, 20:00 ET on D2-1)
    class by n = D2 - D1 - 1 closed calendar days: 1 Short, 2 Weekend, >=3 Long
    id = day index (days since 1970-01-01) of D1

Run: python calendar_oracle.py [--out PATH]
"""

from __future__ import annotations

import argparse
import bisect
import json
import random
from datetime import UTC, date, datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import exchange_calendars as xcals
import pandas as pd

NY = ZoneInfo("America/New_York")
EPOCH = date(1970, 1, 1)
FIRST = date(2024, 1, 1)
LAST = date(2035, 12, 31)
SEED = 20260101
N_RANDOM = 20_000

SESSION_CODE = {"Closed": 0, "PreMarket": 1, "Regular": 2, "PostMarket": 3, "Overnight": 4}
DEFAULT_OUT = Path(__file__).resolve().parents[1] / "contracts/test/fixtures/calendar_cases.json"


def day_index(d: date) -> int:
    return (d - EPOCH).days


def et_to_utc(d: date, hh: int, mm: int = 0) -> int:
    return int(datetime.combine(d, time(hh, mm), tzinfo=NY).astimezone(UTC).timestamp())


def build_calendar():
    cal = xcals.get_calendar("XNYS", start="2023-06-01", end="2037-06-30")
    sessions = [s.date() for s in cal.sessions]
    return cal, sessions


def build_windows(sessions: list[date]) -> list[dict]:
    windows = []
    for d1, d2 in zip(sessions, sessions[1:], strict=False):
        n = (d2 - d1).days - 1
        if n <= 0:
            continue
        cls = 0 if n == 1 else 1 if n == 2 else 2
        windows.append(
            {
                "start": et_to_utc(d1, 20),
                "end": et_to_utc(d2 - timedelta(days=1), 20),
                "cls": cls,
                "id": day_index(d1),
                "n": n,
            }
        )
    return windows


def dst_transitions(year: int) -> list[int]:
    """UTC instants at which the NY offset changes, found by scanning hourly (no rule knowledge)."""
    out = []
    t = int(datetime(year, 1, 1, tzinfo=UTC).timestamp())
    end = int(datetime(year + 1, 1, 1, tzinfo=UTC).timestamp())
    prev = datetime.fromtimestamp(t, NY).utcoffset()
    while t < end:
        t += 3600
        cur = datetime.fromtimestamp(t, NY).utcoffset()
        if cur != prev:
            out.append(t)
            prev = cur
    return out


def expected_session(ts: int, blind: bool, early: set[date]) -> int:
    if blind:
        return SESSION_CODE["Closed"]
    dt = datetime.fromtimestamp(ts, NY)
    tod = dt.hour * 3600 + dt.minute * 60 + dt.second
    if tod >= 20 * 3600 or tod < 4 * 3600:
        return SESSION_CODE["Overnight"]
    if tod < 9 * 3600 + 1800:
        return SESSION_CODE["PreMarket"]
    close = 13 * 3600 if dt.date() in early else 16 * 3600
    return SESSION_CODE["Regular"] if tod < close else SESSION_CODE["PostMarket"]


def lookup(windows: list[dict], starts: list[int], ts: int, early: set[date]) -> dict:
    i = bisect.bisect_right(starts, ts) - 1
    inside = i >= 0 and windows[i]["start"] <= ts < windows[i]["end"]
    if inside:
        w = windows[i]
        wid, cls = w["id"], w["cls"]
    else:
        wid, cls = windows[i + 1]["id"], 0
    return {
        "ts": ts,
        "blind": 1 if inside else 0,
        "id": wid,
        "cls": cls,
        "session": expected_session(ts, inside, early),
    }


def columns(rows: list[dict]) -> dict:
    return {k: [r[k] for r in rows] for k in ("ts", "blind", "id", "cls", "session")}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    cal, all_sessions = build_calendar()
    windows = build_windows(all_sessions)
    starts = [w["start"] for w in windows]
    in_range = [d for d in all_sessions if FIRST <= d <= LAST]
    early = {d.date() for d in cal.early_closes if FIRST <= d.date() <= LAST}

    adhoc_dates = set()
    for ah in cal.adhoc_holidays:
        d = pd.Timestamp(ah).date()
        if FIRST <= d <= LAST:
            adhoc_dates.add(d)

    session_set = set(all_sessions)
    holidays = []
    d = FIRST
    while d <= LAST:
        if d.weekday() < 5 and d not in session_set:
            holidays.append(d)
        d += timedelta(days=1)

    reg_open = [int(cal.opens[pd.Timestamp(s)].timestamp()) for s in in_range]
    reg_close = [int(cal.closes[pd.Timestamp(s)].timestamp()) for s in in_range]

    dst_ts, dst_off = [], []
    for y in range(2020, 2041):
        for t in dst_transitions(y):
            for dt in (t - 1, t, t + 1):
                dst_ts.append(dt)
                dst_off.append(-int(datetime.fromtimestamp(dt, NY).utcoffset().total_seconds()))

    rng = random.Random(SEED)
    lo = int(datetime(2024, 1, 2, tzinfo=UTC).timestamp())
    hi = int(datetime(2035, 12, 29, tzinfo=UTC).timestamp())
    rand_rows = [lookup(windows, starts, rng.randrange(lo, hi), early) for _ in range(N_RANDOM)]

    in_win = [w for w in windows if lo < w["start"] and w["end"] < hi]
    boundary_ts = sorted(
        {t for w in in_win for t in (w["start"] - 1, w["start"], w["end"] - 1, w["end"])}
    )
    boundary_rows = [lookup(windows, starts, t, early) for t in boundary_ts]

    out = {
        "meta": {
            "generator": "research/calendar_oracle.py",
            "exchange_calendars": xcals.__version__,
            "seed": SEED,
            "range": [FIRST.isoformat(), LAST.isoformat()],
            "model": "D1 trading-day windows; see docs/CALENDAR_NOTES.md",
        },
        "windows": {k: [w[k] for w in in_win] for k in ("start", "end", "cls", "id")},
        "sessions": [day_index(s) for s in in_range],
        "tdOpen": [et_to_utc(s - timedelta(days=1), 20) for s in in_range],
        "tdClose": [et_to_utc(s, 20) for s in in_range],
        "regOpen": reg_open,
        "regClose": reg_close,
        "holidays": [day_index(h) for h in holidays],
        "adhoc": sorted(day_index(a) for a in adhoc_dates),
        "earlyCloses": sorted(day_index(e) for e in early),
        "dst": {"ts": dst_ts, "offset": dst_off},
        "random": columns(rand_rows),
        "boundary": columns(boundary_rows),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, separators=(",", ":")))
    print(
        f"wrote {args.out} windows={len(in_win)} sessions={len(in_range)} holidays={len(holidays)} "
        f"adhoc={sorted(a.isoformat() for a in adhoc_dates)} early={len(early)} dst={len(dst_ts)} "
        f"random={len(rand_rows)} boundary={len(boundary_rows)}"
    )


if __name__ == "__main__":
    main()
