<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0
-->

# Reproducible DMG tooling — design

**Date:** 2026-08-09
**Status:** approved, not yet implemented
**Issue:** #45 phase 2

## Problem

v0.1.1 shipped a signed, notarised, stapled `coffee-bar-0.1.1.dmg` and left **zero
trace of how** in the repository. Measured on this tree:

```
$ grep -rl 'hdiutil\|create-dmg' . --exclude-dir=.git --exclude-dir=.build
./.github/ISSUE_TEMPLATE/release.yml
```

One hit, and it is a checklist template. `scripts/` holds `build-app.sh`,
`lid-probe.sh`, `preferences-activation-acceptance.sh` and the redact-hook pair;
none builds a disk image. `.github/workflows/release.yml` triggers on `v*` tags
but only builds `coffee-bar-probe` and jq-checks its JSON — it attaches nothing.

So cutting v0.2.0 means reconstructing the v0.1.1 sequence from memory. That is
the failure #45 phase 2 asks to end.

`CHANGELOG.md` raises the stakes: its header requires every claim to be true of
the SHIPPED build, and the v0.1.1 entry records the DMG's size and SHA-256. Those
cannot be written without building the artifact, so the artifact gates the entry,
which gates the tag, which gates the site.

## What v0.1.1 actually shipped

Not reconstructed — measured against the artifact still on disk at
`build/dist/coffee-bar-0.1.1.dmg`, which is provably the shipped file:

| Fact | Value | Matches CHANGELOG |
|---|---|---|
| Size | `299302` bytes | yes |
| SHA-256 | `afc1b15f9bde31aad09de80f23ae97b05f6053322b68b89bab36bcfbc641d2e6` | yes |
| Format | UDIF read-only compressed (zlib) = UDZO | — |
| Volume name | `coffee-bar` | — |
| Volume root | `.VolumeIcon.icns`, `Applications -> /Applications`, `CoffeeBar.app` | — |
| Custom-icon flag | SET (`GetFileInfo` → `avbstClinmedz`, uppercase `C`) | — |
| Signature | `Developer ID Application: … (85FN4Z37V8)`, identifier `coffee-bar-0` | yes |
| Staple | `xcrun stapler validate` → "The validate action worked!" | yes |
| Bundle payload | `coffee-bar` only | — |

The last row is the one user-visible change in v0.2.0: `build-app.sh:41` now reads
`PRODUCTS=(coffee-bar coffee-bar-probe)`, so the v0.2.0 DMG carries the probe.
That partly closes #64, whose premise ("the binary is NOT shipped") was measured
on 2026-08-07 and is now stale.

## Measured facts that shape the design

Three assumptions were tested rather than reasoned about. Each would have shipped
a defect.

**1. `hdiutil create -srcfolder` drops the custom-icon bit.** Setting `SetFile -a C`
on the source folder does not carry through:

```
source folder after SetFile -a C : avbstClinmedz   (set)
resulting mounted volume         : avbstclinmedz   (CLEAR)
```

A one-shot `create -srcfolder` therefore ships a generic-icon disk image while
appearing to succeed. Reproducing v0.1.1 requires the read-write dance:
`create -format UDRW` → `attach` → `SetFile -a C` on the **mounted volume** →
`detach` → `convert -format UDZO`. Verified end-to-end: the flag reads
`avbstClinmedz` on the final compressed image.

**2. A fixture bundle built from `/bin/echo` signs and verifies like production.**
Ad-hoc signing (`--sign -`) nested-first, then the bundle, yields:

```
--prepared:/…/Fixture.app/Contents/MacOS/coffee-bar-probe
--validated:/…/Fixture.app/Contents/MacOS/coffee-bar-probe
Fixture.app: valid on disk
Fixture.app: satisfies its Designated Requirement
rc=0
```

This is what makes an executed test possible without a 900 KB release build.

**3. The signing-order check discriminates.** With the nested signatures stripped
and only the bundle signed, `codesign` refuses at **sign** time, and
`--verify --deep --strict` returns `rc=1`:

```
In subcomponent: /…/Fixture.app/Contents/MacOS/coffee-bar-probe
Fixture.app: code object is not signed at all
```

A guard asserting `rc=0` therefore flips when the order is wrong. It is not
theater.

## Design

### `scripts/release-dmg.sh`

Given a clean tree at a release tag, produce a signed, notarised, stapled
`build/dist/coffee-bar-<version>.dmg` and print CHANGELOG-ready facts.

