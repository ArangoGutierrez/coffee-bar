#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Assembles build/CoffeeBar.app from the `coffee-bar` SwiftPM product. No
# .xcodeproj is involved and none is needed — SwiftPM builds the SwiftUI
# MenuBarExtra fine and the bundle is assembled by hand.
#
# The bundle this produces is unsigned. Signing, notarisation and Sparkle are
# M4, so a copy handed to another Mac is quarantined by Gatekeeper.
#
# Usage: scripts/build-app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PRODUCT="coffee-bar"
APP_NAME="CoffeeBar"
BUNDLE_ID="com.coffeebar.app"
OUT_DIR="${REPO_ROOT}/build"
APP="${OUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
ART="${REPO_ROOT}/assets/art/menubar"

die() {
    echo "error: $*" >&2
    exit 1
}

# --- version -----------------------------------------------------------------
#
# The git tag is the single source of version truth: .github/workflows/release.yml
# triggers on `v*` and builds its tarball URL from ${GITHUB_REF_NAME}. Nothing is
# hard-coded here, per design spec §7.
#
# `git describe` exits 128 with "No names found" when no tag exists, and none
# does yet, so the untagged fallback is the only path that runs today. Under
# `set -e` an unguarded call would abort every build.
VERSION_RAW="$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null || true)"
VERSION="${VERSION_RAW#v}"
VERSION="${VERSION:-0.0.0-dev}"

if [ -n "${VERSION_RAW}" ]; then
    echo "==> version ${VERSION} (from git tag ${VERSION_RAW})"
else
    echo "==> version ${VERSION} (no git tag in this repo; untagged fallback)"
fi

# --- build -------------------------------------------------------------------
#
# `--package-path` rather than `cd`: a failed `cd` would build the wrong tree.

echo "==> swift build -c release --product ${PRODUCT}"
swift build -c release --product "${PRODUCT}" --package-path "${REPO_ROOT}"

BIN_DIR="$(swift build -c release --product "${PRODUCT}" --package-path "${REPO_ROOT}" --show-bin-path)"
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
    # The exit code of `cp` proves nothing; check the file arrived.
    [ -f "${CONTENTS}/Resources/$(basename "${src}")" ] \
        || die "copy of ${src} did not land in the bundle"
    glyph_count=$((glyph_count + 1))
done
[ "${glyph_count}" -gt 0 ] || die "no template glyphs copied from ${ART}"

# The two states the app actually switches between must both be present.
# MenuBarGlyphs falls back to the `cup.and.saucer` SF Symbol when a PDF is
# missing, so an incomplete bundle still looks like a working app.
for required in coffee-bar-idleTemplate coffee-bar-servingTemplate; do
    [ -f "${CONTENTS}/Resources/${required}.pdf" ] \
        || die "missing required glyph ${required}.pdf in the bundle"
done
echo "    ${glyph_count} glyph files copied"

# --- Info.plist --------------------------------------------------------------
#
# CFBundleVersion stays at 1: it is the build number, not the marketing version.
# A monotonic build number belongs with Sparkle in M4.

cat >"${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>coffee-bar</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
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

Built ${APP} (version ${VERSION}, unsigned)

Launch it:

    open "${APP}"

Then run the manual acceptance checklist:

    .superpowers/sdd/2026-07-28-coffee-bar-m1/task6-acceptance-checklist.md
DONE
