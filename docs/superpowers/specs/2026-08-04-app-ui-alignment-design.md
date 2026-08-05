# Align the app UI with the site palette — design

Date: 2026-08-04
Branch: `feat/app-ui-alignment`, cut from `origin/main` at `0bb5f12`
Milestone: v0.2

## 1. Purpose

The site ships the roast and orange two-colour system. The app ships no brand
colour at all, and the art package still carries `#76B900`. This project moves
the app and the art package onto the site's system.

## 2. Verified state

Every number below comes from a command run against this worktree at `0bb5f12`
on 2026-08-04. The seed document
(`.superpowers/sdd/2026-08-04-app-ui-alignment/NEXT-app-ui-alignment.md`) was
re-checked line by line. Its palette, its census and its brand-doc claim all
hold. Three of its other claims do not.

### 2.1 Confirmed

| Claim | Value |
|---|---|
| Rasters carrying `#76B900` | 40 — `appicon/` 24, `web/` 8, `github/` 4, `wordmark/` 4 |
| Vector and doc files carrying it | 6 |
| Accent or tint in `Sources/` | none — `grep -rE "accentColor\|\.tint\(\|AccentColor" Sources/` returns 0 |
| Panel colours | `.secondary` and `.orange` only |
| `assets/art/README.md` carries the two-colour system | true — the palette table is at lines 12–16 |

### 2.2 Corrected

| Seed claim | Verified state |
|---|---|
| A user sees "a green cup in the menu bar" | The menu-bar glyphs are monochrome `fill="#000"` templates. They are never green. |
| A user installs "the DMG" | No DMG exists, and no packaged `.app` artifact exists. `release.yml` builds and verifies `coffee-bar-probe` only. |
| `DocsClaims_test` and `SiteClaims_test` read `assets/art/README.md` | They do not. `grep -ra "assets/art" Tests/` returns 0, with a passing control search. They read `README.md`, `CHANGELOG.md`, `docs/*.md` and `site/*.html`. |

### 2.3 New facts the seed does not carry

1. **The app bundle has no icon.** `scripts/build-app.sh` copies menu-bar glyphs
   only and sets no `CFBundleIconFile`. No `.icns` was ever committed:
   `git log --all --diff-filter=A -- '*.icns'` is empty. The re-cut icon must be
   wired in, or it reaches no user.
2. **`actool` requires full Xcode.** `DEVELOPER_DIR=/nonexistent actool
   --version` fails with `xcrun: error: missing DEVELOPER_DIR path`.
   `/usr/bin/actool` carries 16 hard links, so it is the shared `xcrun` shim.
   `iconutil` is a real binary with 1 link and still runs with a bogus
   `DEVELOPER_DIR`.
3. **The recoloured vector geometry already exists.** `site/appicon-light.svg`
   and `site/appicon-dark.svg` differ from `assets/art/appicon/svg/AppIcon-default.svg`
   and `AppIcon-dark.svg` by exactly one token: the liquid `<rect>` fill.
   `site/appicon-web.svg` is the same geometry on the web tile `#F2F0EB`.
4. **`web/` has a source after all.** The brand doc states the web rasters are
   cut from `site/appicon-web.svg`, and that file exists and carries `#A2571E`.
5. **Nine sets of rasters are byte-identical duplicates**, compared by SHA-256
   of their RGBA bytes. `github/repo-avatar-1024.png` is the dark appicon render
   at 1024. `github/repo-avatar-512.png`, `web/icon-512-dark.png` and the dark
   appicon render at 512 are one image. The whole `AppIcon.iconset` duplicates
   the light `png/default/` renders. So both GitHub avatars have a source, and
   only **6** rasters do not: the two composite `github/` images and the four
   `wordmark/` files.

   A note on method: `ImageChops.difference(a, b).getbbox()` reports `None` for
   two RGBA images that differ in RGB, because the difference alpha is zero
   everywhere and Pillow treats fully transparent pixels as empty. That produced
   a false "identical" reading. Compare content hashes, not `getbbox`.
6. **The brand doc's unfinished-recolour note omits `wordmark/`.** Lines 40–45
   name `appicon/**`, `web/**` and `github/**`. The census shows `wordmark/`
   carries 4 green rasters.
7. **The note calls the re-cut "a tracked follow-up", and no such issue exists.**
   The full issue list holds nothing about art, icons, palette or recolour.
8. **The note says "the installed app icon stays green".** There is no installed
   app icon. Fact 1 contradicts this sentence.

## 3. The brand rule this design obeys

`assets/art/README.md` lines 18–20 state:

> **Never mix `state` and `action`.** `state` colours the liquid and the held
> segments — in the icon system it is used **only** for the liquid. `action`
> colours buttons, links and focus rings, and appears on the web only.

Decision D3 complies. The selected segment of a `Picker` is a **held segment**,
so `state` is the correct role for it. `action` stays off the app, exactly as the
rule requires. The panel keeps `.orange` for warnings, which is a system
semantic colour rather than the brand's `action` role.