| # | Step | Rationale |
|---|---|---|
| 0 | Preconditions: clean tree; HEAD at a tag; signing identity in keychain; notarytool profile `coffeebar-app` present | fail in seconds, not after a full build |
| 1 | `scripts/build-app.sh` → `build/CoffeeBar.app` | reuses existing tooling, which already stamps the version from `git describe` |
| 2 | `codesign` each nested binary, then the bundle, with `--options runtime --timestamp` | wrong order fails at sign time (fact 3) |
| 3 | `codesign --verify --deep --strict`; require a `--validated:` line for `coffee-bar-probe` | the check #45 phase 2 names |
| 4 | Stage `CoffeeBar.app`, `Applications -> /Applications`, `.VolumeIcon.icns` | reproduces the measured v0.1.1 layout |
| 5 | UDRW → attach → `SetFile -a C` → detach → convert UDZO → **re-verify the flag** | fact 1; the re-verify is the guard against a silent regression |
| 6 | `codesign` the DMG | v0.1.1's DMG is signed |
| 7 | `notarytool submit --wait`, then `notarytool info` to confirm status is `Accepted` | exit 0 from submit does not mean Accepted |
| 8 | `stapler staple` then `stapler validate` | v0.1.1's staple validates |
| 9 | `spctl -a -t open --context context:primary-signature -vv` | the acceptance the CHANGELOG claims |
| 10 | Print file, size in bytes, SHA-256, `lipo -archs`, team | makes the CHANGELOG entry mechanical rather than remembered |

The volume icon source is the bundle's own `Contents/Resources/AppIcon.icns`,
which `build-app.sh:267` generates with `iconutil` from
`assets/art/appicon/AppIcon.iconset`. No new asset is committed.

**Error handling.** `set -euo pipefail`, a `die()` per step, and an `EXIT` trap
that detaches `/Volumes/coffee-bar` and removes the staging directory. A mid-run
failure must not leave a mounted volume behind; the next run would then hit a
name collision and either fail confusingly or silently image the wrong volume.

**Parameters, and why they exist.** Defaults are the production values; the
overrides exist so the suite can execute the script for real.

| Variable | Default | Purpose |
|---|---|---|
| `SIGN_IDENTITY` | `Developer ID Application: Carlos Eduardo Arango Gutierrez (85FN4Z37V8)` | `-` (ad-hoc) in tests |
| `NOTARIZE` | `1` | `0` skips steps 7-9, which need network and credentials |
| `APP_SRC` | unset | when set, skip step 1 and use this bundle |
| `OUT_DIR` | `build/dist` | tests write to a temp dir |

`NOTARIZE=0` is the one configuration no release uses. It is confined to steps
that provably cannot run in CI, and every step it skips is covered by a text
guard instead.

### `Tests/CoffeeBarCoreTests/ReleaseDmg_test.swift`

**Executed against a real artifact.** The test builds a fixture bundle
(`/bin/echo` copied to `coffee-bar` and `coffee-bar-probe`, plus a minimal
`Info.plist` and an `AppIcon.icns`), runs the script with `SIGN_IDENTITY=-`,
`NOTARIZE=0`, `APP_SRC=<fixture>`, `OUT_DIR=<temp>`, and asserts against the DMG
it produced:

- the file exists and `hdiutil verify` returns 0
- the volume name is `coffee-bar`
- `Applications` resolves to `/Applications`
- the custom-icon flag is set — **named bug: a one-shot `create -srcfolder`
  ships a generic-icon DMG** (fact 1)
- `Contents/MacOS` holds exactly `{coffee-bar, coffee-bar-probe}`, by set
  equality rather than containment, for the reason `build-app.sh:350` already
  gives: containment passes over a stale binary left by a rename, and an
  unnoticed second Mach-O is one that does not get signed
- `codesign --verify --deep --strict` returns 0 — **named bug: the bundle is
  signed before the nested probe and notarisation rejects it** (fact 3)

**Text-read guards**, for the steps that cannot execute in CI, following the
established idiom of `BuildScriptVersion_test.swift` and `BundleLicence_test.swift`:
the script must contain a `notarytool info` confirmation and not merely `submit`;
`stapler`; `spctl`; and `--options runtime --timestamp`.

Every text guard is mutation-checked by deleting the line it asserts. A guard
that stays green without its subject is deleted and rewritten.

## Out of scope

- **Window layout and background image.** v0.1.1 had neither. The AppleScript
  and `.DS_Store` machinery is brittle and unreviewable, and nobody has asked.
- **Publishing.** `gh release create` and the atomic push stay manual and gated
  on explicit approval. This script stops at a verified local artifact.
- **CI integration.** `release.yml` holds no write token by design. Wiring the
  DMG into it needs signing secrets in Actions, which is a separate decision.
- **Reproducible output.** `hdiutil` embeds timestamps, so two runs at the same
  commit produce different bytes. The CHANGELOG's SHA-256 therefore describes the
  one uploaded file, which is why step 10 prints it from the artifact rather than
  computing it anywhere else.

## Consequences

`docs/BUILDING.md` §Signing says Developer ID signing and notarisation "are
planned release work". That was already stale when v0.1.1 shipped notarised. It
describes the local `build-app.sh` output, which genuinely is still unsigned, so
the sentence is defensible but misleading. Correcting it is a follow-up, not part
of this change.
