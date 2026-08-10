#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Builds the release disk image: a signed, notarised, stapled
# build/dist/coffee-bar-<version>.dmg, plus the size and SHA-256 that CHANGELOG.md
# requires be true of the SHIPPED build.
#
# v0.1.1 shipped a DMG and left no trace of how. This script is that trace.
#
# Usage: scripts/release-dmg.sh
#
# Environment overrides exist so the suite can execute the offline core. The
# defaults are the release values.
#
#   SIGN_IDENTITY  codesign identity          (default: the Developer ID)
#   NOTARIZE       1 = notarise/staple/assess (default: 1)
#   APP_SRC        prebuilt .app to package   (default: unset, build one)
#   OUT_DIR        where the .dmg lands       (default: build/dist)
#   VERSION        version string             (default: git describe, no leading v)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="CoffeeBar"
VOLNAME="coffee-bar"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Carlos Eduardo Arango Gutierrez (85FN4Z37V8)}"
NOTARIZE="${NOTARIZE:-1}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/build/dist}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-coffeebar-app}"

die() { echo "error: $*" >&2; exit 1; }

# A timestamp needs a real certificate, so an ad-hoc identity cannot carry one.
# Releases always sign with the Developer ID and therefore always timestamp.
TS_FLAG="--timestamp"
[ "${SIGN_IDENTITY}" = "-" ] && TS_FLAG="--timestamp=none"

VERSION="${VERSION:-$(git -C "${REPO_ROOT}" describe --tags 2>/dev/null || true)}"
VERSION="${VERSION#v}"
[ -n "${VERSION}" ] || die "no version: not at a tag and VERSION is unset"

# --- staging, and a trap that cannot leave a volume mounted ------------------
#
# Run-scoped, because a fixed basename lets an earlier run's artifact be picked
# up silently. The mountpoint is explicit rather than /Volumes/coffee-bar: an
# already-mounted image of the same name would otherwise send `SetFile` at the
# wrong volume.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/coffee-bar-dmg.XXXXXX")"
STAGE="${WORK}/stage"
MNT="${WORK}/mnt"

