<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0
-->

# Reproducible DMG Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `scripts/release-dmg.sh`, which turns a clean tagged tree into a signed, notarised, stapled `coffee-bar-<version>.dmg` and prints the size and SHA-256 the CHANGELOG requires.

**Architecture:** One shell script following `scripts/build-app.sh`'s conventions, parameterised so its offline core executes under test. One Swift test file: real assertions against a DMG the script actually produced from a fixture bundle, plus text-read guards for the steps that need Apple credentials and cannot run in CI.

**Tech Stack:** bash, `hdiutil`, `codesign`, `SetFile`, `xcrun notarytool`, `xcrun stapler`, `spctl`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-09-dmg-tooling-design.md`

## Global Constraints

- Worktree: `.worktrees/45-dmg-tooling`, branch `feat/45-dmg-tooling`, based at `2c1d379`. Always use `git -C` — `cd` does not persist between tool calls.
- `swift build` MUST run before `swift test`; `swift test` does not compile the `CoffeeBarProbe` executable target.
- Both need the sandbox DISABLED and a `--scratch-path`. SwiftPM's own sandbox-exec cannot nest and misreports the failure as `Invalid manifest`.
- Baseline is `889 tests in 11 suites`. Three tests are known load-sensitive flakes: `DemotionCrashPath_test.swift:196`, `DemotionCrashPath_test.swift:242`, `SleepDisabledController_test.swift:366`. Judge any failure among them by an isolated `--filter` run before treating it as a regression.
- Every commit is signed: `git commit -s -S`.
- Shell scripts use `#!/bin/bash`, the Apache-2.0 header, `set -euo pipefail`, and a `die()` helper, matching `scripts/build-app.sh`.
- `build/` is gitignored, so build output never appears in `git status`.
- Do NOT redefine `repoRoot()`. It is internal in `Tests/CoffeeBarCoreTests/DocsClaims_test.swift:41` and shared across the `CoffeeBarCoreTests` module; a second definition is a redeclaration error.
- Do NOT push, open a PR, or run any `gh` command. The orchestrator owns every outward action.

## File Structure

| File | Responsibility |
|---|---|
| Create `scripts/release-dmg.sh` | the whole local release pipeline, from a clean tagged tree to a verified artifact |
| Create `Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift` | executed assertions against a produced DMG, plus text guards for the credential-dependent steps |

---

### Task 1: The offline core — staging, signing, and the disk image

Produces a signed DMG with the correct layout and an effective volume icon. Everything in this task runs without network or Apple credentials, which is what makes it testable.

**Files:**
- Create: `scripts/release-dmg.sh`
- Test: `Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift`

**Interfaces:**
- Consumes: `scripts/build-app.sh` (invoked when `APP_SRC` is unset); `repoRoot()` from `DocsClaims_test.swift:41`.
- Produces: `${OUT_DIR}/coffee-bar-${VERSION}.dmg`. Environment contract used by Task 2 and by the test: `SIGN_IDENTITY` (default the Developer ID string), `NOTARIZE` (default `1`), `APP_SRC` (default unset), `OUT_DIR` (default `${REPO_ROOT}/build/dist`), `VERSION` (default from `git describe --tags`, leading `v` stripped).

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation

/// Holds `scripts/release-dmg.sh` to the layout v0.1.1 shipped.
///
/// **This test EXECUTES the script.** It builds a fixture bundle from `/bin/echo`
/// — a real Mach-O, so `codesign` behaves as it does on the real product — signs
/// it ad-hoc, and asserts against the disk image the script actually wrote. A
/// text-reading guard could not catch either bug named below, because both are
/// about what the tools DO, not what the script says.
///
/// The steps that need Apple credentials (notarise, staple, spctl) cannot run
/// here. They are covered by the text guards in Task 2, and by the real release
/// run, whose output goes in the CHANGELOG.

private func releaseDmgScript() -> URL {
    repoRoot().appending(path: "scripts/release-dmg.sh")
}

