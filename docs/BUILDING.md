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

The probe also carries five verbs that need root — `arm`, `report`, `revert`,
`watchdog` and `serve`. **All five are implemented.** They are lid-closed mode,
which shipped in v0.2.0: `arm` records the setting it is about to change,
installs a launchd watchdog, sets the machine to stay awake with the lid shut and
forces the display off; `report` prints what is armed; `revert` puts the setting
back; `watchdog` is what launchd itself runs to undo the hold when the TTL
expires.

`serve` is the odd one out and you will never type it. It is the entry point of
the **registered helper** (issue #71): a launchd job whose plist ships inside
`CoffeeBar.app/Contents/Library/LaunchDaemons/`, which the app installs through
`SMAppService` when you click the button in Preferences and then enable the
item yourself in System Settings › General › Login Items & Extensions. It
publishes an XPC endpoint, and every peer on that channel is
pinned by Team ID **and** bundle ID — `PrivilegedHelperIdentity` is where the
requirement is written and `PrivilegedHelperPeerGate.swift` is the only file
allowed to apply it.

**That path needs a code-signed bundle, so a default build cannot use it.**
`SMAppService` registers a plist out of a signed bundle's contents, and
`scripts/build-app.sh` signs only when `SIGN_IDENTITY` is set — which a
contributor build, a CI build and a Homebrew install all leave unset. Those
builds carry no team, the app reads its own signature, and it does not offer the
button. `sudo coffee-bar-probe arm` remains the route for them, and it is
unchanged.

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

`scripts/build-app.sh` leaves the bundle unsigned unless you ask for a
signature. Set `SIGN_IDENTITY` and it signs with that identity; leave it unset
and the bundle keeps the ad-hoc signature the linker gave it, and the build
still exits 0.

```
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
```

`security find-identity -v -p codesigning` lists what a machine holds, and an
unsigned run prints the same hint with this machine's identity filled in.
`SIGN_IDENTITY='-'` signs ad hoc.

**Signing is opt-in, not detected**, and the reason is that this script is also
the Homebrew formula's build path. A version that reached for whatever Developer
ID it found in the keychain made `brew install coffee-bar` run
`codesign --sign <that person's private key>` over a bundle they were merely
installing — a third party's signing identity used without their consent, on the
route most likely to reach somebody who never read this repository. So an unset
variable has to mean *sign nothing*. `scripts/sign-bundle.sh` carries the
argument in full.

Unset is also the right default for the two cases that were always the normal
ones: a contributor holds no Developer ID Application certificate, because the
private key is the maintainer's and cannot be shared, and CI assembles the
bundle on a runner with no keychain identity at all. A build that failed for
want of a private key would break `git clone && scripts/build-app.sh` for
everyone who is not the maintainer.

With an identity, `codesign -dv` reports `flags=0x10000(runtime)` and the team
that signed it. Without one, the bundle carries nothing but the ad-hoc signature
the linker applies — `Signature=adhoc` with `flags=0x20002(adhoc,linker-signed)`
— which is enough to run on the machine that built it and not enough for
Gatekeeper to accept a copy handed to another Mac.

Neither bundle is notarised. A copy that reaches another Mac carrying
`com.apple.quarantine` is refused unless it is notarised, so a local build is
for this machine either way. `scripts/release-dmg.sh` is what signs, notarises
and staples a release.

**Two executables mean two signatures.** `Contents/MacOS/` holds `coffee-bar` and
`coffee-bar-probe`, and signing the bundle covers the main executable — a nested
Mach-O is sealed by the bundle signature but is not itself signed by it. The
nested binaries are signed first and the bundle second, because signing a nested
binary afterwards changes a file the bundle's seal covers and invalidates it.

The bundle's own verification cannot police this. Measured on a two-binary
fixture: with only the bundle signed, `codesign --verify --deep --strict`
returns 0 while the nested binary still holds the linker's signature and names
no team — which notarisation refuses before Gatekeeper ever sees it. So the
script reads each binary back individually rather than trusting that exit code,
and `Tests/CoffeeBarCoreTests/BundleSigning_test.swift` holds it to that.

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
