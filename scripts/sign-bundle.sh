#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Signs an assembled CoffeeBar.app in place: every executable in Contents/MacOS
# first, the bundle last.
#
# Usage: scripts/sign-bundle.sh <path to .app>
#
#   SIGN_IDENTITY  codesign identity to sign with. `-` signs ad hoc.
#                  Unset (the normal case) means: do not sign at all.
#
# SIGNING IS OPT-IN, and that is the load-bearing decision here. Nothing else in
# this script matters as much.
#
# `scripts/build-app.sh` calls this, and `build-app.sh` is ALSO the Homebrew
# formula's build path. An earlier version of this file resolved the identity as
# `${SIGN_IDENTITY:-$(detect_identity)}`, so an unset variable meant "find a
# Developer ID in this keychain and use it". The formula sets no SIGN_IDENTITY.
# The result: `brew install coffee-bar` on any machine that happens to hold a
# Developer ID ran `codesign --sign <that person's private key>` over a bundle
# they were merely installing. Measured on the fixture bundle before this change,
# with nothing in the environment: `TeamIdentifier=85FN4Z37V8`. Nobody asked for
# that signature.
#
# A script that runs on other people's machines does not reach for a signing key
# without being asked, and `brew install` is the path most likely to reach a
# stranger. It also falsifies a written promise: `SECURITY.md` states, under
# "Things that are not vulnerabilities", that a Homebrew-installed bundle is
# ad-hoc signed and names no team.
#
# So an unset SIGN_IDENTITY leaves the bundle exactly as `swift build` emitted
# it — ad-hoc, linker-signed, naming no team — and exits 0. That is also the
# right default for the two cases that were already normal: a contributor
# cloning this repository has no Developer ID Application certificate, because
# the private key is the maintainer's and cannot be shared, and
# `.github/workflows/ci.yml` builds the bundle on a hosted runner with no
# keychain identity at all. A build that FAILS for want of a private key breaks
# `git clone && scripts/build-app.sh` for everyone who is not the maintainer.
#
# There is no `--sign` flag, deliberately. `build-app.sh` takes no arguments and
# forwards none, so a flag would be reachable only by calling this script
# directly — a second opt-in surface with no caller. A bare `--sign` would also
# have to pick an identity on the user's behalf, which is the question opt-in
# exists to stop answering. SIGN_IDENTITY already crosses the build-app.sh
# boundary with no plumbing; when #71b needs a flag, adding one is cheap.
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
# REPORTING ONLY. `detect_identity` answers "what could this machine sign with",
# which is what the opt-in message needs so it can name an identity the reader
# can paste back. It is NOT how the identity is chosen — that is SIGN_IDENTITY
# and nothing else. Reading which certificates exist and signing with one are
# different acts, and only the second needs consent.
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

# SIGN_IDENTITY and nothing else. There is no fallback to `detect_identity`
# here, and the absence is the fix: see the opening comment.
IDENTITY="${SIGN_IDENTITY:-}"

if [ -z "${IDENTITY}" ]; then
    cat <<'UNSIGNED'
    SIGN_IDENTITY is unset, so this bundle is UNSIGNED. Signing is OPT-IN: this
    script does not reach for a signing key it was not asked to use.

    The bundle runs on the machine that built it. A copy handed to another Mac
    arrives carrying com.apple.quarantine, and Gatekeeper refuses to open an
    unsigned app that has it. Notarisation needs a signature too, so that route
    is closed as well.

    This is the normal case for a contributor, for CI and for a Homebrew
    install, and it is not an error.
UNSIGNED

    # What this machine COULD sign with, so opting in is a paste rather than a
    # lookup. Read-only, and it chooses nothing.
    available="$(detect_identity)"
    if [ -n "${available}" ]; then
        printf "\n    To sign with the identity already in this keychain, ask for it:\n\n        SIGN_IDENTITY='%s' scripts/build-app.sh\n\n" "${available}"
    else
        printf "\n    To sign, set SIGN_IDENTITY to a codesign identity. This keychain holds\n    no Developer ID Application certificate; \`security find-identity -v -p\n    codesigning\` lists what it does have, and SIGN_IDENTITY='-' signs ad hoc.\n\n"
    fi
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
