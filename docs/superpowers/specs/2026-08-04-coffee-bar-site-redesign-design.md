<!--
Copyright 2026 Carlos Eduardo Arango Gutierrez
SPDX-License-Identifier: Apache-2.0
-->

# coffee-bar site redesign — design

**Date:** 2026-08-04
**Status:** approved
**Supersedes:** the single-page `site/index.html` shipped at v0.1.1

## 1. Goal

Turn the landing page into a four-page documentation site. Add a clear Download
button for the notarised DMG. Show the current version. Explain the two panel
controls and the panel vocabulary. Carry a changelog that grows with each
release.

## 2. Facts this design rests on

Every claim below comes from a command run against the tree on 2026-08-04. A
builder must re-run these and report any delta before writing copy.

| Fact | Source of truth | Value |
|---|---|---|
| Latest tag | `git ls-remote --tags origin` | `v0.1.1` |
| DMG asset | `gh release view v0.1.1` | `coffee-bar-0.1.1.dmg`, 299302 bytes |
| Release state | `gh release view v0.1.1` | **draft** on 2026-08-04 |
| DMG signature | `spctl -a -t open -vv` | accepted, Notarized Developer ID |
| DMG staple | `xcrun stapler validate` | valid |
| Architecture | `lipo -archs` | `arm64` only. **Not universal.** |
| Minimum macOS | `otool -l`, `LSMinimumSystemVersion` | 14.0 |
| Code diff v0.1.0..v0.1.1 | `git diff --stat` over `Sources/ Package.swift Tests/` | empty |
| Homebrew tap pins | tap `Formula/coffee-bar.rb` | `v0.1.0`, builds from source |
| Serving labels | `ServingModel.label(for:)` | `Off` / `Auto` / `On` |
| Display labels | `ServingModel.displayLabel(for:)` | `Sleeps` / `Stays on` |
| Hold states | `PowerBroker.activeStates` | `starting`, `working` |
| Attention states | `SessionState.attentionStates` | `awaitingPermission`, `awaitingInput` |
| Assertions | `AssertionHolder.swift` | `PreventUserIdleSystemSleep`, `PreventUserIdleDisplaySleep` |
| Battery floor | `PowerBroker.decide` | suppresses at `percent <= floor`, default 20 |
| Timeouts | `StalePolicy.standard` | `workingTimeout` 900 s, `blockedTimeout` 14400 s |
| Baseline suite | `swift test` | 486 tests, rc=0 |

**Warning.** The architecture row corrects an error made during design. An
earlier mockup said "Apple silicon & Intel". `lipo -archs` reports `arm64`
alone. Write "Apple silicon" only.

## 3. Decisions

### 3.1 Four pages, no build step

`index.html` (Home), `install.html`, `docs.html`, `changelog.html`. Two shared
assets: `assets/site.css` and `assets/bench.js`.

The site stays a static tree. A build step would break the no-JavaScript
reading path and add a toolchain to a repository that has none. The cost is
that the sidebar markup repeats four times. A test pins the four copies
identical, so a drifting copy fails instead of rotting.

Both assets are same-origin. The no-external-requests rule holds.

### 3.2 Colour system

The accent moves off `#76B900`. Two reasons. First, `#76B900` is NVIDIA's brand
colour, and this is a personal Apache-2.0 product published from an nvidia.com
account; the colour can read as corporate endorsement. Second, the accent fills
the liquid in a cup, and coffee is not green.

Two colours with two jobs. **State** colours the liquid and the held segments.
**Action** colours buttons, links and focus rings.

| Role | Light | Dark | Job |
|---|---|---|---|
| state | `#A2571E` | `#B8682A` | the liquid; held awake |
| action | `#FF9500` | `#FF9F0A` | Apple `systemOrange`; buttons, links, focus |
| rest | `#6B7683` | `#6B7683` | released; free to sleep |

Measured separation between state and action: 9.1 degrees of hue and 2.44x
luminance in light, 10.3 degrees and 2.02x in dark. Ink on the action colour
reaches 8.51 and 9.10, so a filled button carries body text. The state colour
reaches 4.71 on paper and 4.57 on the dark background, so it works as a graphic
in both appearances. `#76B900` reached only 2.12 on paper.

