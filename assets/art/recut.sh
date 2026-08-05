#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Re-rasterises every raster that has a vector source. Six files have none —
# github/readme-header, github/social-preview and the four wordmarks — and are
# handled separately.
#
# Several outputs are byte-identical to each other in the shipped package, so
# this renders each unique image once and copies. `command cp` bypasses an
# interactive `cp -i` alias, which would decline and still exit 0.

set -euo pipefail

# This script lives at <root>/assets/art/recut.sh, so the root is TWO levels up.
cd "$(dirname "$0")/../.."
# Every path below is root-relative. A wrong working directory would otherwise
# create a parallel tree and leave the real rasters stale, all at exit 0.
[ -d assets/art ] && [ -d site ] || {
    echo "error: $(pwd) is not the repo root" >&2; exit 1
}

A=assets/art
LIGHT=$A/appicon/svg/AppIcon-default.svg
DARK=$A/appicon/svg/AppIcon-dark.svg
WEB=site/appicon-web.svg

render() {  # render <svg> <size> <out>
    rsvg-convert -w "$2" -h "$2" "$1" -o "$3"
    [ -s "$3" ] || { echo "error: $3 is empty" >&2; exit 1; }
}

for s in 16 32 64 128 256 512 1024; do
    render "$LIGHT" "$s" "$A/appicon/png/default/AppIcon-$s.png"
    render "$DARK"  "$s" "$A/appicon/png/dark/AppIcon-$s.png"
done

# The iconset duplicates the light renders under Apple's naming.
IS=$A/appicon/AppIcon.iconset
command cp -f "$A/appicon/png/default/AppIcon-16.png"   "$IS/icon_16x16.png"
command cp -f "$A/appicon/png/default/AppIcon-32.png"   "$IS/icon_16x16-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-32.png"   "$IS/icon_32x32.png"
command cp -f "$A/appicon/png/default/AppIcon-64.png"   "$IS/icon_32x32-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-128.png"  "$IS/icon_128x128.png"
command cp -f "$A/appicon/png/default/AppIcon-256.png"  "$IS/icon_128x128-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-256.png"  "$IS/icon_256x256.png"
command cp -f "$A/appicon/png/default/AppIcon-512.png"  "$IS/icon_256x256-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-512.png"  "$IS/icon_512x512.png"
command cp -f "$A/appicon/png/default/AppIcon-1024.png" "$IS/icon_512x512-2x.png"

# web/ sits on the web tile #F2F0EB, which is why it has its own source.
for s in 16 32 48; do render "$WEB" "$s" "$A/web/favicon-$s.png"; done
render "$WEB" 180 "$A/web/apple-touch-icon-180.png"
render "$WEB" 192 "$A/web/icon-192.png"
render "$WEB" 512 "$A/web/icon-512.png"

# The dark web icon and both GitHub avatars are the DARK appicon render.
command cp -f "$A/appicon/png/dark/AppIcon-512.png"  "$A/web/icon-512-dark.png"
command cp -f "$A/appicon/png/dark/AppIcon-512.png"  "$A/github/repo-avatar-512.png"
command cp -f "$A/appicon/png/dark/AppIcon-1024.png" "$A/github/repo-avatar-1024.png"

# Maskable insets the art by 0.72 about the canvas centre for the platform
# safe zone (assets/art/README.md).
python3 - "$A/web/icon-512.png" "$A/web/icon-512-maskable.png" <<'PY'
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
image = Image.open(src).convert("RGBA")
size = image.size[0]
inner = round(size * 0.72)
canvas = Image.new("RGBA", (size, size), image.getpixel((0, 0)))
canvas.paste(image.resize((inner, inner), Image.LANCZOS), ((size - inner) // 2,) * 2)
canvas.save(dst)
PY

echo "re-cut complete"
