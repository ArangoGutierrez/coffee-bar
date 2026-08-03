# Building from source

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later).

## The menu-bar app

    swift build
    scripts/build-app.sh
    open build/CoffeeBar.app

`scripts/build-app.sh` assembles `build/CoffeeBar.app` from the compiled binary
and the bundle resources. It stamps the version from `git describe`, falling back
to `0.0.0-dev` when no tag exists — which is what an untagged checkout reports
today.

Then wire the hooks: see [Quick start](QUICKSTART.md).

## The capability probe

    swift build
    swift run coffee-bar-probe --json

The probe answers the hardware and OS capability questions the architecture
branches on, as JSON. See
[`docs/superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md`](superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md).

The probe binary also advertises privileged verbs — `arm`, `report`, `revert`,
`watchdog`. **They are not implemented.** Each exits 64 with a message naming the
task that would add it. Nothing in the shipped app reaches the privileged code
path.

## Running the tests

    swift test

The suite includes guards that read the repository rather than the code: a
tree-wide scan for leaked session prose, and a check that the documentation's
factual claims match the constants that settle them
(`Tests/CoffeeBarCoreTests/DocsClaims_test.swift`).

Those guards shell out to `git ls-files` and throw rather than scanning an empty
corpus. **A release source tarball has no `.git`**, so `swift test` inside an
extracted tarball fails on that check. That is the guard working correctly — it
fails closed instead of passing vacuously. Build from a clone if you want to run
the suite.

## Signing

The bundle is ad-hoc signed, not notarised. `codesign -dv` reports
`Signature=adhoc` with `flags=0x20002(adhoc,linker-signed)`. That is enough to
run on the machine that built it, and not enough for Gatekeeper to accept a copy
handed to another Mac. Developer ID signing and notarisation are planned release
work.

### Why a formula and not a cask

A cask distributes a *downloaded* binary, and anything downloaded arrives
carrying `com.apple.quarantine`, which is what makes Gatekeeper refuse an ad-hoc
signed app.

A formula builds from source on your machine, and a locally compiled bundle
never gets that attribute. Measured on a Homebrew-installed build: only
`com.apple.provenance` is present, and the app launches. So the signing work that
blocks a downloadable `.dmg` does not block this path.

A cask becomes the better route once notarisation lands, for people who would
rather not build.
