#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Assembles build/CoffeeBar.app from the SwiftPM products named in PRODUCTS. No
# .xcodeproj is involved and none is needed — SwiftPM builds the SwiftUI
# MenuBarExtra fine and the bundle is assembled by hand.
#
# The bundle this produces is unsigned unless you ask for a signature by setting
# SIGN_IDENTITY; `scripts/sign-bundle.sh` records why signing is opt-in rather
# than detected, and this script is the reason — it is also the Homebrew
# formula's build path. Notarisation and Sparkle remain release work, so even a
# signed bundle from here is quarantined on another Mac until
# `scripts/release-dmg.sh` notarises one.
#
# Usage: scripts/build-app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The bundle's executable, named separately because Info.plist's
# CFBundleExecutable is what macOS launches and only one binary can be it.
PRODUCT="coffee-bar"

# Everything that lands in Contents/MacOS/, `PRODUCT` first.
#
# `coffee-bar-probe` joined it for issue #64. Lid-closed mode's only entry point
# is `sudo …/coffee-bar-probe arm`, `Sources/CoffeeBarProbe/main.swift`
# implements `.arm` against a real ArmService, and the bundle shipped without the
# binary — so the feature was reachable only by building from source, which is a
# strange thing to tell somebody who just installed a signed disk image.
#
# It is NOT on the user's PATH and this script does not put it there. Placing a
# symlink in /usr/local/bin needs a privileged step, and `coffee-bar never
# elevates its own privilege` (design §6). The documents print the path inside
# the bundle instead, and `theBundleTheScriptAssemblesCarriesTheProbe` holds them
# to the layout this script builds.
#
# SIGNING: every one of these needs its own signature. `codesign` on the bundle
# signs the main executable and seals the rest; a second Mach-O in Contents/MacOS
# is not covered by that and Gatekeeper rejects the bundle if it is unsigned.
# Sign the nested binaries first, then the bundle. `scripts/sign-bundle.sh` is
# where that happens, and `BundleSigning_test.swift` measures both halves.
PRODUCTS=(coffee-bar coffee-bar-probe)

APP_NAME="CoffeeBar"
BUNDLE_ID="com.coffeebar.app"

# The registered helper (#71). Three spellings of one name, all literal.
#
# `PrivilegedHelperIdentity` is the Swift side — what the app registers, dials
# and PINS — and no compiler crosses the boundary between it and this heredoc.
# `theDaemonPlistAgreesWithTheAppOnEveryName` reads both ends and holds them
# together, which is the only thing that can: a plist naming
# `com.coffeebar.helper` while the app registers `com.coffeebar.probehelper`
# builds cleanly, keeps the suite green, and fails only on a SIGNED install.
#
# Written as literals rather than composed from each other so the Swift check
# can find each string. A `${HELPER_IDENTIFIER}.plist` would be correct and
# invisible to it.
HELPER_LABEL="com.coffeebar.probehelper"
HELPER_PLIST="com.coffeebar.probehelper.plist"
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
#
# `--abbrev=0` is deliberately ABSENT. It prints the bare tag name and drops the
# commit distance, so every build descended from a tag reported itself AS that
# tag: a build 16 commits past v0.1.1 displayed "Version 0.1.1". At a tagged
# commit `git describe --tags` still returns exactly that tag, so a release is
# unaffected; only descendants gain the `-<n>-g<sha>` suffix. `--dirty` marks an
# uncommitted tree, because a build from modified sources is not the commit it
# names.
VERSION_RAW="${COFFEE_BAR_VERSION:-$(git -C "${REPO_ROOT}" describe --tags --dirty 2>/dev/null || true)}"
VERSION="${VERSION_RAW#v}"
VERSION="${VERSION:-0.0.0-dev}"

if [ -n "${COFFEE_BAR_VERSION:-}" ]; then
    echo "==> version ${VERSION} (from COFFEE_BAR_VERSION)"
elif [ -n "${VERSION_RAW}" ]; then
    echo "==> version ${VERSION} (from git describe ${VERSION_RAW})"
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

for product in "${PRODUCTS[@]}"; do
    echo "==> swift build -c release --product ${product} ${SWIFT_FLAGS}"
    swift build -c release --product "${product}" --package-path "${REPO_ROOT}" ${SWIFT_FLAGS}
done

# One bin path for all of them: every product of one package in one
# configuration lands in the same directory, so this is asked once.
BIN_DIR="$(swift build -c release --product "${PRODUCT}" --package-path "${REPO_ROOT}" ${SWIFT_FLAGS} --show-bin-path)"
for product in "${PRODUCTS[@]}"; do
    [ -x "${BIN_DIR}/${product}" ] || die "release binary not found at ${BIN_DIR}/${product}"
