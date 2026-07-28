<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0
-->

# Contributing to coffee-bar

Thanks for looking. This document holds the rules that a pull request is checked
against. Every command below was run against this repository before it was
written down.

To report a security vulnerability, do not open a pull request or an issue. Read
[SECURITY.md](SECURITY.md).

## What you need

- macOS 14 or later. `Package.swift` declares `platforms: [.macOS(.v14)]`.
- A Swift 6 toolchain, which means Xcode 16 or later. `Package.swift` declares
  `swift-tools-version: 6.0` and every target sets `.swiftLanguageMode(.v6)`,
  so Xcode 15 fails at manifest parse.
- Apple Silicon for the power work. Every measurement in
  `docs/probe-results.md` was taken on an Apple Silicon MacBook, and the S2
  finding is specifically an Apple Silicon behaviour. Nothing has been measured
  on Intel, so treat an Intel result as new data rather than a regression.

Check your toolchain first:

```
$ swift --version
swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
Target: arm64-apple-macosx26.0
```

## Build from source

Fork the repository, then clone your fork. There is no `.xcodeproj` and none is
needed: SwiftPM builds every product, including the SwiftUI menu-bar app.

```
$ swift build
Building for debugging...
Build complete! (0.12s)
```

Build the release configuration too. CI builds both, and a warning that only
appears under optimisation fails there rather than here:

```
$ swift build -c release
Building for production...
Build complete! (0.20s)
```

`Package.swift` declares no external package dependencies, so a build resolves
and fetches nothing.

### Build the menu-bar app bundle

`swift build` produces the `coffee-bar` executable, but macOS needs a bundle
before it shows a menu-bar item. `scripts/build-app.sh` assembles one:

```
$ ./scripts/build-app.sh
==> version 0.0.0-dev (no git tag in this repo; untagged fallback)
==> swift build -c release --product coffee-bar
Build of product 'coffee-bar' complete! (0.20s)
==> assembling .../build/CoffeeBar.app
    8 glyph files copied
    LSUIElement=true (no Dock icon)

Built .../build/CoffeeBar.app (version 0.0.0-dev, unsigned)
```

The bundle is unsigned, so a copy handed to another Mac is quarantined by
Gatekeeper. The version comes from `git describe --tags --abbrev=0`. No tag
exists yet, so every build today reports `0.0.0-dev`. Read it back with:

```
$ /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    build/CoffeeBar.app/Contents/Info.plist
0.0.0-dev
```

## Run the tests

```
$ swift test
✔ Test run with 203 tests in 3 suites passed after 2.484 seconds.
```

Filter to one suite while you work. The filter matches the suite type name, not
the file name:

```
$ swift test --filter AssertionHolderTests
✔ Suite AssertionHolderTests passed after 0.005 seconds.
✔ Test run with 8 tests in 1 suite passed after 0.005 seconds.
```

Some tests read live IOKit state and create real power-management assertions.
`AssertionHolderTests` is declared `@Suite(.serialized)` for that reason: two of
its tests in parallel would see each other's assertions and every live count
would be meaningless. Keep that annotation on any suite you add that touches
process-global state.

## Run the capability probe

The probe answers the hardware and OS questions the architecture branches on. It
holds and releases a real assertion, so run it on the machine you are asking
about:

```
$ swift run coffee-bar-probe
coffee-bar capability probe
  host   Mac16,7 arm64
  os     26.5.2 (build 25F84)

  baseline pass        PreventUserIdleSystemSleep acquired and released
  S3       pass        ri_billed_energy populated for pid 43699
  S5       pass        demoted pid 43699 to background QoS and restored it
  S8       pass        telemetry mode: ownIt
  S1       not-yet-run run `coffee-bar-probe arm`, close the lid, then `report`
  S2       not-yet-run needs an armed run, and needs a new instrument first: ...
```

The S2 line is cut short here. The probe prints the whole reason, which points
at `docs/probe-results.md`.

Add `--json` for a machine-readable report:

```
$ swift run coffee-bar-probe --json
{
  "generatedAt" : "2026-07-28T16:26:18Z",
  "host" : {
    "arch" : "arm64",
    "hardwareModel" : "Mac16,7",
    "osBuild" : "25F84",
    "osVersion" : "26.5.2"
  },
  "schemaVersion" : 1,
  "spikes" : [
```

Read the exit code carefully. `0` means the probe ran, whatever the spikes
found: a spike reporting `fail` is a finding about the machine, not a probe
malfunction. `70` means the probe could not encode its report, and stdout stays
empty so a downstream `jq` gets nothing to parse. `64` means an unimplemented or
unknown verb.

The `arm`, `report`, `revert` and `watchdog` verbs are not implemented yet. They
exit 64 today.

To see what is holding your Mac awake at any moment, including coffee-bar's own
assertions (`coffee-bar is serving` from the app, `coffee-bar probe baseline`
from the probe):

```
$ pmset -g assertions
Assertion status system-wide:
...
Listed by owning process:
   pid 48824(caffeinate): [0x000f76610001a2d0] 00:02:06 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
```

## Tests come first

This project is written test first. Red, then green, then refactor, in that
order.

- Write the failing test before the implementation. Run it and watch it fail.
  A test that has never failed proves nothing.
- Change a test and change an implementation in separate commits. A pull request
  that edits both in one commit cannot be reviewed for which one moved.
