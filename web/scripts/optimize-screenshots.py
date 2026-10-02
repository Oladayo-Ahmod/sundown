#!/usr/bin/env python3
"""Converts the Playwright PNG screenshots in docs/figures/web to WebP (max 1440 px wide, quality 80) and keeps
only the six that are committed: home, risk and replay at 1440 and 390 px. Run with the research venv (Pillow):

    SHOTS=1 SCREENSHOT_DIR=<tmp> playwright test tests/screenshots.spec.ts
    research/.venv/bin/python web/scripts/optimize-screenshots.py <tmp> docs/figures/web
"""
import sys
from pathlib import Path

from PIL import Image

KEEP = {f"{p}-{w}" for p in ("home", "risk", "replay") for w in (1440, 390)}
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
for old in dst.glob("*.png"):
    old.unlink()
for png in sorted(src.glob("*.png")):
    if png.stem not in KEEP:
        continue
    im = Image.open(png)
    if im.width > 1440:
        im = im.resize((1440, round(im.height * 1440 / im.width)), Image.LANCZOS)
    out = dst / f"{png.stem}.webp"
    im.convert("RGB").save(out, "WEBP", quality=80, method=6)
    print(out.name, f"{out.stat().st_size // 1024} KB", im.size)
