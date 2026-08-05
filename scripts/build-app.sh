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

# Pids of processes that run a coffee-bar bundle, one "    pid <n>  <path>" line
# each, empty when there are none.
#
# Two literal path patterns, never a substring of the product name. `pgrep -f
# coffee-bar` matches `coffee-bar-poc` as well, and killing off that match once
# took three unrelated processes with it:
#
#   1. anything running out of this build directory, whatever the bundle is
#      named — the case that started this, a POC bundle whose source tree was
#      already deleted;
#   2. this app's own executable path under any bundle anywhere — a copy in
#      /Applications, or a build from a second worktree.
#
# `ps -o comm=` prints the full executable path on macOS, so both patterns
# anchor on a whole path, and `/MacOS/coffee-bar` cannot match
# `/MacOS/coffee-bar-poc`. Process listing is denied in some sandboxes; an
# unreadable process table means "none found", never a failed build.
running_bundles() {
    local pid comm
    while read -r pid comm; do
        case "${comm}" in
            "${OUT_DIR}"/* | *"/${APP_NAME}.app/Contents/MacOS/${PRODUCT}")
                printf '    pid %s  %s\n' "${pid}" "${comm}"
                ;;
        esac
    done < <(ps -axo pid=,comm= 2>/dev/null || true)
    return 0
}

# --- bundles this script does not own ----------------------------------------
#
# `rm -rf` below touches ${APP} and nothing else, so every other bundle in
# build/ survives every rebuild. build/CoffeeBarPOC.app outlived the deletion of
# its own source tree and sat in the menu bar beside the real app, drawn from
# the very same glyph files, until someone clicked the wrong cup.
#
# Report, do not delete. build/ is also where a signed or downloaded bundle gets
# parked for comparison, and a build script that removes bundles it never
# created is its own kind of hazard.
foreign_bundles=""
for candidate in "${OUT_DIR}"/*.app; do
    if [ -d "${candidate}" ] && [ "${candidate}" != "${APP}" ]; then
        foreign_bundles="${foreign_bundles}$(printf '    rm -rf %q' "${candidate}")"$'\n'
    fi
done
if [ -n "${foreign_bundles}" ]; then
    {
        echo "error: ${OUT_DIR} holds a bundle this script does not own."
        echo
        printf '%s' "${foreign_bundles}"
        echo
        echo "A second bundle puts a second, identical cup in the menu bar and takes the"
        echo "clicks meant for this one. Run the command above, then build again."
    } >&2
    exit 1
fi

# --- version -----------------------------------------------------------------
#
# The git tag is the single source of version truth: .github/workflows/release.yml
# triggers on `v*` and builds its tarball URL from ${GITHUB_REF_NAME}. Nothing is
# hard-coded here, per design spec §7.
#
# `git describe` exits 128 with "No names found" when no tag exists, and none
# does yet, so the untagged fallback is the only path that runs today. Under
# `set -e` an unguarded call would abort every build.
# `COFFEE_BAR_VERSION` wins when set. A Homebrew build unpacks a release
# TARBALL, which carries no `.git`, so `git describe` finds nothing there and
# every brew-installed app would otherwise report `0.0.0-dev`. The formula knows
# the version it is building and passes it in.
VERSION_RAW="${COFFEE_BAR_VERSION:-$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION_RAW#v}"
VERSION="${VERSION:-0.0.0-dev}"

if [ -n "${COFFEE_BAR_VERSION:-}" ]; then
    echo "==> version ${VERSION} (from COFFEE_BAR_VERSION)"
elif [ -n "${VERSION_RAW}" ]; then
    echo "==> version ${VERSION} (from git tag ${VERSION_RAW})"
else
    echo "==> version ${VERSION} (no git tag in this repo; untagged fallback)"
fi

# --- build -------------------------------------------------------------------
#
# `--package-path` rather than `cd`: a failed `cd` would build the wrong tree.
#
# `COFFEE_BAR_SWIFT_FLAGS` exists for one caller: Homebrew. SwiftPM runs its own
# `sandbox-exec`, and that cannot nest inside Homebrew's own sandbox — it fails
# with `sandbox_apply: Operation not permitted`, which SwiftPM then reports as a
# MANIFEST error, sending the reader after a `Package.swift` that is fine. The
# formula sets this to `--disable-sandbox`. Unset, nothing changes.
# shellcheck disable=SC2086
SWIFT_FLAGS="${COFFEE_BAR_SWIFT_FLAGS:-}"

echo "==> swift build -c release --product ${PRODUCT} ${SWIFT_FLAGS}"
swift build -c release --product "${PRODUCT}" --package-path "${REPO_ROOT}" ${SWIFT_FLAGS}

BIN_DIR="$(swift build -c release --product "${PRODUCT}" --package-path "${REPO_ROOT}" ${SWIFT_FLAGS} --show-bin-path)"
BIN="${BIN_DIR}/${PRODUCT}"
[ -x "${BIN}" ] || die "release binary not found at ${BIN}"

# --- older instance still running --------------------------------------------
#
# A new bundle means nothing while an older instance owns the menu bar: the two
# icons are the same file, and `open` reactivates the running process instead of
# starting the build that just finished. Warn, do not fail — a rebuild while the
# app runs is the normal inner loop — and warn again at the end, where the
# message cannot scroll away behind the compiler output.

running="$(running_bundles)"
if [ -n "${running}" ]; then
    {
        echo "warning: an older coffee-bar build is still running:"
        # `$(…)` ate the trailing newline; %s\n puts back exactly one.
        printf '%s\n' "${running}"
        echo "Quit it from its menu-bar cup before you open the new bundle."
    } >&2
fi

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

# --- licence -----------------------------------------------------------------
#
# Apache-2.0 section 4(a) requires giving every recipient of the Work a copy of
# the Licence. The DMG is a distribution of the Work in Object form, so the
# licence travels inside the bundle rather than only in the repository.
#
# `-s` and not `-f`: an empty file satisfies `-f` and complies with nothing.
command cp -f "${REPO_ROOT}/LICENSE" "${CONTENTS}/Resources/LICENSE"
[ -s "${CONTENTS}/Resources/LICENSE" ] \
    || die "LICENSE did not land in the bundle"
echo "    LICENSE copied ($(wc -c < "${CONTENTS}/Resources/LICENSE" | tr -d ' ') bytes)"

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
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Carlos Eduardo Arango Gutierrez. Apache-2.0. A personal project, not an NVIDIA product.</string>
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
DONE

# The checklist lives under .superpowers/, which git does not track, so a build
# from a release tarball has no such file — and this was the last thing every
# `brew install` user saw: a path into a directory that is not there. Guard it
# rather than drop it, so a maintainer building a full checkout keeps the
# pointer.
CHECKLIST=".superpowers/sdd/2026-07-28-coffee-bar-m1/task6-acceptance-checklist.md"

if [ -f "${REPO_ROOT}/${CHECKLIST}" ]; then
    cat <<DONE

Then run the manual acceptance checklist:

    ${CHECKLIST}
DONE
fi

# Read the process table again: the build takes minutes, and an instance can
# start or stop inside that window.
running="$(running_bundles)"
if [ -n "${running}" ]; then
    {
        echo "warning: the menu bar still belongs to an older build:"
        printf '%s\n' "${running}"
        echo
        echo "Quit that cup first, or kill the pid above. Until then the cup you click"
        echo "is the old process, not the bundle this run just built."
    } >&2
fi
