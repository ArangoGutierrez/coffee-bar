#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Signs an assembled CoffeeBar.app in place: every executable in Contents/MacOS
# first, the bundle last.
#
# Usage: scripts/sign-bundle.sh <path to .app>
#
#   SIGN_IDENTITY  codesign identity, skipping detection. `-` signs ad hoc.
#                  Unset (the normal case) means: find the Developer ID in the
#                  keychain, and if there is none, do not sign.
#
# SIGNING IS OPTIONAL AND DETECTED, and that is a deliberate decision rather
# than a shortcut. A contributor cloning this repository has no Developer ID
# Application certificate — the private key is the maintainer's and cannot be
# shared — and `.github/workflows/ci.yml` builds the bundle on a hosted runner
# that has no keychain identity either. A build that FAILS because the machine
# lacks a private key is a worse outcome than a build that produces an unsigned
# bundle and says so: the first breaks `git clone && scripts/build-app.sh` for
# everyone who is not the maintainer, the second costs a copy handed to another
# Mac, which was already the case.
#
# This is the LOCAL build. Releases are signed by `scripts/release-dmg.sh`,
# which re-signs everything with `--force` and a secure timestamp before it
# notarises. Two things follow, and neither is an oversight:
#
#   - No `--timestamp` here. Requesting one is `codesign`'s default for a
#     Developer ID and it contacts Apple's timestamp authority, so every local
#     build would need the network and an offline one would fail. Measured
#     2026-08-14: signing with no timestamp flag at all still produced
#     `Timestamp=14. Aug 2026 at 07:21:24`, so the flag has to be passed
#     explicitly to opt OUT. A local signature is not notarised anyway, and the
#     release path asks for its own timestamp.
#   - No notarisation and no stapling. Both need Apple credentials and upload
#     the bundle; they belong to the release script.

set -euo pipefail

APP="${1:-}"
[ -n "${APP}" ] || { echo "usage: $(basename "$0") <path to .app>" >&2; exit 2; }

die() {
    echo "error: $*" >&2
    exit 1
}

[ -d "${APP}" ] || die "no bundle at ${APP}"
[ -d "${APP}/Contents/MacOS" ] || die "no Contents/MacOS in ${APP}"

# --- which identity, if any --------------------------------------------------
#
# `security` is called by NAME rather than by absolute path, so a test can put a
# stand-in earlier on PATH and exercise the machine-with-no-identity case
# without touching the keychain. Nothing here writes to the keychain; the only
# question asked of it is which identities exist.
#
# `find-identity` exits 0 and prints "0 valid identities found" when there are
# none, so the exit code answers nothing and the output is what gets parsed. The
# `|| true` covers `set -o pipefail`: `head` closing the pipe early makes `sed`
# fail, and on a machine with no `security` at all the answer is still "no
# identity" rather than a failed build.
#
# Developer ID Application specifically. `security find-identity -p codesigning`
# also lists `Apple Development` certificates, which sign for a device during
# development and are refused for distribution — signing with one would produce
# a bundle that looks signed and is useless to anybody else.
detect_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/^ *[0-9][0-9]*) [0-9A-Fa-f]* "\(Developer ID Application:.*\)"$/\1/p' \
        | head -1 || true
}

IDENTITY="${SIGN_IDENTITY:-$(detect_identity)}"

if [ -z "${IDENTITY}" ]; then
    cat <<'UNSIGNED'
    no Developer ID Application identity in this keychain: the bundle is UNSIGNED.

    It runs on this machine. A copy handed to another Mac arrives carrying
    com.apple.quarantine, and Gatekeeper refuses to open an unsigned app that
    has it. Notarisation needs a signature too, so that route is closed as well.

    This is expected on a contributor's machine and on CI, and it is not an
    error. `security find-identity -v -p codesigning` lists what this machine
    has.
UNSIGNED
    exit 0
fi

# --- sign, NESTED FIRST, then the bundle -------------------------------------
#
# `codesign` on a bundle signs the main executable and SEALS everything else, so
# a second Mach-O in Contents/MacOS is covered by the seal without carrying a
# signature of its own. Measured 2026-08-14 on a two-binary fixture: with only
# the bundle signed, `codesign --verify --deep --strict` returns rc=0 while the
# nested binary still holds the linker's signature and names no team.
# Notarisation refuses that bundle before Gatekeeper ever sees it.
#
# The ORDER is the other half. Signing a nested binary after the bundle changes
# a file the bundle's seal covers: measured on the same fixture,
# `codesign --verify --deep --strict` then returns rc=1, "nested code is
# modified or invalid".
#
# The main executable is signed by this loop AND again by the bundle. That is
# redundant and harmless; an explicit skip would be dead code reading as if the
# distinction mattered.
#
# `--force` because every binary arrives already signed — `swift build` emits
# arm64 Mach-Os the linker has ad-hoc signed, `flags=0x20002(adhoc,linker-signed)`
# — and `codesign` refuses to replace a signature without it.
#
# `--options runtime` enables the hardened runtime, which notarisation requires
# and which #71b will need.
TS_FLAG="--timestamp=none"

signed=0
for bin in "${APP}/Contents/MacOS"/*; do
    [ -f "${bin}" ] || die "Contents/MacOS holds no regular file at ${bin}; nothing to sign"
    codesign --force --options runtime "${TS_FLAG}" --sign "${IDENTITY}" "${bin}" \
        || die "cannot sign nested binary ${bin}"
    signed=$((signed + 1))
    echo "    signed $(basename "${bin}")"
done
[ "${signed}" -gt 0 ] || die "signed nothing; ${APP}/Contents/MacOS is empty"

codesign --force --options runtime "${TS_FLAG}" --sign "${IDENTITY}" "${APP}" \
    || die "cannot sign ${APP}"
echo "    signed the bundle"

# --- read the signature back off the bundle ----------------------------------
#
# The exit code of `codesign --sign` is not evidence: this repository already
# carries an interactive-alias `cp` no-op and a `cp -R` that nested into a
# subdirectory, both at exit 0. Every claim below is read from the artifact.
codesign --verify --deep --strict --verbose=2 "${APP}" \
    || die "codesign --verify --deep --strict rejected the bundle this run just signed"

# …and the bundle's verification is NOT enough on its own, per the measurement
# above: it returns 0 for a bundle whose nested binary was merely sealed. Ask
# each binary what it carries. The hardened-runtime flag is the discriminator
# that works for an ad-hoc identity as well as a Developer ID one, because the
# linker never sets it.
#
# Captured first and matched with a HERESTRING, never `codesign … | grep -q`.
# Measured 2026-08-14: that pipe fails a correctly signed binary. `grep -q`
# exits at the first match, `codesign` dies of SIGPIPE with status 141, and
# `set -o pipefail` reports the pipeline as failed — so the check aborted a run
# whose main executable really did carry `flags=0x10002(adhoc,runtime)`.
for bin in "${APP}/Contents/MacOS"/*; do
    report="$(codesign -dv --verbose=4 "${bin}" 2>&1 || true)"
    grep -q "flags=.*runtime" <<<"${report}" \
        || die "$(basename "${bin}") has no hardened-runtime flag after signing; it is sealed rather than signed"
done

TEAM="$(codesign -dv --verbose=4 "${APP}" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
if [ -n "${TEAM}" ] && [ "${TEAM}" != "not set" ]; then
    echo "    Developer ID signature, team ${TEAM}"
else
    echo "    ad-hoc signature: this bundle names no team and Gatekeeper will refuse a copy"
fi
