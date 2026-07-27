#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# spikes-note: assembles the throwaway menu-bar POC bundle. M1 replaces this
# with a real signed/notarised build. No .xcodeproj is involved and none is
# needed — SwiftPM builds the SwiftUI MenuBarExtra fine and the bundle is
# assembled by hand.
#
# Usage: scripts/build-poc-app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PRODUCT="coffee-bar-poc"
APP_NAME="CoffeeBarPOC"
BUNDLE_ID="com.coffeebar.poc"
OUT_DIR="${REPO_ROOT}/build"
APP="${OUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
ART="${REPO_ROOT}/assets/art/menubar"

die() {
    echo "error: $*" >&2
    exit 1
}

# --- build -------------------------------------------------------------------

echo "==> swift build -c release --product ${PRODUCT}"
swift build -c release --product "${PRODUCT}"

BIN_DIR="$(swift build -c release --product "${PRODUCT}" --show-bin-path)"
BIN="${BIN_DIR}/${PRODUCT}"
[ -x "${BIN}" ] || die "release binary not found at ${BIN}"

# --- bundle skeleton ---------------------------------------------------------

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

# `command cp` bypasses an interactive `cp -i` alias, which would decline the
# copy and still exit 0.
command cp -f "${BIN}" "${CONTENTS}/MacOS/${PRODUCT}"
[ -x "${CONTENTS}/MacOS/${PRODUCT}" ] || die "binary did not land in the bundle"

# --- menu-bar glyphs ---------------------------------------------------------
#
# PDF is what AppKit prefers at 16pt; the PNGs ride along as a fallback. The
# `Template` suffix in the filenames is load-bearing and must survive the copy.

glyph_count=0
for src in "${ART}/pdf"/*Template.pdf "${ART}/png"/*Template.png; do
    [ -f "${src}" ] || continue
    command cp -f "${src}" "${CONTENTS}/Resources/"
    glyph_count=$((glyph_count + 1))
done
[ "${glyph_count}" -gt 0 ] || die "no template glyphs copied from ${ART}"

# The two states the POC actually switches between must both be present.
for required in coffee-bar-idleTemplate coffee-bar-servingTemplate; do
    [ -f "${CONTENTS}/Resources/${required}.pdf" ] \
        || die "missing required glyph ${required}.pdf in the bundle"
done
echo "    ${glyph_count} glyph files copied"

# --- Info.plist --------------------------------------------------------------

cat >"${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>coffee-bar (POC)</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# --- validate ----------------------------------------------------------------

plutil -lint "${CONTENTS}/Info.plist" || die "Info.plist failed plutil -lint"

# -lint accepts any well-formed plist, so confirm the key that actually
# suppresses the Dock icon really is set.
ui_element="$(plutil -extract LSUIElement raw -o - "${CONTENTS}/Info.plist")"
[ "${ui_element}" = "true" ] || die "LSUIElement is '${ui_element}', expected true"
echo "    LSUIElement=true (no Dock icon)"

# --- done --------------------------------------------------------------------

cat <<DONE

Built ${APP}

Launch it:

    open "${APP}"

Then click the coffee-cup glyph in the menu bar, flip "Serving" on, and check:

    pmset -g assertions | grep -i coffee-bar

Quit from the same menu (or 'q') and the assertion disappears.
DONE
