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

## [0.1.1] — 2026-08-04

The first signed and notarised download. This release ships no code change.

### Added

- A disk image, `coffee-bar-0.1.1.dmg`, on the GitHub release page. It is the
  first artifact signed with a Developer ID, notarised by Apple, and stapled.
  macOS opens it without a Gatekeeper warning.

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

Homebrew still installs 0.1.0. The tap pins the older tag and builds from
source, so the version in the panel differs from the version in the disk image.

## [0.1.0] — 2026-08-03

The first release. coffee-bar is a macOS menu-bar app that keeps the Mac awake
while a coding agent works, and lets it sleep when every agent waits on you.

### Added

- The wake policy. coffee-bar holds a `PreventUserIdleSystemSleep` assertion
  while an agent session is `starting` or `working`. It releases the assertion
  when every session waits on a human. A session that waits on you holds
  nothing.
- The Serving control, with three positions. `Off` never holds, and it outranks
  an active session. `Auto` is the default, and the sessions decide. `On` always
  holds.
- The Display control, with two positions. `Sleeps` is the default, so the
  screen goes dark while the machine stays awake. `Stays on` adds a
  `PreventUserIdleDisplaySleep` assertion. That assertion rides the system hold
  and never outlives it.
- The battery floor. On battery, at or below 20%, coffee-bar does not hold. The
  floor also refuses the display assertion. "At or below" is exact: at 20%
  itself coffee-bar does not hold.
- Ingest over a unix socket with mode 0600. Five Claude Code hooks feed it:
  `SessionStart`, `PreToolUse`, `PostToolUse`, `PermissionDenied` and `Stop`.
  The app learns what your sessions do from these hooks and from nothing else.
- The attention list in the panel. It names the sessions blocked on you:
  `awaitingPermission` and `awaitingInput`.
- Distribution through Homebrew. The tap builds the app from source.

coffee-bar asks macOS for the same power assertions `caffeinate` uses. It needs
no root, no password, and no kernel extension.

### Not in this release

- No token accounting.
- No battery measurement, and no claim about a saving.
- No support for an agent other than Claude Code.

[0.1.1]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.1.1
[0.1.0]: https://github.com/ArangoGutierrez/coffee-bar/releases/tag/v0.1.0