Line 102 forbids "a third accent colour". This design adds none.

## 4. Decisions

| # | Decision | Who |
|---|---|---|
| D1 | Re-cut the icon **and** wire it into the bundle. | Carlos, over a panel HARD-DISSENT that asked for two PRs. |
| D2 | Deliver the accent with SwiftUI `.tint()` from the model. Add no asset catalog. | Carlos, over a panel HARD-DISSENT that asked for a catalog follow-up. |
| D3 | `state` tints the controls. `.orange` stays reserved for warnings. | Carlos, from mockups. |
| D4 | The indicator is a cup glyph: filled when holding, outline when released. | Carlos, from mockups. |
| D5 | Re-cut from source where a source exists. Hue-remap the rest. | Carlos. |
| D6 | Rasterize with `librsvg`. Headless Chrome is the documented fallback. | Chief, after Carlos expressed no preference. |

D2 rejects the seed's `AccentColor` asset. `actool` requires full Xcode, while
the Homebrew tap builds from a tarball on machines that may carry only the
Command Line Tools. The app declares exactly one `Scene`, a `MenuBarExtra`, and
that scene holds every control the app owns, so `.tint()` reaches all of them.

## 5. Goals and non-goals

**Goals**

1. No `#76B900` remains in `assets/art/` or in the app.
2. The app bundle carries an icon in the new palette.
3. The panel shows a status indicator that does not rely on colour alone.
4. `assets/art/README.md` matches the finished state.

**Non-goals**

- The menu-bar glyphs stay monochrome. This is a brand rule and a platform
  requirement.
- `site/` is already re-cut. This project does not change it.
- No asset catalog, and no `actool` in the build.
- No DMG, no signing, no notarisation. Those are M4.

## 6. The colour system

### 6.1 Where it lives

`Sources/CoffeeBarUI/BrandPalette.swift` owns every value. `ServingModel` owns
the mapping from state to role. The view holds no colour decision, because M1
design §5.4 rules out asserting on rendered AppKit text.

```
enum ColorRole { case state, rest, warning }

struct IndicatorSpec: Equatable {
    let symbolName: String
    let role: ColorRole
}

// Pure and static, so a test calls it without rendering a view.
extension ServingModel {
    static func indicator(isServing: Bool) -> IndicatorSpec
}

enum BrandPalette {
    struct RGB: Equatable { let r, g, b: Double; init(hex: String) }

    // nil for .warning, which is SwiftUI's semantic .orange and has no fixed
    // value. Pinning a hex there would stop it adapting.
    static func rgb(_ role: ColorRole,
                    scheme: ColorScheme,
                    contrast: ColorSchemeContrast) -> RGB?

    static func color(_ role: ColorRole,
                      scheme: ColorScheme,
                      contrast: ColorSchemeContrast) -> Color

    static func contrastRatio(_ a: RGB, against b: RGB) -> Double
}
```

`rgb` returns components, so a test asserts numbers. `color` wraps `rgb` and is
the only call the view makes.

### 6.2 The values

| Role | Light | Dark | Job |
|---|---|---|---|
| `state` | `#A2571E` | `#B8682A` | the liquid; held segments |
| `rest` | `#6B7683` | `#6B7683` | released |
| `warning` | system `.orange` | system `.orange` | attention |

`warning` is the SwiftUI semantic colour and never a hex. It adapts to the
appearance and to Increase Contrast at no cost. The panel uses it today at
`PanelView.swift` lines 193, 215 and 231.

### 6.3 Increased contrast

`state` and `rest` are fixed hexes and do not adapt on their own. The implementer
derives one increased-contrast variant per appearance.

This spec states no variant hex, because none has been measured. Inventing one
here would ship an untested literal.

Acceptance is a measurement, not a value chosen by eye:

- the indicator is a non-text graphic and needs **at least 3:1** against its
  background;
- any brand colour behind a text label needs **at least 4.5:1**.

**Re-measure the backdrop.** The brand doc's ratios at lines 25–30 are measured
against the art tiles `#F2F0EB` (light) and `#101013` (dark). The panel sits on
macOS vibrancy material, which is neither. Those ratios do not transfer. Measure
against the panel's real background and record the result in the task report.

## 7. The panel

Changes to `Sources/CoffeeBarUI/PanelView.swift`:

1. Apply `.tint(BrandPalette.color(.state, …))` to the panel content. Both
   `Picker`s and the Quit `Button` follow it.
2. Put the indicator on the `servingSummary` line. Holding shows
   `cup.and.saucer.fill` in `state`. Released shows `cup.and.saucer` in `rest`.
   Both symbols already appear at line 25 as the `MenuBarLabel` fallback, so the
   vocabulary does not change.
3. Leave the three advisory lines on `.orange`.
4. Leave every text style on `.secondary` or `.primary`.

The indicator changes **shape as well as colour**, so a user with Differentiate
Without Color still tells the states apart. The text label stays, so colour is
never the sole carrier.

## 8. The app icon

