#!/usr/bin/env python3
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""Assert that no raster under assets/art still carries the retired accent.

A failed image conversion leaves the OLD file in place and exits 0, so a
green pipeline is not evidence. This opens every file and looks.

It also asserts the NUMBER of files inspected. A guard reads what a file
says and cannot see a file it never opened, so a silently skipped path
would otherwise pass.
"""
import colorsys
import glob
import sys
from PIL import Image

RETIRED = (0x76, 0xB9, 0x00)
EXPECTED_TOTAL = 62  # every PNG under assets/art, measured 2026-08-05


def green_band(rgb):
    """True for any hue a #76B900 pixel could have blended into."""
    r, g, b = (c / 255 for c in rgb[:3])
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    return 70 / 360 <= h <= 100 / 360 and s > 0.25 and v > 0.20


def main():
    paths = sorted(glob.glob("assets/art/**/*.png", recursive=True))
    failures = []
    for path in paths:
        image = Image.open(path).convert("RGBA")
        colours = image.getcolors(1_000_000) or []
        exact = sum(n for n, c in colours if c[:3] == RETIRED)
        banded = sum(n for n, c in colours if c[3] > 0 and green_band(c))
        if exact or banded:
            failures.append(f"{path}: {exact} exact #76B900, {banded} in the green band")

    if len(paths) != EXPECTED_TOTAL:
        failures.append(
            f"inspected {len(paths)} PNGs, expected {EXPECTED_TOTAL}. "
            "A file was added, removed, or silently skipped."
        )

    for line in failures:
        print(f"FAIL {line}", file=sys.stderr)
    print(f"checked {len(paths)} rasters, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
