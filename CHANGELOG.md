<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0

This file is the source of truth for the version history. `site/changelog.html`
mirrors it, so an entry is written here first.

Every claim on this page must be true of the SHIPPED build, which is the same
rule the header of `site/index.html` carries. Two constraints follow from it and
both have already caught an error:

  1. The binary is Apple silicon only. `lipo -archs` reports `arm64` alone, and
     an earlier draft of the site named a second architecture that the build
     does not carry. Write `arm64` only. Name no other architecture here, and
     claim no multi-architecture build.
  2. v0.1.1 ships no code change. The diff over `Sources/`, `Package.swift` and
     `Tests/` between the two tags is empty. If a future release repeats that
     shape, say so as plainly.

Do not add an "Unreleased" heading for work that is not tagged. A version
heading here means a tag exists.
-->

# Changelog

Every released version of coffee-bar, newest first.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] — 2026-08-11

A release about trusting the suite that certifies this app. Nothing here changes
what coffee-bar does for you. Seven tests could fail on a loaded machine while
the code they cover was correct, and a suite that cries wolf is one you stop
reading — which is how a real defect ships behind 900 green checks.

Five root causes, each traced to a specific line and each fix mutation-checked:
delete the fix, the guard must go red.

### Fixed

- **A test helper published its state non-atomically.** It wrote with
  `fopen(path, "w")`, which truncates the file to zero bytes *before* writing,
  on a 50 ms cycle — so a reader could observe an empty file. Measured at 71
  empty reads in 219,902 samples. Worse for the crash test, which reads after a
  `SIGKILL`: a kill landing inside that window left the file empty permanently.
  The helper now writes to a sibling path and `rename(2)`s over the target, so a
  reader sees the old report or the new one and never neither. (#84)
- **A file-descriptor bound sat below its own noise floor.** The leak guard
  allowed a delta of 20 over 40 spawns, but the descriptor count is
  process-global and the suite's parallel ramp alone was measured at 16 to 22 —
  so the bound was *under* the noise, and tripped on innocent runs. Now 200
  iterations against a bound of 100: 4.5x clear of the worst observed ramp, and
  still a factor of four under the leak it exists to catch. (#57)
- **Two hook-shim tests asserted a guarantee the shim does not make.** The shim
  gives up after one second and exits silently, by design — a lost confirmation
  is not worth a diagnostic on every tool call. Under load that budget expired
  and the tests failed on behaviour that had not changed. The budget is now
  resolvable, and the tests raise it. (#90)
<!-- The three timings in the bullet below are wrapped in backticks ON PURPOSE.
     They are readings taken from one past CI log, not product constants, and
     `everyDurationStatedIsARealProductConstant` reads every duration in prose
     and asserts it is a `StalePolicy` value. Unwrapping them turns the suite red
     against sentences that are true. The same reasoning is written out beside
     the wrapped percentages in `site/changelog.html`. -->
- **Three tests built disk images at the same time.** Their file declares no
  suite, so they ran concurrently, and concurrent `hdiutil create` fails with
  `Resource busy`. Measured from a CI log: all three started within `0.93 s` of
  each other and ran concurrently for about `45 s`. The create/attach/detach
  cycle is now serialised — pairwise overlap went from `96.10 s` to zero.
- **A listener test pinned one curl exit code where two were correct.** `52`
  (empty reply) and `55` (failed sending data) both describe the socket
  accepting a post and then dropping it; which arrives depends on where the drop
  lands relative to the write. The test now accepts exactly those two, and still
  fails on delivery or refusal.

### Added

- `COFFEE_BAR_SHIM_TIMEOUT_SECONDS` sets the hook shim's total run budget. It is
  the only production change in this release and exists so tests can raise the
  budget above what a loaded machine costs. Absent, unparseable, zero, negative,
  non-finite or above the five-second ceiling all fall back to the shipped
  default of one second, so behaviour is unchanged unless you set it
  deliberately.

### Not in this release

`site/`, the app's UI and every user-facing behaviour are untouched. The only
shipped binary difference is the shim's budget resolver above.

| Fact | Value |
|---|---|
| File | `coffee-bar-0.2.2.dmg` |
| Size | 860341 bytes |
| SHA-256 | `21839e1612b67a845943102b4737d4cd2f3984d5facee4e428a992774e08331b` |
| Architecture | Apple silicon (`arm64`) only |
| Minimum macOS | 14.0 |
| Signature | Developer ID Application, team `85FN4Z37V8` |
| Notarisation | `spctl` accepts it, source `Notarized Developer ID` |
| Staple | `xcrun stapler validate` passes on the app and on the image |

This is not a universal binary. `lipo -archs` on the shipped binary reports
`arm64` alone, so an Intel Mac cannot run it.

Verify the download before you open it:

    shasum -a 256 coffee-bar-0.2.2.dmg
    spctl -a -t open --context context:primary-signature -vv coffee-bar-0.2.2.dmg

## [0.2.1] — 2026-08-10

A release about trust in what the app tells you. Four things it reported, or
failed to report, were not true. Each is now correct, and each correction is
held in place by a check that fails if it regresses.

### Fixed

- **The app can now tell you when its root helper is stale.** Installing a new
  build left the old helper in place, so privileged fixes never reached an armed
  setup, and nothing said so. The panel and the Preferences window now raise an
  advisory when the installed helper differs from the one in the build you are
  running, carrying the exact command that repairs it. Paste that command and
  the advisory clears without relaunching. (#81)
- **A hook that cannot fire is no longer reported as wired.** A tool event whose
  matcher was missing, `null`, or not a string counted as healthy, so the app
  would tell you your setup was fine while it could never run. A tool event now
  requires a matcher the tool can actually use, and a lifecycle event must carry
  none at all. (#55)
- **The app inside the disk image is stapled.** The image was notarised and
  stapled, but the app inside it was not. The app is now signed, notarised and
  stapled *before* the image is built around it. (#82)
- **Two architectural justifications no longer rest on a dead premise.** The
  comments explaining why the privileged path avoids XPC peer pinning and
  `SMAppService` were written when this project had no signed bundle. One has
  shipped since 0.2.0. Both decisions now read as *unimplemented rather than
  impossible*, and the open question is tracked in #71. (#86)

| Fact | Value |
|---|---|
| File | `coffee-bar-0.2.1.dmg` |
| Size | 858099 bytes |
| SHA-256 | `0c1cd40bbd2c8a1bd2e1cd54122ab49d7f5f40b5a716772d0713917178f11288` |
| Architecture | Apple silicon (`arm64`) only |
| Minimum macOS | 14.0 |
| Signature | Developer ID Application, team `85FN4Z37V8` |
| Notarisation | `spctl` accepts it, source `Notarized Developer ID` |
| Staple | `xcrun stapler validate` passes on the app and on the image |

This is not a universal binary. `lipo -archs` on the shipped binary reports
`arm64` alone, so an Intel Mac cannot run it.

Verify the download before you open it:

    shasum -a 256 coffee-bar-0.2.1.dmg
    spctl -a -t open --context context:primary-signature -vv coffee-bar-0.2.1.dmg

### Upgrading

Nothing to do beyond installing it. This release changes no on-disk format and
ends no hold that is already running.

If you armed lid-closed mode with an earlier build, install this one and then
follow the advisory the panel now shows: the root helper is replaced by the
command it gives you, not by the installer.

Homebrew installs 0.2.1 as well: the tap pins this tag. It builds on your
machine, so that copy is signed only ad hoc and is not notarised. The disk image
is the signed, notarised and stapled artifact.

## [0.2.0] — 2026-08-09

Lid-closed mode, a Preferences window, and a hardened privileged path. The disk
image now carries `coffee-bar-probe`, so the feature it unlocks is reachable
without building from source.

### Added

- **Lid-closed mode.** `sudo coffee-bar-probe arm` holds the Mac awake with the
  lid shut, governed by a launchd watchdog with a revert ladder and a hard
  eight-hour cap.
- **A Preferences window**, split out of the panel, carrying the battery floor.
  It ships at 15%, and the control moves between `10%` and `50%` in steps of `5`.
- **A process governor**, wired into the app.
- **Codex and Cursor adapters**, plus the `coffeebar-hook` shim, so each agent
  tool's hook file is read in its own shape.
- **An app icon**, and an app palette aligned with the site.
- **`coffee-bar-probe` inside the bundle**, and so inside the disk image. 0.1.1
  shipped `coffee-bar` alone, which left lid-closed mode reachable only by
  building from source.
- **`scripts/release-dmg.sh`**, which builds this disk image. 0.1.1's image left
  no trace in the repository of how it was made.

| Fact | Value |
|---|---|
| File | `coffee-bar-0.2.0.dmg` |
| Size | 844641 bytes |
| SHA-256 | `5c16bfd3636adfc568e14dbf26e8a3c62ecd9e2fb2606136a08e6342c965cd15` |
| Architecture | Apple silicon (`arm64`) only |
| Minimum macOS | 14.0 |
| Signature | Developer ID Application, team `85FN4Z37V8` |
| Notarisation | `spctl` accepts it, source `Notarized Developer ID` |
| Staple | `xcrun stapler validate` passes on the image; the app inside it was NOT stapled |

The Staple row above read `passes` until 0.2.1, which is what a run that stapled
only the image prints. Measured on the shipped 0.2.0 image: `stapler validate`
exits 65 on `CoffeeBar.app` with "does not have a ticket stapled to it". 0.2.1
staples the app as well, and the row now names both so the two states can be
told apart. That is #82.

Verify the download before you open it:

    shasum -a 256 coffee-bar-0.2.0.dmg
    spctl -a -t open --context context:primary-signature -vv coffee-bar-0.2.0.dmg

### Fixed

- The watchdog's `uninstall` booted the service out before removing its plist,
  leaving a root LaunchDaemon that came back at every boot.
- The revert and refusal notifications sat after a self-terminating bootout, so
  neither ever fired on the daemon path.
- The TTL rung measured elapsed time on the wall clock, so a backward step
  extended a privileged hold past its eight-hour cap. It now uses
  `mach_continuous_time()`, which keeps counting across sleep.

### Changed

- The watchdog journal's `schemaVersion` moved from 1 to 2.

### Upgrading

**Installing this version ends an `arm` that is already running.** A hold armed
by an older build wrote a version 1 journal. The first watchdog rung reads it,
answers `.unknownSchema`, and reverts. That is the fail-safe working as designed,
but it is invisible unless you know the schema moved. Re-arm after installing.

Homebrew installs 0.2.0 as well: the tap now pins this tag. It builds on your
machine, so that copy is signed only ad hoc and is not notarised. The disk image
is the signed, notarised and stapled artifact.

## [0.1.1] — 2026-08-04

The first signed and notarised download. This release ships no code change.

### Added

- A disk image, `coffee-bar-0.1.1.dmg`, on the GitHub release page. It is the
  first artifact signed with a Developer ID, notarised by Apple, and stapled.

| Fact | Value |
|---|---|
| File | `coffee-bar-0.1.1.dmg` |
| Size | 299302 bytes |
| SHA-256 | `afc1b15f9bde31aad09de80f23ae97b05f6053322b68b89bab36bcfbc641d2e6` |
| Architecture | Apple silicon (`arm64`) only |
| Minimum macOS | 14.0 |
| Signature | Developer ID Application, team `85FN4Z37V8` |
| Notarisation | `spctl` accepts it, source `Notarized Developer ID` |
| Staple | `xcrun stapler validate` passes on the app and on the image |

Measured on the shipped 0.1.1 image, not inferred: `stapler validate` exits 0 on
the image and on `CoffeeBar.app` inside it. 0.2.0 lost the second of those and
0.2.1 restored it, so this row now says which staples were checked rather than
the bare `passes` it shared with 0.2.0 — wording that read the same either way.

Verify the download before you open it:

    shasum -a 256 coffee-bar-0.1.1.dmg
    spctl -a -t open --context context:primary-signature -vv coffee-bar-0.1.1.dmg

### Changed

- The landing page under `site/`. It now carries the product's own identity and
  the assertion timeline.
- `SECURITY.md`. Four stale claims now match the code.
- `.gitignore`. It now excludes the signing and notarisation secrets.

None of these change the application.

### Unchanged

The application is the same code as 0.1.0. The measured difference between the
two tags over the shipped source is empty:

    git diff --stat v0.1.0..v0.1.1 -- Sources/ Package.swift Tests/

That command prints nothing. Take this release for the signed artifact, not for
new behaviour.

When 0.1.1 shipped, Homebrew still installed 0.1.0: the tap pinned the older tag
and built from source, so the version in the panel differed from the version in
the disk image. The tap has since moved on.

## [0.1.0] — 2026-08-03

The first release. coffee-bar is a macOS menu-bar app that keeps the Mac awake
while a coding agent works, and lets it sleep when every agent waits on you.

### Added

- The wake policy. Under `Auto`, coffee-bar holds a
  `PreventUserIdleSystemSleep` assertion while an agent session is `starting` or
  `working`. It releases the assertion when every session waits on a human.
  Under `Auto`, a session that waits on you holds nothing.
- The Serving control, with three positions. `Off` never holds, and it outranks
  an active session. `Auto` is the default, and the sessions decide. `On` holds
  whatever the sessions do. The battery floor below still applies to `Auto` and
  to `On`.
- The Display control, with two positions. `Sleeps` is the default, so the
  screen goes dark while the machine stays awake. `Stays on` adds a
  `PreventUserIdleDisplaySleep` assertion. That assertion rides the system hold
  and never outlives it.
- The battery floor. On battery, at or below 20%, coffee-bar does not hold.
  The floor also refuses the display assertion. "At or below" is exact: at 20%
  itself coffee-bar does not hold.
  <!-- The floor this release shipped, written plainly. These two numbers were
       code literals because `theBatteryFloorStatedIsTheRealDefault` read every
       percentage in PROSE and asserted it was the floor in force today, which
       reddened a sentence that is true. That guard now stops at a version
       heading — see `currentClaimProse` in DocsClaims_test.swift — so a
       released section may record what it shipped. Do not update these to the
       current default: they say what 0.1.0 did. -->

- Ingest over a unix socket with mode 0600. Five Claude Code hooks feed it:
  `SessionStart`, `PreToolUse`, `PostToolUse`, `PermissionDenied` and `Stop`.
  The app learns what your sessions do from these hooks and from nothing else.
- The attention list in the panel. It names the sessions blocked on you:
  `awaitingPermission` and `awaitingInput`.
- Distribution through Homebrew. The tap builds the app from source.

coffee-bar asks macOS for the same power assertions `caffeinate` uses. v0.1.0
needs no root, no password, and no kernel extension.

### Not in this release

- No token accounting.
- No battery measurement, and no claim about a saving.
- No support for an agent other than Claude Code.

[0.2.1]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.2.1
[0.2.0]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.2.0
[0.1.1]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.1.1
[0.1.0]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.1.0
