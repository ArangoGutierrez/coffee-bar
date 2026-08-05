#!/usr/bin/env python3
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""Checks for assets/art/remap.py — the recolour for the rasters with no source.

Six files were delivered as an external export with no vector behind them, so
they cannot be re-cut and are recoloured pixel by pixel. That makes this script
destructive and unrepeatable: it rewrites shipped art in place, and the census
that follows only proves the GREEN is gone, not that what replaced it is right.
So the tests below pin what the census cannot see.

Each test names the bug it catches. The colour facts are derived independently
of remap.py: the two roast tokens come from assets/art/README.md, the composite
expectations come from alpha algebra, and the routing expectation comes from the
WCAG contrast formula implemented here rather than from remap.py's own table.

Run: python3 assets/art/remap_test.py
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image

REMAP_PATH = pathlib.Path(__file__).with_name("remap.py")

# Resolve the subject relative to THIS file. A harness that reaches for a
# copy somewhere else green-lights the wrong artifact.
_spec = importlib.util.spec_from_file_location("remap_under_test", REMAP_PATH)
remap_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(remap_mod)

RETIRED = (0x76, 0xB9, 0x00)  # the accent being removed
ROAST_LIGHT = (0xA2, 0x57, 0x1E)  # state, light appearance
ROAST_DARK = (0xB8, 0x68, 0x2A)  # state, dark appearance

ART = pathlib.Path(__file__).parent
THE_SIX = [
    ART / "github" / "readme-header-1600x400.png",
    ART / "github" / "social-preview-1280x640.png",
    ART / "wordmark" / "coffee-bar-wordmark-light.png",
    ART / "wordmark" / "coffee-bar-wordmark-light-2x.png",
    ART / "wordmark" / "coffee-bar-wordmark-dark.png",
    ART / "wordmark" / "coffee-bar-wordmark-dark-2x.png",
]


def make_png(path, pixels):
    """Write a 1-row RGBA PNG holding exactly `pixels`."""
    image = Image.new("RGBA", (len(pixels), 1))
    image.putdata([p if len(p) == 4 else p + (255,) for p in pixels])
    image.save(path)
    return path


def read_png(path):
    return list(Image.open(path).convert("RGBA").getdata())


def relative_luminance(rgb):
    """WCAG 2.1 relative luminance. Implemented here, not imported."""
    out = 0.0
    for channel, weight in zip(rgb, (0.2126, 0.7152, 0.0722)):
        c = channel / 255
        c = c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
        out += weight * c
    return out