/// Runs a command and returns its exit code and combined output.
///
/// Reads the pipe BEFORE waiting. Waiting first deadlocks as soon as the output
/// outgrows the pipe buffer, which `hdiutil` output does.
@discardableResult
private func run(_ args: [String], env extra: [String: String] = [:]) throws -> (rc: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    for (k, v) in extra { env[k] = v }
    p.environment = env

    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A minimal but REAL app bundle: two genuine Mach-O executables, an Info.plist,
/// and a non-empty icon file.
///
/// The icon's CONTENT is irrelevant — the script only copies it, and what is
/// under test is whether the custom-icon FLAG survives image creation. A dummy
/// file keeps the fixture free of `iconutil`.
private func makeFixtureApp(at root: URL) throws {
    let macOS = root.appending(path: "Contents/MacOS")
    let resources = root.appending(path: "Contents/Resources")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

    for name in ["coffee-bar", "coffee-bar-probe"] {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: macOS.appending(path: name))
    }
    try Data("icon".utf8).write(to: resources.appending(path: "AppIcon.icns"))
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>coffee-bar</string>
    <key>CFBundleIdentifier</key><string>com.coffeebar.fixture</string>
    <key>CFBundleName</key><string>CoffeeBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>9.9.9</string>
    </dict></plist>
    """.write(to: root.appending(path: "Contents/Info.plist"), atomically: true, encoding: .utf8)
}

/// Builds a DMG from a fixture and hands the caller the mounted volume.
private func withProducedImage(_ body: (URL, URL) throws -> Void) throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "cb-releasedmg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let app = tmp.appending(path: "CoffeeBar.app")
    try makeFixtureApp(at: app)

    let out = tmp.appending(path: "dist")
    let r = try run([releaseDmgScript().path],
                    env: ["SIGN_IDENTITY": "-",
                          "NOTARIZE": "0",
                          "APP_SRC": app.path,
                          "OUT_DIR": out.path,
                          "VERSION": "9.9.9"])
    #expect(r.rc == 0, "release-dmg.sh exited \(r.rc):\n\(r.out)")

    let dmg = out.appending(path: "coffee-bar-9.9.9.dmg")
    #expect(FileManager.default.fileExists(atPath: dmg.path),
            "release-dmg.sh exited 0 but wrote no coffee-bar-9.9.9.dmg:\n\(r.out)")

    let mount = tmp.appending(path: "mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let attach = try run(["hdiutil", "attach", dmg.path, "-readonly", "-nobrowse",
                          "-mountpoint", mount.path])
    #expect(attach.rc == 0, "cannot attach the produced image:\n\(attach.out)")
    defer { _ = try? run(["hdiutil", "detach", mount.path, "-force"]) }

    try body(dmg, mount)
}

@Test func theImageCarriesTheLayoutThatShipped() throws {
    try withProducedImage { dmg, mount in
        // Named bug: `hdiutil create -srcfolder` drops the custom-icon bit, so a
        // one-shot build ships a generic-icon disk image while exiting 0. The
        // source folder having the flag is NOT enough; only the produced volume
        // counts, which is why this reads the mounted image.
        let info = try run(["/usr/bin/GetFileInfo", mount.path])
        #expect(info.out.contains("avbstC"),
                "the produced volume has no custom-icon flag; Finder will draw the generic icon:\n\(info.out)")

        // Named bug: the Applications symlink is dropped or points somewhere
        // else, so the user cannot drag-install and the image looks broken.
        let link = try FileManager.default.destinationOfSymbolicLink(
            atPath: mount.appending(path: "Applications").path)
        #expect(link == "/Applications", "the Applications symlink points at \(link)")

        // Named bug: a stale binary from a rename rides along unsigned. EXACT
        // set equality for the reason build-app.sh:350 already gives.
        let shipped = try FileManager.default.contentsOfDirectory(
            atPath: mount.appending(path: "CoffeeBar.app/Contents/MacOS").path).sorted()
        #expect(shipped == ["coffee-bar", "coffee-bar-probe"],
                "Contents/MacOS holds \(shipped)")

        let verify = try run(["hdiutil", "verify", dmg.path])
        #expect(verify.rc == 0, "hdiutil verify failed:\n\(verify.out)")
    }
}

@Test func theNestedBinaryIsSignedBeforeTheBundle() throws {
    try withProducedImage { _, mount in
        // Named bug: the bundle is signed before the nested probe. codesign then
        // SEALS an unsigned Mach-O, and notarisation rejects the whole bundle
        // before Gatekeeper ever sees it. Measured: with the nested signature
        // missing this returns rc=1, "code object is not signed at all".
        let app = mount.appending(path: "CoffeeBar.app").path
        let v = try run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
        #expect(v.rc == 0, "codesign --verify --deep --strict failed:\n\(v.out)")
        #expect(v.out.contains("coffee-bar-probe"),
                "verification never mentions coffee-bar-probe, so the nested binary was not covered:\n\(v.out)")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
WT=/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar/.worktrees/45-dmg-tooling
swift build --package-path "$WT" --scratch-path /tmp/cb-dmg-scratch
swift test --package-path "$WT" --scratch-path /tmp/cb-dmg-scratch \
  --filter 'theImageCarriesTheLayoutThatShipped|theNestedBinaryIsSignedBeforeTheBundle'
```

Sandbox DISABLED. Expected: FAIL. `scripts/release-dmg.sh` does not exist, so `/usr/bin/env` exits non-zero and the `r.rc == 0` expectation reports the exit code.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/release-dmg.sh`, `chmod +x`:

```bash
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

echo "==> built ${DMG}"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
WT=/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar/.worktrees/45-dmg-tooling
swift build --package-path "$WT" --scratch-path /tmp/cb-dmg-scratch
swift test --package-path "$WT" --scratch-path /tmp/cb-dmg-scratch \
  --filter 'theImageCarriesTheLayoutThatShipped|theNestedBinaryIsSignedBeforeTheBundle'
```

Expected: both PASS. Paste the output into the task report.

- [ ] **Step 5: Prove the guards discriminate**

A guard that stays green without its subject is theater. Mutate, observe RED, revert. Print the diff of each mutation so the report shows the mutant applied and changed only its subject.

1. Replace the whole read-write dance (create UDRW through the convert) with a single `hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"`. Expected: `theImageCarriesTheLayoutThatShipped` FAILS on the custom-icon flag.
2. Move the bundle `codesign` line ABOVE the nested loop. Expected: RED — the script's own `die` fires, or `theNestedBinaryIsSignedBeforeTheBundle` fails.

Revert both. Re-run and confirm GREEN again.

- [ ] **Step 6: Commit**

```bash
WT=/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar/.worktrees/45-dmg-tooling
git -C "$WT" add scripts/release-dmg.sh Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift
git -C "$WT" commit -s -S -m 'feat(release): build the disk image from a script

Measured: hdiutil create -srcfolder drops the custom-icon bit, so the
one-shot path ships a generic-icon image while exiting 0. The flag has to
be set on a mounted read-write volume and survives the UDZO convert.

The test executes the script against a fixture built from /bin/echo — a
real Mach-O, so codesign behaves as it does on the product — and asserts
on the image produced, not on the text of the script.

Refs #45'
```

---

### Task 2: Notarisation, verification, and the CHANGELOG report

Adds the steps that need Apple credentials, and the text guards that hold them in place. Reviewable independently: Task 1's artifact is already correct without this, and this changes nothing Task 1 asserts.

**Files:**
- Modify: `scripts/release-dmg.sh` (append after the image-signing step)
- Modify: `Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift` (append)

**Interfaces:**
- Consumes: `${DMG}`, `${NOTARIZE}`, `${KEYCHAIN_PROFILE}` from Task 1.
- Produces: stdout block containing `File`, `Size`, `SHA-256`, `Architecture`, `Team`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift`:

```swift
/// Guards the steps that CANNOT execute here.
///
/// Notarisation needs an Apple ID, a keychain profile and the network. These
/// assertions therefore read the script as text, exactly as
/// `BundleLicence_test.swift` and `BuildScriptVersion_test.swift` do. Each one
/// names the bug it catches, and each was checked by deleting the line it
/// asserts and observing this test go red.
@Test func theScriptConfirmsNotarisationRatherThanTrustingTheExitCode() throws {
    let s = try String(contentsOf: releaseDmgScript(), encoding: .utf8)

    // Named bug: `notarytool submit` exits 0 for a submission Apple REJECTED.
    // Shipping on the exit code alone publishes an unnotarised image that
    // Gatekeeper blocks on every machine but the one that built it.
    #expect(s.contains("notarytool submit"), "the script no longer submits for notarisation")
    #expect(s.contains("notarytool info"),
            "the script trusts `notarytool submit`'s exit code; exit 0 does not mean Accepted")
    #expect(s.contains("Accepted"),
            "the script never checks for the Accepted status")

    // Named bug: the ticket is never stapled, so the image needs a network
    // round-trip to Apple at first launch and fails offline.
    #expect(s.contains("stapler staple"), "the script no longer staples the ticket")
    #expect(s.contains("stapler validate"), "the script staples without validating the result")

    // Named bug: nothing ever asks Gatekeeper whether it would accept the file.
    #expect(s.contains("spctl"), "the script never asks Gatekeeper to assess the image")

    // Named bug: signing without a hardened runtime or a secure timestamp.
    // Notarisation refuses both, and the failure arrives minutes later from
    // Apple rather than immediately from codesign.
    #expect(s.contains("--options runtime"), "the script signs without the hardened runtime")
    #expect(s.contains("--timestamp"), "the script signs without a secure timestamp")
}

@Test func theScriptReportsWhatTheChangelogMustState() throws {
    let s = try String(contentsOf: releaseDmgScript(), encoding: .utf8)

    // Named bug: the CHANGELOG's size and SHA-256 get typed from memory. The
    // file's own header requires every claim be true of the SHIPPED build, and
    // a remembered number is not evidence.
    #expect(s.contains("shasum -a 256"), "the script does not compute the SHA-256")
    #expect(s.contains("lipo -archs"),
            "the script does not report the architecture; CHANGELOG.md claims arm64 only")
    #expect(s.contains("stat -f"), "the script does not report the size in bytes")
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
WT=/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar/.worktrees/45-dmg-tooling
swift test --package-path "$WT" --scratch-path /tmp/cb-dmg-scratch \
  --filter 'theScriptConfirmsNotarisationRatherThanTrustingTheExitCode|theScriptReportsWhatTheChangelogMustState'
```

Expected: FAIL. The script has no `notarytool`, `stapler`, `spctl`, `shasum`, `lipo` or `stat` yet.

- [ ] **Step 3: Write the minimal implementation**

Append to `scripts/release-dmg.sh`, replacing the final `echo "==> built ${DMG}"` line:

```bash
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

    spctl -a -t open --context context:primary-signature -vv "${DMG}" \
        || die "Gatekeeper does not accept ${DMG}"
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

cat <<REPORT

Built ${DMG}

| Fact | Value |
|---|---|
| File | \`$(basename "${DMG}")\` |
| Size | ${SIZE} bytes |
| SHA-256 | \`${SHA}\` |
| Architecture | ${ARCHS} |
| Signature | Developer ID Application, team 85FN4Z37V8 |

REPORT
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
WT=/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar/.worktrees/45-dmg-tooling
swift test --package-path "$WT" --scratch-path /tmp/cb-dmg-scratch --filter ReleaseDmg
```

Expected: all four tests PASS. The two from Task 1 must still pass — step 7 runs on the `NOTARIZE=0` path too, so a mistake there breaks them.

- [ ] **Step 5: Prove the text guards discriminate**

For EACH of `notarytool info`, `stapler validate`, `spctl`, `--options runtime`, `shasum -a 256`, `lipo -archs`: delete the line, run the filtered test, confirm RED with the message that names that bug, restore. Print each mutation diff. A guard that stays green is deleted and rewritten.

- [ ] **Step 6: Commit**

```bash
WT=/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar/.worktrees/45-dmg-tooling
git -C "$WT" add scripts/release-dmg.sh Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift
git -C "$WT" commit -s -S -m 'feat(release): notarise, staple and report the shipped facts

notarytool submit --wait exits 0 for a submission Apple rejected, so the
id is read back and the status confirmed before anything is stapled.

The size, SHA-256 and architecture are printed from the artifact, because
CHANGELOG.md requires every claim be true of the shipped build.

Refs #45'
```

---

### Task 3: Whole-suite verification

**Files:** none modified. This task produces evidence.

- [ ] **Step 1: Cold-scratch build**

```bash
WT=/Users/eduardoa/src/github/ArangoGutierrez/coffee-bar/.worktrees/45-dmg-tooling
swift build --package-path "$WT" --scratch-path "/tmp/cb-cold-$$" --build-tests
```

Expected: `Build complete`, 0 errors, 0 warnings. A warm `.build` has hidden compile errors on this project before, which is why this uses a fresh path.

- [ ] **Step 2: Full suite**

```bash
swift test --package-path "$WT" --scratch-path "/tmp/cb-cold-$$"
```

Expected: `Test run with 893 tests in 11 suites passed` — 889 baseline plus the 4 added here. If the count differs, report the actual number; do not adjust it to match this plan.

- [ ] **Step 3: Judge any flake**

If a failure is one of the three known flakes, re-run it alone and report both results:

```bash
swift test --package-path "$WT" --scratch-path "/tmp/cb-cold-$$" --filter <testName>
```

- [ ] **Step 4: Report**

Write the report file with the pasted output of steps 1-3, the mutation diffs from Tasks 1 and 2, and the final `git -C "$WT" log --oneline main..HEAD`.

## Self-Review

**Spec coverage.** Pipeline steps 0-10 map to Task 1 (0-6, minus notarisation) and Task 2 (7-10). Parameters, error handling and the `EXIT` trap are in Task 1 step 3. Both executed assertions and all text guards from the spec's test section appear in Tasks 1-2. Out-of-scope items (window layout, publishing, CI wiring, reproducible bytes) are absent from every task, as intended.

**Placeholders.** None. Every code step carries the actual file content.

**Type consistency.** `releaseDmgScript()`, `run(_:env:)`, `makeFixtureApp(at:)` and `withProducedImage(_:)` are defined once in Task 1 and reused by name in Task 2. `repoRoot()` is used but never redefined. Shell variables `WORK`, `STAGE`, `MNT`, `DMG`, `APP`, `VERSION`, `TS_FLAG` are defined in Task 1 and referenced in Task 2 with the same names.

**Known gap, deliberate.** The production path — `build-app.sh`, Developer ID signing, real notarisation — is exercised only by the actual release run, never by the suite. That is inherent: those steps need credentials CI does not have. The evidence for them is the GA cut's pasted output.
