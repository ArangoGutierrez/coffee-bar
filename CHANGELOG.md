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
| Staple | `xcrun stapler validate` passes |

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
| Staple | `xcrun stapler validate` passes |

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
- The battery floor. On battery, at or below `20%`, coffee-bar does not hold.
  The floor also refuses the display assertion. "At or below" is exact: at
  `20%` itself coffee-bar does not hold.
  <!-- The floor this release shipped, as a code literal ON PURPOSE. It is a
       record of 0.1.0, not a claim about the current default, and the default
       has since moved. `theBatteryFloorStatedIsTheRealDefault` reads every
       percentage in PROSE and asserts it is the floor in force today, so
       unwrapping these turns the suite red against a sentence that is true. -->

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

[0.1.1]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.1.1
[0.1.0]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.1.0
