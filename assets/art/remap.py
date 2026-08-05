#!/usr/bin/env python3
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""Recolour the rasters that have no vector source.

Four wordmarks and two composite GitHub images were delivered as an external
export with no vector behind them, so they cannot be re-cut. This rotates the
retired accent's HUE and keeps each pixel's saturation, value and alpha, which
is what stops anti-aliased edges fringing: a partly-green edge pixel stays
partly-roast at the same lightness.
"""
import colorsys
import os
import sys
from PIL import Image

RETIRED = "#76B900"
TARGETS = {"light": "#A2571E", "dark": "#B8682A"}

# A file's appearance is the background it was exported onto, NOT a word in its
# name. Both github/ images carry no appearance word and sit on #000000, so a
# `"dark" in path` test hands them the LIGHT token, which fails contrast on
# their own background: #A2571E on #000000 is 3.92:1, #B8682A is 5.05:1. The
# table is explicit and an unlisted file is refused rather than guessed at.
APPEARANCE = {
    "readme-header-1600x400.png": "dark",
    "social-preview-1280x640.png": "dark",
    "coffee-bar-wordmark-light.png": "light",
    "coffee-bar-wordmark-light-2x.png": "light",
    "coffee-bar-wordmark-dark.png": "dark",
    "coffee-bar-wordmark-dark-2x.png": "dark",
}


def hsv_of(hex_colour):
    h = hex_colour.lstrip("#")
    rgb = tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return colorsys.rgb_to_hsv(*rgb)


def remap(path, target_hex):
    src_h, src_s, src_v = hsv_of(RETIRED)
    target_h, target_s, target_v = hsv_of(target_hex)
    # RATIOS, derived, not constants picked by eye. A pixel that is exactly the
    # retired accent lands exactly on the target, and a half-blended edge pixel
    # keeps its blend. Verified: #76B900 maps to #A2571E and to #B8682A exactly.
    s_ratio = target_s / src_s
    v_ratio = target_v / src_v
    image = Image.open(path).convert("RGBA")
    pixels = image.load()
    width, height = image.size
    touched = 0
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if not (70 / 360 <= h <= 100 / 360 and s > 0.25 and v > 0.20):
                continue
            # Scale s and v by the derived ratios so the edge ramp survives.
            nr, ng, nb = colorsys.hsv_to_rgb(target_h,
                                             min(1.0, s * s_ratio),
                                             min(1.0, v * v_ratio))
            pixels[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
            touched += 1
    if touched == 0:
        raise SystemExit(f"error: {path} had no pixel in the green band")
    image.save(path)
    print(f"{path}: {touched} pixels remapped -> {target_hex}")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        appearance = APPEARANCE.get(os.path.basename(arg))
        if appearance is None:
            raise SystemExit(f"error: {arg} has no declared appearance")
        remap(arg, TARGETS[appearance])
