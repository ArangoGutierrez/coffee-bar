# Building from source

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later).

## The menu-bar app

    swift build
    scripts/build-app.sh
    open build/CoffeeBar.app

`scripts/build-app.sh` assembles `build/CoffeeBar.app` from the compiled binaries
and the bundle resources. Two binaries land in `Contents/MacOS/`: `coffee-bar`,
which is what macOS launches, and `coffee-bar-probe` beside it. The script
asserts that directory holds exactly those two before it finishes.

It stamps the version from `git describe`, falling back to `0.0.0-dev` when no
tag exists — which is what an untagged checkout reports today.

Then wire the hooks: see [Quick start](QUICKSTART.md).

## The capability probe

    swift build
    swift run coffee-bar-probe --json

The probe answers the hardware and OS capability questions the architecture
branches on, as JSON. See
[`docs/superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md`](superpowers/specs/2026-07-27-coffee-bar-m0-probe-design.md).

### The privileged verbs

The probe also carries four verbs that need root — `arm`, `report`, `revert` and
`watchdog`. **All four are implemented.** They are lid-closed mode, which shipped
in v0.2.0: `arm` records the setting it is about to change, installs a launchd
watchdog, sets the machine to stay awake with the lid shut and forces the display
off; `report` prints what is armed; `revert` puts the setting back; `watchdog` is
what launchd itself runs to undo the hold when the TTL expires.

`swift run` cannot reach them, because `swift run` does not run as root. Build
first and invoke the binary directly:

    swift build
    sudo .build/debug/coffee-bar-probe report

`report` is the one you can run that way. `arm`, `revert` and `watchdog` need
more than uid 0: they install or remove a launchd job. Only `arm` is stopped by
the code, though. It is the one verb that reaches
`LaunchDaemonInstaller.install()`, which refuses a program path whose components
are not root-owned and closed to everyone else; `revert` and `watchdog` reach
`uninstall()`, which validates nothing. A build tree under `$HOME` fails `arm`'s
check, and so does an installed app — macOS ships `/Applications` writable by
every administrator account, which is issue #75. Install a copy where root can
trust it and run all three from there:

    sudo install -o root -g wheel -m 755 \
      /Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe \
      /Library/PrivilegedHelperTools/coffee-bar-probe
    sudo /Library/PrivilegedHelperTools/coffee-bar-probe arm

The refusal is the feature: launchd execs that file as root at every boot, so a
job pointed at a binary another account can rewrite is root persistence for
whoever gets there first.

**coffee-bar itself never runs any of them.** The app never elevates its own
privilege (design §6), so there is no control anywhere in it that arms the mode —
you type the command yourself, in your own shell. That is the same posture the
app takes with hooks: it prints what to paste and edits none of your files. What
the app does do is print the command, and say that it cannot read the journal
that would tell you whether the mode is armed. See
[`site/docs.html`](https://arangogutierrez.github.io/coffee-bar/docs.html) for
what the mode does and why that limit is real.

### Where the binary comes from if you did not build it

`scripts/build-app.sh` builds both products and puts them side by side in the
bundle, so an installed app carries the probe:

    /Applications/CoffeeBar.app/Contents/MacOS/coffee-bar-probe

**It is not on your `PATH` and nothing puts it there.** A symlink into
`/usr/local/bin` needs a privileged step, and this project does not take one on
your behalf. Type the path, or add your own symlink if you want the short form.

A Homebrew install lands in the Homebrew prefix rather than `/Applications`, and
the install prints the command that links it there; the path above is the one you
get from the disk image or from linking a brew build.

## The hook shim

    swift build
    .build/debug/coffeebar-hook --help

`coffeebar-hook` is the command you wire into an agent's hooks instead of a
`curl` line. It reads one hook payload on standard input and posts it to a
running coffee-bar. `--tool` selects the agent, and therefore the ingest
endpoint the payload is attributed to.

Nothing installs it on your `PATH`. The Homebrew formula builds the app bundle
and does not place this binary anywhere, so a wired hook names the built
binary by its absolute path. See [Quick start](QUICKSTART.md).

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

**Two executables mean two signatures.** `Contents/MacOS/` holds `coffee-bar` and
`coffee-bar-probe`, and signing the bundle covers the main executable — a nested
Mach-O is sealed by the bundle signature but is not itself signed by it. Sign the
nested binary first and the bundle second: an unsigned nested executable makes
Gatekeeper reject the whole bundle, and notarisation refuses it before that.

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