# Detach unconditionally and ignore the result. Testing `mount` output first is
# what a careful reader reaches for and it is wrong twice over: the mountpoint is
# followed by " (" rather than a space, and $TMPDIR resolves through /private, so
# the printed path does not match the one we hold.
cleanup() {
    hdiutil detach "${MNT}" -force >/dev/null 2>&1 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT

# --- 1. the bundle ----------------------------------------------------------
if [ -n "${APP_SRC:-}" ]; then
    [ -d "${APP_SRC}" ] || die "APP_SRC is not a directory: ${APP_SRC}"
    APP="${APP_SRC}"
else
    echo "==> building the bundle"
    COFFEE_BAR_VERSION="${VERSION}" "${SCRIPT_DIR}/build-app.sh" || die "build-app.sh failed"
    APP="${REPO_ROOT}/build/${APP_NAME}.app"
fi
[ -d "${APP}" ] || die "no bundle at ${APP}"

# --- 2. sign NESTED FIRST, then the bundle ----------------------------------
#
# codesign on the bundle signs the main executable and SEALS everything else. A
# second Mach-O in Contents/MacOS is sealed but not signed, and notarisation
# rejects that before Gatekeeper sees it. Measured: signing the bundle while the
# nested binary is unsigned fails at sign time with "In subcomponent:".
# Every binary gets its own signature, the main executable included. Signing the
# bundle re-signs the main executable anyway, so this is redundant for it and
# harmless — and an explicit skip would be dead code that reads as if it matters.
[ -d "${APP}/Contents/MacOS" ] || die "no Contents/MacOS in ${APP}"
BIN_COUNT=0
for bin in "${APP}/Contents/MacOS"/*; do
    [ -f "${bin}" ] || die "Contents/MacOS holds no files; nothing to sign"
    echo "==> signing $(basename "${bin}")"
    codesign --force --options runtime ${TS_FLAG} --sign "${SIGN_IDENTITY}" "${bin}" \
        || die "cannot sign nested binary ${bin}"
    BIN_COUNT=$((BIN_COUNT + 1))
done
[ "${BIN_COUNT}" -ge 2 ] \
    || die "signed ${BIN_COUNT} binary; the bundle should carry coffee-bar and coffee-bar-probe"
echo "==> signing the bundle"
codesign --force --options runtime ${TS_FLAG} --sign "${SIGN_IDENTITY}" "${APP}" \
    || die "cannot sign ${APP}"

codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | tee "${WORK}/verify.txt" \
    || die "codesign --verify --deep --strict rejected ${APP}"
grep -q -- "--validated:.*coffee-bar-probe" "${WORK}/verify.txt" \
    || die "verification never validated coffee-bar-probe; the nested binary is not covered"

# --- 2b. notarise and staple the APP, before it is staged -------------------
#
# A SECOND Apple round-trip, and it is not optional. Notarising only the image
# leaves the app a user drags out of it without a ticket, so Gatekeeper has to
# ask Apple on first launch and an offline machine cannot. v0.1.1 stapled the
# app; v0.2.0 did not, and this restores it.
#
# The order matters more than the cost: the staged copy is taken from ${APP},
# so the app has to carry its ticket BEFORE `hdiutil create` reads it.
if [ "${NOTARIZE}" = "1" ]; then
    APP_ZIP="${WORK}/CoffeeBar.zip"
    # notarytool cannot take a bare .app. `ditto -c -k --keepParent` is the
    # documented shape; `zip -r` loses symlinks and extended attributes.
    ditto -c -k --keepParent "${APP}" "${APP_ZIP}" || die "cannot zip the app for notarisation"

    echo "==> submitting the app for notarisation (minutes, not seconds)"
    APP_SUBMIT_LOG="${WORK}/app-submit.txt"
    xcrun notarytool submit "${APP_ZIP}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait \
        > "${APP_SUBMIT_LOG}" 2>&1 || { cat "${APP_SUBMIT_LOG}"; die "notarytool submit failed for the app"; }
    cat "${APP_SUBMIT_LOG}"

    APP_SUBMISSION_ID="$(awk '/^ *id: /{print $2; exit}' "${APP_SUBMIT_LOG}")"
    [ -n "${APP_SUBMISSION_ID}" ] || die "cannot read the app submission id"

    APP_INFO_LOG="${WORK}/app-info.txt"
    xcrun notarytool info "${APP_SUBMISSION_ID}" --keychain-profile "${KEYCHAIN_PROFILE}" \
        > "${APP_INFO_LOG}" 2>&1 || { cat "${APP_INFO_LOG}"; die "notarytool info failed for the app"; }
    cat "${APP_INFO_LOG}"
    grep -q "status: Accepted" "${APP_INFO_LOG}" \
        || die "app notarisation is not Accepted for ${APP_SUBMISSION_ID}"

    xcrun stapler staple "${APP}" || die "stapler staple failed for the app"
    xcrun stapler validate "${APP}" || die "stapler validate failed for the app"
else
    echo "==> NOTARIZE=0: skipping app notarisation and stapling"
fi

# --- 3. stage the volume ----------------------------------------------------
mkdir -p "${STAGE}"
# `ditto`, not `cp -R`. Copying a SIGNED bundle has to preserve extended
# attributes and the resource layout; `cp -R` is not guaranteed to, and a
# signature that survives the copy by luck is a signature that breaks later.
ditto "${APP}" "${STAGE}/${APP_NAME}.app" || die "cannot stage the bundle"
ln -s /Applications "${STAGE}/Applications" || die "cannot create the Applications symlink"

ICON_SRC="${APP}/Contents/Resources/AppIcon.icns"
[ -s "${ICON_SRC}" ] || die "no non-empty AppIcon.icns in the bundle; the volume icon would be missing"
command cp "${ICON_SRC}" "${STAGE}/.VolumeIcon.icns" || die "cannot stage the volume icon"

# --- 4. read-write image, set the icon bit, then compress -------------------
#
# `hdiutil create -srcfolder` does NOT preserve the custom-icon flag: measured,
# a source folder with the bit set produces a volume with it clear. The flag has
# to be set on the MOUNTED volume, which means a read-write image first.
RW="${WORK}/rw.dmg"
hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" -ov -format UDRW "${RW}" >/dev/null \
    || die "hdiutil create failed"

mkdir -p "${MNT}"
hdiutil attach "${RW}" -nobrowse -mountpoint "${MNT}" >/dev/null || die "cannot attach ${RW}"
# Absolute paths: these two live in /usr/bin and are easy to shadow.
/usr/bin/SetFile -a C "${MNT}" || die "cannot set the custom-icon flag"
/usr/bin/GetFileInfo "${MNT}" | grep -q "avbstC" \
    || die "the custom-icon flag did not take on the staged volume"
hdiutil detach "${MNT}" >/dev/null || die "cannot detach ${MNT}"

mkdir -p "${OUT_DIR}"
DMG="${OUT_DIR}/coffee-bar-${VERSION}.dmg"
rm -f "${DMG}"
hdiutil convert "${RW}" -format UDZO -o "${DMG}" >/dev/null || die "hdiutil convert failed"

# The flag surviving `convert` is the whole point of the dance above. Verify it
# on the ARTIFACT, not on the staging tree.
hdiutil attach "${DMG}" -readonly -nobrowse -mountpoint "${MNT}" >/dev/null \
    || die "cannot attach the converted image"
/usr/bin/GetFileInfo "${MNT}" | grep -q "avbstC" \
    || die "the custom-icon flag did not survive the UDZO convert"
hdiutil detach "${MNT}" >/dev/null || die "cannot detach the converted image"

# --- 5. sign the image ------------------------------------------------------
codesign --force ${TS_FLAG} --sign "${SIGN_IDENTITY}" "${DMG}" || die "cannot sign ${DMG}"

# --- 6. notarise, staple, and ask Gatekeeper --------------------------------
#
# Skipped only under NOTARIZE=0, which is the suite. No release uses that path.
if [ "${NOTARIZE}" = "1" ]; then
    echo "==> submitting for notarisation (minutes, not seconds)"
    SUBMIT_LOG="${WORK}/submit.txt"
    xcrun notarytool submit "${DMG}" --keychain-profile "${KEYCHAIN_PROFILE}" --wait \
        > "${SUBMIT_LOG}" 2>&1 || { cat "${SUBMIT_LOG}"; die "notarytool submit failed"; }
    cat "${SUBMIT_LOG}"

    # `submit --wait` exits 0 for a submission Apple REJECTED. The id has to be
    # read back and the status confirmed, or an unnotarised image ships.
    SUBMISSION_ID="$(awk '/^ *id: /{print $2; exit}' "${SUBMIT_LOG}")"
    [ -n "${SUBMISSION_ID}" ] || die "cannot read the submission id from notarytool output"

    INFO_LOG="${WORK}/info.txt"
    xcrun notarytool info "${SUBMISSION_ID}" --keychain-profile "${KEYCHAIN_PROFILE}" \
        > "${INFO_LOG}" 2>&1 || { cat "${INFO_LOG}"; die "notarytool info failed"; }
    cat "${INFO_LOG}"
    grep -q "status: Accepted" "${INFO_LOG}" \
        || die "notarisation is not Accepted for ${SUBMISSION_ID}; see the log above"

    xcrun stapler staple "${DMG}" || die "stapler staple failed"
    xcrun stapler validate "${DMG}" || die "stapler validate failed"
    STAPLE_FACT='`xcrun stapler validate` passes'

    # Captured, not asserted. The Notarisation row states which source Gatekeeper
    # matched, and the only honest way to print that is to read it back from the
    # assessment this run performed.
    SPCTL_LOG="${WORK}/spctl.txt"
    spctl -a -t open --context context:primary-signature -vv "${DMG}" > "${SPCTL_LOG}" 2>&1 \
        || { cat "${SPCTL_LOG}"; die "Gatekeeper does not accept ${DMG}"; }
    cat "${SPCTL_LOG}"
    SPCTL_SOURCE="$(sed -n 's/^source=//p' "${SPCTL_LOG}" | head -1)"
    [ -n "${SPCTL_SOURCE}" ] \
        || die "spctl accepted ${DMG} but printed no source= line; cannot state the Notarisation row"
    NOTARISATION_FACT="\`spctl\` accepts it, source \`${SPCTL_SOURCE}\`"
else
    echo "==> NOTARIZE=0: skipping notarisation, stapling and assessment"
fi

# --- 7. the facts CHANGELOG.md requires -------------------------------------
#
# Printed from the ARTIFACT. CHANGELOG.md's header requires every claim be true
# of the shipped build, and the v0.1.1 entry carries the size and SHA-256.
SIZE="$(stat -f '%z' "${DMG}")"
SHA="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
ARCHS="$(lipo -archs "${STAGE}/${APP_NAME}.app/Contents/MacOS/coffee-bar" 2>/dev/null || echo unknown)"

# Read from Package.swift, never typed here. A second copy of the platform floor
# is a second thing to get wrong, and this one would be discovered by a user on
# an older macOS rather than by a test. `.v14` is SwiftPM's spelling; the string
# form `.macOS("14.1")` would not match, and an unreadable floor stops the
# release rather than printing a number nobody checked.
MIN_MACOS_MAJOR="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' "${REPO_ROOT}/Package.swift" | head -1)"
[ -n "${MIN_MACOS_MAJOR}" ] \
    || die "cannot read the macOS platform floor from ${REPO_ROOT}/Package.swift"
MIN_MACOS="${MIN_MACOS_MAJOR}.0"

# The eight rows `theReleaseFactsOnThePageAreTheOnesInTheChangelog` requires, in
# its order. Six of them hold for any run. The last two are claims about steps
# this run may not have taken, so they are printed only where they are true.
cat <<REPORT

Built ${DMG}

| Fact | Value |
|---|---|
| File | \`$(basename "${DMG}")\` |
| Size | ${SIZE} bytes |
| SHA-256 | \`${SHA}\` |
| Architecture | ${ARCHS} |
| Minimum macOS | ${MIN_MACOS} |
| Signature | Developer ID Application, team \`85FN4Z37V8\` |
REPORT

if [ "${NOTARIZE}" = "1" ]; then
    cat <<REPORT
| Notarisation | ${NOTARISATION_FACT} |
| Staple | ${STAPLE_FACT} |

REPORT
else
    cat <<REPORT

NOTARIZE=0: this run did not notarise or staple, so the Notarisation and Staple
rows are omitted rather than asserted. CHANGELOG.md needs all eight; take the
table from a release run.

REPORT
fi