- A test is a contract. When one fails, fix the implementation. Change the test
  only when the test itself carries a genuine bug, and say so in the commit body.
- Assert against a literal or an independently derived value. A test that
  recomputes the implementation's own logic tests nothing.
- After the test passes, name the bug it catches. If you cannot name one, delete
  the test and write a real one.

The existing suite shows the standard. `AssertionHolder_test.swift` reads its
counts back out of IOKit rather than off the holder's own bookkeeping, because
a holder that only flipped a `Bool` would satisfy `isHeld` and still fail every
one of those checks.

## Name test files `<Subject>_test.swift`

Every test file in `Tests/` ends in `_test.swift`:
`AssertionHolder_test.swift`, `ServingModel_test.swift`, `Verdict_test.swift`.
The **type** inside keeps the normal Swift name — `struct AssertionHolderTests`.
Only the file name carries the suffix.

This is not a style preference. `tdd-guard.sh`, the pre-write hook this project
is developed under, classifies a file as a test purely by its **name**. Its
patterns are `*_test.*`, `*.test.*`, `*.spec.*`, `test_*.py`, and the lowercase
directory forms `tests/*` and `*/tests/*`. Shell `case` is case sensitive, so
this repository's capital-`T` `Tests/` directory matches neither directory
pattern. The file name is the only signal left.

The consequence is measurable. Feed the hook a correctly named file and it
allows the write:

```
$ printf '%s' '{"tool_input":{"file_path":".../Tests/CoffeeBarPowerTests/AssertionHolder_test.swift"}}' \
    | bash ~/.claude/hooks/tdd-guard.sh
$ echo $?
0
```

Feed it the XCTest-conventional name and it treats the test as an
implementation file with no test behind it, and blocks:

```
$ printf '%s' '{"tool_input":{"file_path":".../Tests/CoffeeBarPowerTests/AssertionHolderTests.swift"}}' \
    | bash ~/.claude/hooks/tdd-guard.sh
TDD GUARD: No test file found for implementation file.
File: Tests/CoffeeBarPowerTests/AssertionHolderTests.swift

Write the failing test FIRST (Red phase), then implement.
$ echo $?
2
```

A misnamed test file therefore does worse than look inconsistent: it stops
counting as a test, and it blocks the implementation work that depends on it.

## Sign your commits, twice

Every commit needs two things. No git hook in this repository and no CI job
checks them today — `.github/workflows/ci.yml` builds and tests only — so a
maintainer checks them at review, and a commit missing either has to be amended.

```
git commit -s -S -m "fix(power): release the assertion when the last session ends"
```

- `-s` adds the `Signed-off-by:` trailer. That is the Developer Certificate of
  Origin: you state that you wrote the patch, or otherwise have the right to
  contribute it under Apache-2.0. The trailer must carry your real name and a
  real address.
- `-S` signs the commit cryptographically, so the history shows who made each
  change. GPG and SSH signing both work. Configure a key with GitHub's own
  instructions for
  [commit signature verification](https://docs.github.com/authentication/managing-commit-signature-verification),
  then set `commit.gpgsign` to `true` so you cannot forget.

Check a commit after you make it. `%G?` prints `G` for a good signature:

```
$ git log -1 --format='%G? %h %s'
G b886ea2 fix(app): guard the mirror floor boundary, make the app-layer guard structural
```

An unsigned or unsigned-off commit has to be amended and force-pushed to your
branch, so it is cheaper to set both up once.

## Write conventional commit subjects

```
type(scope): description
```

`type` is one of `feat`, `fix`, `docs`, `test`, `refactor`, `build`, `ci`,
`chore`. `scope` names the package or subsystem the change lives in — `core`,
`power`, `ui`, `app`, `probe`, `docs`, `ci`.

Real examples from this repository:

```
fix(app): guard the mirror floor boundary, make the app-layer guard structural
build(app): assemble CoffeeBar.app, retire the POC script
```

Write the subject in the imperative, and keep it to one line and one idea. Put
the reason in the body: the diff already shows what changed, so the body
explains why. State a breaking change explicitly.

## Open the pull request

- One concern per pull request. Two unrelated fixes are two pull requests.
- Open it as a draft, and mark it ready once CI is green.
- Rebase on `main` rather than merging `main` into your branch. Feature branches
  carry no merge commits.
- Fill in the template: problem, approach, testing done, breaking changes, and
  `Closes #N`. Paste real command output under "testing done".

CI runs on `macos-15` and does exactly what you ran locally: `swift --version`,
`swift build`, `swift build -c release`, `swift test`. See
`.github/workflows/ci.yml`.

## Two limits that bind every change

Section 12 of `coffee-bar-HANDOFF.md` lists the 0.x non-goals. Two of them
constrain almost every patch:

1. **No transcript reading.** `transcript_path` and
   `~/.claude/projects/**/*.jsonl` hold proprietary source code and secrets.
   coffee-bar reads session metadata and nothing else. This is a privacy
   commitment.
2. **No network egress.** No telemetry, no crash reporting, no update ping.
   `Package.swift` has no external dependencies, and `Sources/` contains no
   networking symbol. A patch that adds either needs the non-goals list changed
   first, in its own discussion.

`docs/ROADMAP.md` holds the milestones and the decisions behind them. Read it
before proposing anything large — the answer to "why is it not like this
already" is usually recorded there.
