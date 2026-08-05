#!/usr/bin/env python3
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""Checks for assets/art/census.py — the guard that the accent is really gone.

census.py is the only evidence that the re-cut landed. A failed image
conversion leaves the OLD file in place and exits 0, so the pipeline is
silent about it. That makes the census itself load-bearing, and a guard
that cannot discriminate is worse than no guard: it reports clean forever.

Two failure directions matter, and each test below names the one it catches:

  too narrow — the band misses an anti-aliased green edge, so a bad re-cut
               reports clean;
  too wide   — the band reaches the roast accent that REPLACES the green, so
               the census can never pass and the re-cut is unverifiable.

The colour facts asserted here are properties of the colours, derived with
colorsys independently of census.py: #76B900 sits at hue 81.7 deg, and both
roast accents sit near hue 26 deg.

Run: python3 assets/art/census_test.py
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image

CENSUS_PATH = pathlib.Path(__file__).with_name("census.py")

# Resolve the subject relative to THIS file. A harness that reaches for a
# copy somewhere else green-lights the wrong artifact.
_spec = importlib.util.spec_from_file_location("census_under_test", CENSUS_PATH)
census = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(census)

RETIRED = (0x76, 0xB9, 0x00)  # the accent being removed
ROAST_LIGHT = (0xA2, 0x57, 0x1E)  # what replaces it on the light icon
ROAST_DARK = (0xB8, 0x68, 0x2A)  # and on the dark icon


def run_census(pngs: dict[str, tuple[int, int, int]]) -> subprocess.CompletedProcess:
    """Run the real census over a temp tree holding exactly `pngs`.

    census.py globs `assets/art/**/*.png` relative to the working directory,
    so the tree is built under a temp cwd rather than mocked.
    """
    with tempfile.TemporaryDirectory() as tmp:
        art = pathlib.Path(tmp) / "assets" / "art"
        art.mkdir(parents=True)
        for name, rgb in pngs.items():
            Image.new("RGBA", (8, 8), rgb + (255,)).save(art / name)
        return subprocess.run([sys.executable, str(CENSUS_PATH)],
                              cwd=tmp, capture_output=True, text=True)


def test_the_retired_accent_is_inside_the_band() -> None:
    """The colour the guard exists to find must be in the band.

    Bug this catches: the band is narrowed until it no longer covers
    #76B900 itself, and every raster reports clean while still green.
    """
    assert census.green_band(RETIRED) is True, (
        "#76B900 (hue 81.7 deg) fell outside the green band; "
        "the guard cannot see the colour it exists to find")


def test_an_anti_aliased_edge_pixel_is_still_caught() -> None:
    """Blended green must be caught, not just the exact token.

    Bug this catches: an exact-match-only census. rsvg anti-aliases the
    liquid edge, so after a bad re-cut the surviving green is blended with
    the tile or the ink and no pixel equals #76B900 any more. The census
    then reports clean over a still-green raster.

    Each literal below is #76B900 mixed with a real neighbouring colour:
    25% and 50% toward the web tile #F2F0EB, and 50% toward the ink.
    """
    for rgb, why in [((0x95, 0xC7, 0x3B), "25% toward the web tile"),
                     ((0xB4, 0xD4, 0x76), "50% toward the web tile"),
                     ((0x44, 0x66, 0x0A), "50% toward the ink")]:
        assert census.green_band(rgb) is True, (
            f"#{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X} ({why}) escaped the band; "
            "an anti-aliased green edge would survive the census")


def test_the_roast_accents_are_outside_the_band() -> None:
    """The replacement colour must NOT trip the guard.

    Bug this catches: a band widened until it reaches hue 26 deg. The census
    then fails on correctly re-cut art, so it can never pass and stops being
    evidence of anything.
    """
    for rgb in (ROAST_LIGHT, ROAST_DARK):
        assert census.green_band(rgb) is False, (
            f"#{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X} (hue ~26 deg) was flagged as green; "
            "the census would fail on correctly re-cut art")


def test_near_neutral_colours_are_outside_the_band() -> None:
    """The saturation and value floors must survive.

    Bug this catches: dropping `s > 0.25` or `v > 0.20`. The near-white tile
    sits at hue 42.9 deg and the near-black ink at hue 240 deg, but both are
    one careless edit away from being read as coloured pixels.
    """
    for rgb, what in [((0xF2, 0xF0, 0xEB), "the web tile"),
                      ((0x12, 0x12, 0x14), "the vector ink"),
                      ((0x10, 0x10, 0x13), "the shipped raster ink"),
                      ((0xFF, 0xFF, 0xFF), "white")]:
        assert census.green_band(rgb) is False, f"{what} was flagged as green"


def test_a_green_raster_is_reported_by_name() -> None:
    """End to end: a green PNG produces a FAIL line naming that file.

    Bug this catches: a census that opens every file and then forgets to
    report, or reports without the path, leaving nothing actionable.
    """
    proc = run_census({"still-green.png": RETIRED})

    assert proc.returncode == 1, f"census exited {proc.returncode} over a green raster"
    assert "still-green.png" in proc.stderr, (
        f"the offending file was not named. stderr: {proc.stderr!r}")
    assert "exact #76B900" in proc.stderr, (
        f"the exact-match count was not reported. stderr: {proc.stderr!r}")


def test_a_missing_file_fails_even_though_every_opened_file_is_clean() -> None:
    """The count guard fires when the tree is short, with no colour failure.

    Bug this catches: a silently skipped path. A guard cannot see a file it
    never opened, so content checks alone pass over a tree that lost files.
    This also pins the other direction: a roast-only raster raises NO colour
    failure, so the count line is the only one.
    """
    proc = run_census({"roast-only.png": ROAST_LIGHT})

    assert proc.returncode == 1, "a short tree passed the census"
    assert "expected 62" in proc.stderr, (
        f"the file-count guard did not fire. stderr: {proc.stderr!r}")
    assert "roast-only.png" not in proc.stderr, (
        f"a correctly re-cut raster was reported as a colour failure. "
        f"stderr: {proc.stderr!r}")
    assert proc.stderr.count("FAIL") == 1, (
        f"expected the count failure alone, got: {proc.stderr!r}")


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except AssertionError as exc:
            failed += 1
            print(f"FAIL {t.__name__}: {exc}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