An earlier candidate, crema `#C97B26`, is **rejected**. It sits 3.8 degrees from
`systemOrange` with a 1.51x luminance gap, so the two read as one colour that
missed rather than as a system.

The palette change turns the page into a temperature axis: warm means held
awake, cool means free to sleep. Green and slate carried no such relationship.

The menu-bar glyphs need no change. `coffee-bar-servingTemplate.svg` is
`fill="#000"` plus alpha, so AppKit tints it and the rule "never ship a coloured
menu-bar variant" is unaffected.

### 3.3 The policy bench

The signature element. The assertion timeline becomes a control the visitor
operates: Serving `Off`/`Auto`/`On`, Display `Sleeps`/`Stays on`, power source
with a battery percentage, and a session state. A readout names the assertions
macOS holds.

**The policy must not exist twice.** A JavaScript port of `PowerBroker.decide`
would drift from the Swift original with nothing to catch it. So the JavaScript
carries no policy logic. The page embeds the decision table as data:

```html
<script type="application/json" id="policy-table">
[{"intent":"auto","display":"sleeps","power":"ac","battery":null,
  "sessions":"working","system":true,"displayHeld":false}]
</script>
```

Three consequences:

1. `bench.js` looks a row up and paints it. It has no rule to get wrong.
2. A Swift test walks every row and asserts it equals `PowerBroker.decide(...)`
   for those inputs. The page cannot disagree with the shipped policy.
3. The same table renders as a plain HTML `<table>`. A visitor without
   JavaScript reads the complete truth, and a crawler reads facts rather than a
   script.

Point 3 is the GEO mechanism. An answer engine asked "what does coffee-bar's
Auto mode do?" reads a real table.

### 3.4 Page content

**Home.** Wordmark, one-sentence pitch, the policy bench, the three menu-bar
states, the Download button, and a link into Install.

**Install.** The Download button with its verified facts. The Homebrew route.
The five hooks, copied from `docs/QUICKSTART.md`. The first-run check.

The page must state that Homebrew currently installs **0.1.0** while the DMG is
**0.1.1**, because the tap pins the older tag. Hiding that skew would mislead a
reader who checks the version in the panel.

**Docs.** Written as definitions, because that shape serves a confused user and
an answer engine equally.

- The Serving control. `Off` never holds and is absolute. `Auto` holds while a
  session is `starting` or `working`. `On` always holds.
- The Display control. `Sleeps` is the default; the machine is held and the
  screen still goes dark. `Stays on` adds the display assertion, which rides the
  system hold and never outlives it.
- What coffee-bar asks macOS for: `PreventUserIdleSystemSleep`, plus
  `PreventUserIdleDisplaySleep` under `Stays on`. The same mechanism
  `caffeinate` uses. No root, no password, no kernel extension.
- The battery floor. On battery, **at or below** 20 percent, coffee-bar does not
  hold. The phrase is load-bearing: `PowerBroker` suppresses at
  `percent <= floor`, and the existing guard
  `aBoundaryPhraseMatchesTheRealBoundary` fails a page that says "below 20%".
- "Waiting on you". Sessions blocked on a human: `awaitingPermission` or
  `awaitingInput`. Under `Auto` these do not hold the machine awake.
- Where the app's knowledge comes from: five hooks and nothing else.

**Changelog.** `CHANGELOG.md` becomes the source of truth. `changelog.html`
mirrors it. The `v0.1.1` entry states that the release ships no code change and
only the first signed, notarised artifact; the measured diff over `Sources/`,
`Package.swift` and `Tests/` is empty.

### 3.5 Download link

The button points at the versioned asset:
`https://github.com/ArangoGutierrez/coffee-bar/releases/download/v0.1.1/coffee-bar-0.1.1.dmg`

The asset filename carries the version, so `releases/latest/download/<name>`
offers no advantage. Beside the button: **v0.1.1 · Apple silicon · 292 KB**, and
"macOS 14 or later".

## 4. Guards

Four new checks, in the pattern `DocsClaims_test.swift` already uses.

1. **Surface discovery.** `documentedSurfaces` globs `site/*.html` instead of
   naming files. A new page cannot escape the seven existing honesty checks by
   omission. This closes the objection the review panel raised against the
   multi-page choice.
