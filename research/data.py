"""Download vendor data (git-ignored) and derive the committed gap series.

Source: Yahoo Finance via yfinance (free; terms of service apply, personal/research use).
Prices are split-adjusted but NOT dividend-adjusted (auto_adjust=False -> 'Close'/'Open').
Why: the quantity of interest is the move of the quoted price over the closed window; a
dividend back-adjustment rescales history by a ratio that never traded. Ex-dividend days are
handled explicitly: the primary gap includes the ex-date drop (conservative), and a
dividend-neutral variant adds the cash dividend back (stock tokens accrue dividends into
uiMultiplier, DISCOVERY.md b, so the token-level drop is smaller than the share drop; the
timing of that multiplier update vs the feed is UNVERIFIED).

Only derived returns are committed (no prices) to respect the "no raw vendor data" rule.
"""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

import calendar_windows as cw
from config import DERIVED_DIR, HISTORY_START, RAW_DIR, UNIVERSE

MAX_SANE_ABS_GAP = 0.40  # |ln(open/prev close)| above this is flagged for manual review


def raw_path(ticker: str):
    return RAW_DIR / f"{ticker}_daily.csv"


def download_raw(ticker: str) -> dict:
    import yfinance as yf

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    hist = yf.Ticker(ticker).history(
        start=HISTORY_START, auto_adjust=False, actions=True, repair=False
    )
    hist.index = pd.DatetimeIndex(hist.index).tz_localize(None).normalize()
    hist.index.name = "date"
    cols = ["Open", "High", "Low", "Close", "Volume", "Dividends", "Stock Splits"]
    # Drop the in-progress session: its Close is a live quote, not an official close.
    today_et = pd.Timestamp(datetime.now(ZoneInfo("America/New_York")).date())
    hist = hist[cols][hist.index < today_et]
    hist.to_csv(raw_path(ticker), float_format="%.6f")
    digest = hashlib.sha256(raw_path(ticker).read_bytes()).hexdigest()
    return {
        "ticker": ticker,
        "rows": len(hist),
        "first": str(hist.index[0].date()),
        "last": str(hist.index[-1].date()),
        "sha256": digest,
    }


def load_raw(ticker: str) -> pd.DataFrame:
    return pd.read_csv(raw_path(ticker), index_col="date", parse_dates=True)


def derive_gaps(ticker: str, raw: pd.DataFrame | None = None) -> tuple[pd.DataFrame, dict]:
    """Per consecutive-session pair: gap/ret series in bps. Returns (frame, quality report)."""
    raw = load_raw(ticker) if raw is None else raw
    first, last = raw.index[0], raw.index[-1]
    pairs = cw.session_pairs(str(first.date()), str(last.date()))
    # The pair table starts at the first session at/after `first` whose predecessor may not
    # be in the data; missing sessions are handled by the NaN checks below.
    sessions = set(pairs.d2) | set(pairs.d1)
    px = raw[["Open", "Close", "Dividends", "Stock Splits"]].copy()
    px.index = px.index.date
    valid_px = (px.Open > 0) & (px.Close > 0) & px.Open.notna() & px.Close.notna()
    quality = {
        "ticker": ticker,
        "raw_rows": int(len(raw)),
        "non_session_rows": int(sum(d not in sessions for d in px.index)),
        "invalid_ohlc_rows": int((~valid_px).sum()),
    }
    out = []
    missing_pairs = 0
    for r in pairs.itertuples():
        if r.d1 not in px.index or r.d2 not in px.index:
            missing_pairs += 1
            continue
        a, b = px.loc[r.d1], px.loc[r.d2]
        if not (valid_px[r.d1] and valid_px[r.d2]):
            missing_pairs += 1
            continue
        gap = float(np.log(b.Open / a.Close))
        oc = float(np.log(b.Close / b.Open))
        div = float(b.Dividends)
        out.append({
            "d1": r.d1.isoformat(),
            "d2": r.d2.isoformat(),
            "n_closed": r.n_closed,
            "cls": r.cls,
            "hours": r.hours,
            "d1_early_close": r.d1_early_close,
            "gap_bps": round(gap * 1e4, 2),
            "gap_divneutral_bps": round(float(np.log((b.Open + div) / a.Close)) * 1e4, 2),
            "oc_bps": round(oc * 1e4, 2),
            "exdiv": div > 0,
            "div_bps": round(div / a.Close * 1e4, 2),
            "split": float(b["Stock Splits"]) not in (0.0, 1.0),
        })
    cols = ["d1", "d2", "n_closed", "cls", "hours", "d1_early_close", "gap_bps",
            "gap_divneutral_bps", "oc_bps", "exdiv", "div_bps", "split"]
    df = pd.DataFrame(out, columns=cols)
    quality["pairs_total"] = int(len(pairs))
    quality["pairs_dropped_missing_or_invalid"] = int(missing_pairs)
    quality["pairs_kept"] = int(len(df))
    big = df[df.gap_bps.abs() > MAX_SANE_ABS_GAP * 1e4]
    quality["flagged_abs_gap_gt_40pct"] = big[["d2", "gap_bps"]].to_dict("records")
    quality["first_pair"] = df.d2.iloc[0] if len(df) else None
    quality["last_pair"] = df.d2.iloc[-1] if len(df) else None
    return df, quality


def write_derived(ticker: str, df: pd.DataFrame) -> None:
    DERIVED_DIR.mkdir(parents=True, exist_ok=True)
    df.to_csv(DERIVED_DIR / f"{ticker}.csv", index=False)


def load_derived(ticker: str) -> pd.DataFrame:
    df = pd.read_csv(DERIVED_DIR / f"{ticker}.csv", parse_dates=["d1", "d2"])
    df["ticker"] = ticker
    return df


def load_panel(tickers: list[str] | None = None) -> pd.DataFrame:
    return pd.concat([load_derived(t) for t in (tickers or UNIVERSE)], ignore_index=True)


def refresh_all(tickers: list[str] | None = None) -> None:
    """Re-download everything and rewrite derived series + a provenance manifest."""
    manifest = {"retrieved_utc": datetime.now(UTC).isoformat(timespec="seconds"),
                "source": "Yahoo Finance via yfinance", "price_basis": "split-adjusted, "
                "not dividend-adjusted (auto_adjust=False)", "assets": []}
    for t in tickers or UNIVERSE:
        meta = download_raw(t)
        df, q = derive_gaps(t)
        write_derived(t, df)
        manifest["assets"].append({**meta, "quality": q})
        print(t, meta["rows"], meta["first"], meta["last"], q["pairs_kept"],
              "dropped", q["pairs_dropped_missing_or_invalid"],
              "flagged", len(q["flagged_abs_gap_gt_40pct"]))
    DERIVED_DIR.mkdir(parents=True, exist_ok=True)
    (DERIVED_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    refresh_all()