`scripts/build-app.sh` gains an icon step after the glyph copy:

1. Build `AppIcon.icns` from `assets/art/appicon/AppIcon.iconset` with
   `iconutil`, which needs no Xcode, so the Homebrew path stays intact.
2. Copy the `.icns` into `Contents/Resources/`.
3. Add `CFBundleIconFile` to the generated `Info.plist`.
4. Verify. Assert the file is in the bundle and read the key back with
   `plutil -extract`. The script already treats a `cp` exit code as no evidence,
   and this step follows that rule.

`make-icns.sh` renames `-2x` files to `@2x` **in place**. A build must not mutate
the tracked tree, so the new step copies the iconset to a temporary directory,
renames there, and runs `iconutil` on the copy.

## 9. The art re-cut

### 9.1 Track A — from source, 34 rasters

The recolour is a single hex substitution per file, already validated by the site
redesign.

1. Substitute the liquid fill in five files: `layers/default-3-liquid.svg`,
   `layers/dark-3-liquid.svg`, `AppIcon.icon/Assets/liquid.svg`,
   `svg/AppIcon-default.svg` and `svg/AppIcon-dark.svg`. Dark files take the dark
   value. The `mono` layers carry no accent and stay unchanged.
2. Rasterize `appicon/png/{default,dark}/` at every committed size with
   `rsvg-convert`.
3. Rasterize `web/` from `site/appicon-web.svg`, which already carries `#A2571E`.
   `icon-512-maskable.png` insets the art by 0.72 about the canvas centre, per
   the brand doc.
4. Rebuild `AppIcon.iconset`, then `AppIcon.icns`.

Each regenerated file is compared against its site twin where one exists. The
flattened SVGs must differ from `site/appicon-{light,dark}.svg` by nothing at
all once the substitution lands.

### 9.2 Track B — hue remap, 6 rasters

Six files have no vector source: `github/readme-header-1600x400.png`,
`github/social-preview-1280x640.png` and the four `wordmark/` rasters. A scripted
per-pixel remap rotates the green hue onto `state` and preserves each pixel's
saturation, value and alpha, so anti-aliased edges do not fringe.

All six carry typography or composite layout that a remap can degrade. If a
visual check fails, those files leave this project and become a separate art
task. They do not ship degraded.

### 9.3 Per-file census, required

A failed image conversion leaves the old file in place and exits 0. Check every
regenerated raster one file at a time:

- zero pixels of exact `#76B900`, and zero pixels inside the green hue band;
- a non-zero count of the new accent;
- unchanged pixel size and colour mode.

**Assert the count of files checked** against the census in §2.1. A guard reads
what a file says and cannot see a file it never opened, so a silently skipped
file must fail the check.

## 10. Brand doc

`assets/art/README.md` keeps its palette table. Four things change:

1. Remove or rewrite the unfinished-recolour note at lines 40–45 once the re-cut
   lands.
2. That note omits `wordmark/`. Any interim version must name it.
3. The note says "the installed app icon stays green". No installed icon exists.
   Delete the claim.
4. The note calls the re-cut "a tracked follow-up" and no issue exists. Either
   open one or drop the phrase.

No test reads this file, so no guard catches an error here. A human reviews it.

## 11. Testing

| What | How |
|---|---|
| `ServingModel.indicator(isServing:)` | Assert both mappings, and assert the two symbol names differ so shape carries meaning without colour. |
| `BrandPalette.rgb` | Assert components for each role, appearance and contrast. |
| Contrast | Compute the ratio from `rgb` and assert the §6.3 thresholds. |
| Rasters | The per-file census in §9.3. |
| Icon in bundle | Run `scripts/build-app.sh`; assert the `.icns` is in `Contents/Resources` and `plutil -extract CFBundleIconFile` reads it back. |
| Whole suite | `swift test`, and `node --test site/assets/bench.test.js`. |

`swift test` cannot see rendered AppKit text. A green suite is not evidence the
panel looks right. Launch the app, screenshot it, and confirm the image is
non-trivial before reading it.

## 12. Risks

| Risk | Mitigation |
|---|---|
| A hue remap fringes the wordmark or the social preview. | §9.2. Those 6 files fall out to a separate task rather than ship degraded. |
| `brew install librsvg` fails or is unwanted. | Headless Chrome is installed and was used for the site last session. |
| Increased-contrast variants get chosen by eye. | §6.3 makes the threshold a measurement asserted by a test. |
| The icon step breaks the Homebrew build. | The step uses `iconutil` only, which runs without Xcode. Verified. |
| A stale checkout misleads the implementer. | Work only in this worktree. The repo's default checkout sits on a dead branch, `feat/site-multipage`, whose `assets/art/README.md` differs. |

## 13. Out of scope, worth an issue

- The two composite `github/` images and the four `wordmark/` rasters have no
  vector source. The art arrives as an external zip export. A follow-up should
  author real sources so the package rebuilds.
- An `AccentColor` asset becomes cheap once M4 requires full Xcode on the release
  machine. Revisit D2 then.