2. **Policy table fidelity.** Every row of the embedded table equals
   `PowerBroker.decide(...)` for its inputs. The test fails if the table is
   empty, so it cannot pass vacuously.
3. **Version fidelity.** The version string on every page equals the latest git
   tag, and the DMG URL contains that version. The test fails loudly when git is
   unavailable rather than skipping.
4. **Structure fidelity.** The four sidebars are identical, and the hook block
   on `install.html` matches `docs/QUICKSTART.md`. The existing
   `theHookBlockIsExactlyTheRequiredEvents` extends to the site copy.

Each new guard must be mutation-checked: delete the guard, confirm the suite
goes red, restore it.

## 5. Apple compliance

- System fonts only. `-apple-system` and `ui-monospace`. No web fonts, which
  also holds the no-external-requests rule.
- Dynamic colours. Both accents ship light and dark values, switched by
  `prefers-color-scheme`.
- No Apple logo. Apple's marketing guidelines do not permit the mark for
  third-party promotion. The button reads "Download for macOS" in text.
- A trademark line in the footer: Apple and macOS are trademarks of Apple Inc.
- Hit targets of 44 by 44 points or more, visible keyboard focus, full keyboard
  navigation of the sidebar, and `prefers-reduced-motion` respected.

## 6. SEO and GEO

- Per-page `title`, `description` and `canonical`.
- Open Graph and Twitter cards. Copy `assets/art/github/social-preview-1280x640.png`
  into `site/`.
- `sitemap.xml` and `robots.txt`.
- `SoftwareApplication` JSON-LD carrying `softwareVersion`, `operatingSystem`
  and `downloadUrl`.
- `FAQPage` JSON-LD built from the Docs definitions.
- All static. No third-party request.

## 7. Sequencing and risk

**The release is a draft.** A draft release is invisible to the public, so the
Download button 404s for every visitor until Carlos publishes it. The site must
not deploy before the release is public. Acceptance includes an HTTP check that
the DMG URL returns 200.

**Icon rework is deferred.** The accent change makes the shipped rasters
inconsistent. Measured over `site/` on 2026-08-04, six rasters carry `#76b900`:

| File | Accent pixels |
|---|---|
| `site/icon-512.png` | 27942 |
| `site/icon-512-maskable.png` | 14412 |
| `site/icon-192.png` | 3840 |
| `site/apple-touch-icon-180.png` | 3418 |
| `site/favicon-32.png` | 104 |
| `site/favicon-16.png` | 15 |

Two SVGs carry it too: `site/appicon-light.svg` and `site/appicon-dark.svg`.
`site/favicon.svg` is monochrome and needs no change.

This project re-cuts those six rasters and two SVGs. Re-cutting
`assets/art/appicon/**` and `assets/art/github/**`, and rebuilding
`AppIcon.icns`, is a separate follow-up. Until it lands the installed app icon
stays green while the site is roast.

**Brand documentation.** `assets/art/README.md` states one accent and forbids a
second. The two-colour state/action split changes that rule. Update that file in
the same change, or the source of truth contradicts the site.

## 8. Out of scope

- Re-cutting the app icon, the iconset, the `.icns`, and the GitHub art.
- Bumping the Homebrew tap from v0.1.0 to v0.1.1.
- Adding DMG build, signing and notarisation to `release.yml`.
- Any claim about token accounting, battery savings, or measured durations. The
  honesty constraints in the current `site/index.html` header carry forward
  unchanged.

## 9. Acceptance

```
swift test
swift test --filter "everyDocumentedSurfaceIsReadableAndSubstantial|theGuardStillMatchesRealClaims|everyDurationStatedIsARealProductConstant|everyControlNamedExistsInTheProduct|aBoundaryPhraseMatchesTheRealBoundary|theProseHookCountMatchesTheRequiredEventCount|theBatteryFloorStatedIsTheRealDefault"
```

Plus, once the release is public:

```
curl -sIL -o /dev/null -w '%{http_code}\n' \
  https://github.com/ArangoGutierrez/coffee-bar/releases/download/v0.1.1/coffee-bar-0.1.1.dmg
```