done

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
for product in "${PRODUCTS[@]}"; do
    command cp -f "${BIN_DIR}/${product}" "${CONTENTS}/MacOS/${product}"
    [ -x "${CONTENTS}/MacOS/${product}" ] || die "${product} did not land in the bundle"
    echo "    ${product} copied into Contents/MacOS/"
done

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

# --- app icon ---------------------------------------------------------------
#
# The bundle carried no icon at all until now, so Finder drew the generic one.
#
# `iconutil` is used rather than `actool` deliberately. `actool` is the shared
# xcrun shim and needs a full Xcode: `DEVELOPER_DIR=/nonexistent actool
# --version` fails with "missing DEVELOPER_DIR path". `iconutil` is a real
# binary and still runs without one. The Homebrew formula builds from a tarball
# on machines that may carry only the Command Line Tools, so requiring Xcode
# here would break install for those users.
#
# The iconset is COPIED before use. `assets/art/appicon/make-icns.sh` renames
# `-2x` to `@2x` in place, and a build must never mutate the tracked tree.

ICONSET_SRC="${REPO_ROOT}/assets/art/appicon/AppIcon.iconset"
[ -d "${ICONSET_SRC}" ] || die "iconset not found at ${ICONSET_SRC}"

ICON_TMP="$(mktemp -d)"
trap 'rm -rf "${ICON_TMP}"' EXIT

command cp -R "${ICONSET_SRC}" "${ICON_TMP}/AppIcon.iconset"