def contrast(fg, bg):
    a, b = relative_luminance(fg), relative_luminance(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def background_of(path):
    """The most common opaque colour in a file — what the art was exported onto."""
    colours = Image.open(path).convert("RGBA").getcolors(2_000_000)
    return max((c for c in colours if c[1][3] == 255), key=lambda c: c[0])[1][:3]


def test_the_retired_accent_lands_exactly_on_its_token() -> None:
    """A solid #76B900 pixel must become the palette token, to the byte.

    Bug this catches: ratios picked by eye instead of derived. The accent
    then lands NEAR the token, so the six rasters carry a roast that no
    other surface in the product uses and the palette quietly forks.
    """
    for target, expected in (("#A2571E", ROAST_LIGHT), ("#B8682A", ROAST_DARK)):
        with tempfile.TemporaryDirectory() as tmp:
            path = make_png(pathlib.Path(tmp) / "solid.png", [RETIRED])
            remap_mod.remap(str(path), target)
            got = read_png(path)[0]
            assert got == expected + (255,), (
                f"#76B900 -> {got[:3]} under target {target}, expected {expected}; "
                "the remapped accent is not the palette token")


def test_an_anti_aliased_edge_keeps_its_coverage() -> None:
    """A partly-covered edge pixel must stay partly covered, not become solid.

    Bug this catches: a flat replace that stamps the token onto every matched
    pixel. The liquid's anti-aliased edge collapses to a hard step and the
    shape reads jagged at 1x.

    Expectations are alpha algebra, not remap.py's output: green composited
    over black at coverage a is a*green, and the correct result is a*token.
    One 8-bit step of tolerance covers the rounding of the source pixel.
    """
    coverages = [0.35, 0.5, 0.75, 0.9]
    sources = [tuple(round(a * c) for c in RETIRED) for a in coverages]
    with tempfile.TemporaryDirectory() as tmp:
        path = make_png(pathlib.Path(tmp) / "ramp.png", sources)
        remap_mod.remap(str(path), "#B8682A")
        got = read_png(path)

    for a, src, out in zip(coverages, sources, got):
        ideal = tuple(round(a * c) for c in ROAST_DARK)
        drift = max(abs(x - y) for x, y in zip(out[:3], ideal))
        assert drift <= 1, (
            f"coverage {a}: {src} -> {out[:3]}, expected about {ideal} "
            f"(off by {drift}); the anti-aliased ramp was not preserved")
        assert out[3] == 255, f"coverage {a}: alpha changed to {out[3]}"


def test_a_file_with_no_green_is_refused_and_left_untouched() -> None:
    """No match must abort loudly AND leave the file byte-identical.

    Bug this catches: the silent no-op. A substitution that matches nothing
    still exits 0 and still rewrites the file, so a re-encoded but unchanged
    raster looks like a successful recolour in both the log and the diff.
    """
    with tempfile.TemporaryDirectory() as tmp:
        path = make_png(pathlib.Path(tmp) / "no-green.png",
                        [(0xFF, 0xFF, 0xFF), ROAST_LIGHT, (0x12, 0x12, 0x14)])
        before = path.read_bytes()
        try:
            remap_mod.remap(str(path), "#A2571E")
        except SystemExit as exc:
            assert "no pixel in the green band" in str(exc), (
                f"aborted with an unhelpful message: {exc}")
        else:
            raise AssertionError(
                "a file with no green was accepted; a no-op recolour reports success")
        assert path.read_bytes() == before, (
            "the file was rewritten even though nothing matched")


def test_each_file_takes_the_token_that_passes_contrast_on_its_own_background() -> None:
    """Appearance follows the exported background, not a word in the filename.

    Bug this catches: routing on `"dark" in path`. Both github/ images carry
    no appearance word and sit on #000000, so a name test hands them the LIGHT
    token — which is 3.92:1 on their own background and fails 4.5:1. The census
    goes green and the art ships under-contrast.

    The expected token is derived here from the WCAG formula against the
    background actually found in the file, not read from remap.py's table.
    """
    for path in THE_SIX:
        assert path.exists(), f"{path} is missing"
        bg = background_of(path)
        declared = remap_mod.APPEARANCE.get(path.name)
        assert declared is not None, f"{path.name} has no declared appearance"
        token = tuple(int(remap_mod.TARGETS[declared].lstrip("#")[i:i + 2], 16)
                      for i in (0, 2, 4))
        other = ROAST_DARK if token == ROAST_LIGHT else ROAST_LIGHT
        assert contrast(token, bg) >= 4.5, (
            f"{path.name}: on background {bg} the '{declared}' token {token} "
            f"is {contrast(token, bg):.2f}:1 and fails 4.5:1")
        assert contrast(token, bg) > contrast(other, bg), (
            f"{path.name}: on background {bg} the '{declared}' token reads worse "
            f"({contrast(token, bg):.2f}:1) than the other token "
            f"({contrast(other, bg):.2f}:1)")


def test_a_file_with_no_declared_appearance_is_refused() -> None:
    """An unlisted file must abort, not fall back to a default.

    Bug this catches: a seventh file added later picks up whichever token the
    fallback happens to be, and nothing in the census can tell.
    """
    with tempfile.TemporaryDirectory() as tmp:
        path = make_png(pathlib.Path(tmp) / "not-declared.png", [RETIRED])
        proc = subprocess.run([sys.executable, str(REMAP_PATH), str(path)],
                              capture_output=True, text=True)
        assert proc.returncode != 0, (
            "an undeclared file was recoloured with a guessed appearance")
        assert "appearance" in (proc.stderr + proc.stdout), (
            f"the refusal did not say why. stderr: {proc.stderr!r}")
        assert read_png(path)[0][:3] == RETIRED, "the undeclared file was rewritten"


def test_colours_that_were_never_green_are_left_alone() -> None:
    """Only the green band moves. Everything else is byte-identical.

    Bug this catches: a band widened until it reaches the ink, the warm
    neutral base or the roast token itself, shifting colours the recolour
    was never meant to touch.
    """
    keep = [(0xFF, 0xFF, 0xFF), (0x00, 0x00, 0x00), (0x12, 0x12, 0x14),
            (0xF2, 0xF1, 0xEE), (0xEF, 0xED, 0xE7), ROAST_LIGHT, ROAST_DARK,
            (0xFF, 0x95, 0x00), (0x6B, 0x76, 0x83)]
    with tempfile.TemporaryDirectory() as tmp:
        path = make_png(pathlib.Path(tmp) / "palette.png", keep + [RETIRED])
        remap_mod.remap(str(path), "#A2571E")
        got = read_png(path)

    for expected, out in zip(keep, got):
        assert out[:3] == expected, (
            f"{expected} was shifted to {out[:3]}; a colour that was never "
            "green was recoloured")


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