# The export pipeline strips `@` from filenames (assets/art/README.md). iconutil
# requires it back. Rename inside the COPY.
for f in "${ICON_TMP}/AppIcon.iconset"/*-2x.png; do
    [ -f "${f}" ] || continue
    mv "${f}" "${f%-2x.png}@2x.png"
done

iconutil -c icns "${ICON_TMP}/AppIcon.iconset" -o "${CONTENTS}/Resources/AppIcon.icns" \
    || die "iconutil failed to build AppIcon.icns"

# `iconutil` can report success and write nothing useful.
[ -s "${CONTENTS}/Resources/AppIcon.icns" ] \
    || die "AppIcon.icns is missing or empty in the bundle"
echo "    app icon: $(wc -c <"${CONTENTS}/Resources/AppIcon.icns" | tr -d ' ') bytes"

# `-s` proves only that bytes exist. An iconset missing its large sizes still
# produces a VALID .icns, and the app then ships a blurry icon that nothing
# catches. 1024 is the size Finder and the App Switcher actually reach for.
#
# `sips` exits 0 on a missing or corrupt file and prints nothing, so the empty
# string — not a non-zero status — is what reaches the comparison below. That
# is why this reads the VALUE back rather than gating on the exit code.
icon_px="$(sips -g pixelWidth "${CONTENTS}/Resources/AppIcon.icns" 2>/dev/null \
    | awk '/pixelWidth:/ {print $2}')"
[ "${icon_px}" = "1024" ] \
    || die "AppIcon.icns reports pixelWidth '${icon_px}', expected 1024"
echo "    app icon: 1024x1024"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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

# -lint accepts any well-formed plist, so read the icon key back explicitly.
icon_file="$(plutil -extract CFBundleIconFile raw -o - "${CONTENTS}/Info.plist")"
[ "${icon_file}" = "AppIcon" ] || die "CFBundleIconFile is '${icon_file}', expected AppIcon"
echo "    CFBundleIconFile=AppIcon"

# --- the registered helper's launchd job (#71) --------------------------------
#
# `SMAppService.daemon(plistName:)` takes neither a path nor a dictionary: macOS
# reads this file out of Contents/Library/LaunchDaemons INSIDE the app bundle
# and verifies it against the bundle's signature. Nowhere else will do, and no
# Swift check in the package can see whether the file arrived — which is why
# `BuildScriptDaemonPlist_test.swift` exists.
#
# BEFORE the signature, like everything else in Contents: `codesign` on the
# bundle seals this directory, and a file added afterwards leaves a bundle whose
# signature no longer matches its contents — a break that shows up on somebody
# else's Mac rather than here.
#
# An UNSIGNED bundle gets this file too, and deliberately. It is inert there —
# `SMAppService` refuses to register a job it cannot verify, and
# `HelperAvailability` reads the running signature and does not offer the button
# at all — so writing it unconditionally keeps one bundle layout rather than
# two, and keeps the signed and Homebrew builds differing only in the
# signature.
#
# RunAtLoad and KeepAlive are load-bearing for the same reason they are on the
# CLI watchdog: this job SUPERVISES a hold it granted. A SIGKILLed helper must
# come back, and its first act on restart is to evaluate the journal — which is
# what bounds a live hold when the process that granted it has gone.
echo "==> daemon plist for ${HELPER_LABEL}"
mkdir -p "${CONTENTS}/Library/LaunchDaemons"
cat >"${CONTENTS}/Library/LaunchDaemons/${HELPER_PLIST}" <<HELPERPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${HELPER_LABEL}</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/coffee-bar-probe</string>
    <key>ProgramArguments</key>
    <array>
        <string>Contents/MacOS/coffee-bar-probe</string>
        <string>serve</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>${HELPER_LABEL}</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>${BUNDLE_ID}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
HELPERPLIST

plutil -lint "${CONTENTS}/Library/LaunchDaemons/${HELPER_PLIST}" \
    || die "the helper plist failed plutil -lint"

# -lint accepts any well-formed plist, and a heredoc that lost its Label key is
# well-formed. Read back the key launchd and SMAppService both key on.
helper_label="$(plutil -extract Label raw -o - \
    "${CONTENTS}/Library/LaunchDaemons/${HELPER_PLIST}")"
[ "${helper_label}" = "${HELPER_LABEL}" ] \
    || die "the helper plist's Label is '${helper_label}', expected ${HELPER_LABEL}"
echo "    Contents/Library/LaunchDaemons/${HELPER_PLIST} (Label=${helper_label})"

# --- what actually shipped ----------------------------------------------------
#
# Issue #64: the documents tell a user to run a binary out of this directory, and
# for a whole milestone the binary was not in it. Every check above this line
# asks whether a step SUCCEEDED; this one asks what the directory now HOLDS, and
# those are different questions. `command cp` returning 0 is not evidence the
# byte landed — this repository already carries an interactive-alias no-op and a
# `cp -R` that nested into a subdirectory, both at exit 0.
#
# EXACT set equality, not containment. Containment passes over a bundle carrying
# a stale binary from a rename, and a second Mach-O in Contents/MacOS is a second
# thing the maintainer has to sign; one that nobody knew was there is one that
# does not get signed, and Gatekeeper then rejects the whole bundle.
#
# `theBundleTheScriptAssemblesCarriesTheProbe` holds PRODUCTS against what the
# documents print. This holds the built bundle against PRODUCTS. Neither reaches
# both ends alone.
# `printf '%s\n' *` in a subshell rather than `ls`: the glob is what the
# directory holds, and a failed `cd` short-circuits the `&&` to an empty string,
# which fails the comparison below rather than passing it.
shipped="$(cd "${CONTENTS}/MacOS" && printf '%s\n' * | sort | tr '\n' ' ')"
expected="$(printf '%s\n' "${PRODUCTS[@]}" | sort | tr '\n' ' ')"
[ "${shipped}" = "${expected}" ] \
    || die "Contents/MacOS holds '${shipped}', expected '${expected}'"
echo "    Contents/MacOS: ${shipped}"

# --- signature ---------------------------------------------------------------
#
# LAST, and it has to be last: a bundle signature seals Contents/Resources, so
# the glyphs, the LICENCE, the icon and Info.plist all have to be in place
# before this runs. Anything copied in afterwards invalidates the signature
# while leaving the file present, which is the kind of break that shows up on
# somebody else's Mac rather than here.
#
# OPT-IN by design — no SIGN_IDENTITY means an unsigned bundle and exit 0, never
# a failed build and never a reach into the keychain for somebody else's key.
# This script is the Homebrew formula's build path, so an unset variable has to
# mean "sign nothing". `scripts/sign-bundle.sh` carries that argument in full.
echo "==> signing"
"${SCRIPT_DIR}/sign-bundle.sh" "${APP}" || die "signing failed"

# What the artifact IS, read back off it, rather than what this script believes
# it did. The line used to say "unsigned" unconditionally, and that was true
# until the step above existed; printing it from a variable set by the signing
# branch would make the same mistake in a new place.
signature_team="$(codesign -dv --verbose=4 "${APP}" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
if [ -n "${signature_team}" ] && [ "${signature_team}" != "not set" ]; then
    SIGNATURE="signed, team ${signature_team}"
else
    SIGNATURE="unsigned"
fi

# --- done --------------------------------------------------------------------

cat <<DONE

Built ${APP} (version ${VERSION}, ${SIGNATURE})

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
