# App UI Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the coffee-bar app and its art package off `#76B900` onto the site's roast two-colour system, and ship an app icon for the first time.

**Architecture:** A new `BrandPalette` in `CoffeeBarUI` owns every colour value. `ServingModel` maps state to a role through a pure static function, so tests read colour decisions without rendering AppKit. `PanelView` only consumes those. `scripts/build-app.sh` gains an `iconutil` step that puts an `.icns` in the bundle. The art re-cut recolours five SVGs and re-rasterises from them.

**Tech Stack:** Swift 6 (`swiftLanguageMode(.v6)`), swift-testing (`import Testing`), SwiftUI, `librsvg` (`rsvg-convert`), `iconutil`, Python 3 with Pillow.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-08-04-app-ui-alignment-design.md`. Read it first.
- Work only in the worktree `.worktrees/app-ui-alignment` on branch `feat/app-ui-alignment`. The repo's default checkout sits on the dead branch `feat/site-multipage`, where `assets/art/README.md` is a **different file**. Every path below is relative to the worktree root.
- Every commit is signed: `git commit -s -S`.
- Conventional commit format `type(scope): description`.
- **Never** colour the menu-bar glyphs. They stay `fill="#000"` plus alpha. Brand rule and platform requirement.
- **Never mix `state` and `action`** (`assets/art/README.md` lines 18–20). `action` (`systemOrange`) appears on the web only. The app uses `state` for held segments and SwiftUI's semantic `.orange` for warnings.
- Do not add a third accent colour (`assets/art/README.md` line 102).
- Do not touch `site/**`. It is already re-cut.
- Do not run `git push` or any `gh` write subcommand. Report instead; Carlos performs outward actions.
- Palette values, copied verbatim from `assets/art/README.md` lines 14–16:
  | Role | Light | Dark |
  |---|---|---|
  | state | `#A2571E` | `#B8682A` |
  | rest | `#6B7683` | `#6B7683` |
- **Run every `swift` command with the agent sandbox DISABLED.** SwiftPM starts its own `sandbox-exec`, which cannot nest inside the agent's, and it reports the failure as `error: Invalid manifest` — sending you after a `Package.swift` that is perfectly fine. The real cause appears one line earlier as `sandbox-exec: sandbox_apply: Operation not permitted`. `scripts/build-app.sh` documents the same trap for Homebrew. This applies to `swift build`, `swift test` and `scripts/build-app.sh`.
- **Baseline, measured on the rebased branch before any task: `swift test` → `Test run with 573 tests in 4 suites passed`, rc=0.** Any task that ends below 573 passing has broken something.
- Temporary files go under `"${TMPDIR:-/tmp}"`. A bare `/tmp/...` write is denied in the sandbox.
- `swift test` cannot see rendered AppKit text (M1 design §5.4). A green suite is never evidence that the panel looks right.

---

### Task 1: BrandPalette and the indicator mapping

Creates the whole colour system in the model layer. Nothing renders yet.

**Files:**
- Create: `Sources/CoffeeBarUI/BrandPalette.swift`
- Create: `Tests/CoffeeBarUITests/BrandPalette_test.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ColorRole`, `BrandPalette.RGB`, `BrandPalette.rgb(_:scheme:contrast:) -> RGB?`, `BrandPalette.color(_:scheme:contrast:) -> Color`, `BrandPalette.contrastRatio(_:against:) -> Double`, `IndicatorSpec(symbolName:role:)`, `ServingModel.indicator(isServing:) -> IndicatorSpec`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarUITests/BrandPalette_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI
import Testing
@testable import CoffeeBarUI

// The two backgrounds are the WORST plausible panel backdrop in each
// appearance. macOS vibrancy material is not a fixed colour, so a single
// reference would be a guess. These bound the range instead: a ratio that
// holds here holds anywhere lighter (light) or darker (dark).
private let worstLightBackdrop = "#E5E5E5"
private let worstDarkBackdrop = "#232326"

@Test("state and rest carry the exact brand-doc values")
func paletteBaseValuesMatchBrandDoc() throws {
    // assets/art/README.md lines 14-16.
    let cases: [(ColorRole, ColorScheme, String)] = [
        (.state, .light, "#A2571E"),
        (.state, .dark, "#B8682A"),
        (.rest, .light, "#6B7683"),
        (.rest, .dark, "#6B7683"),
    ]
    for (role, scheme, hex) in cases {
        let got = try #require(BrandPalette.rgb(role, scheme: scheme, contrast: .standard))
        #expect(got == BrandPalette.RGB(hex: hex), "\(role) \(scheme) should be \(hex)")
    }
}

@Test("warning has no fixed value because it is a system semantic colour")
func warningHasNoFixedValue() {
    #expect(BrandPalette.rgb(.warning, scheme: .light, contrast: .standard) == nil)
    #expect(BrandPalette.rgb(.warning, scheme: .dark, contrast: .standard) == nil)
}

@Test("every fixed role clears 3:1 on the worst plausible panel backdrop")
func fixedRolesClearNonTextContrast() throws {
    for role in [ColorRole.state, .rest] {
        for (scheme, backdrop) in [(ColorScheme.light, worstLightBackdrop),
                                   (ColorScheme.dark, worstDarkBackdrop)] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let rgb = try #require(BrandPalette.rgb(role, scheme: scheme, contrast: contrast))
                let ratio = BrandPalette.contrastRatio(rgb, against: BrandPalette.RGB(hex: backdrop))
                #expect(ratio >= 3.0,
                        "\(role)/\(scheme)/\(contrast) on \(backdrop) was \(ratio), needs >= 3.0")
            }
        }
    }
}

@Test("increased contrast never reduces the ratio")
func increasedContrastNeverRegresses() throws {
    for role in [ColorRole.state, .rest] {
        for (scheme, backdrop) in [(ColorScheme.light, worstLightBackdrop),
                                   (ColorScheme.dark, worstDarkBackdrop)] {
            let back = BrandPalette.RGB(hex: backdrop)
            let normal = try #require(BrandPalette.rgb(role, scheme: scheme, contrast: .standard))
            let raised = try #require(BrandPalette.rgb(role, scheme: scheme, contrast: .increased))
            #expect(BrandPalette.contrastRatio(raised, against: back)
                    > BrandPalette.contrastRatio(normal, against: back),
                    "\(role)/\(scheme) increased must beat standard")
        }
    }
}

@Test("the indicator distinguishes the two states by SHAPE, not only colour")
func indicatorDiffersBySymbolNotOnlyColour() {
    let holding = ServingModel.indicator(isServing: true)
    let released = ServingModel.indicator(isServing: false)

    #expect(holding.symbolName == "cup.and.saucer.fill")
    #expect(released.symbolName == "cup.and.saucer")
    // The bug this catches: someone "simplifies" the indicator to one symbol
    // recoloured. Then Differentiate Without Color erases the distinction.
    #expect(holding.symbolName != released.symbolName)
    #expect(holding.role == .state)
    #expect(released.role == .rest)
}

@Test("a known contrast pair computes the published ratio")
func contrastRatioIsCorrect() {
    // #A2571E on #F2F0EB is 4.71 in assets/art/README.md line 29.
    let ratio = BrandPalette.contrastRatio(BrandPalette.RGB(hex: "#A2571E"),
                                           against: BrandPalette.RGB(hex: "#F2F0EB"))
    #expect(abs(ratio - 4.71) < 0.01, "expected 4.71, got \(ratio)")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter BrandPalette`
Expected: FAIL to compile, with `cannot find 'BrandPalette' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CoffeeBarUI/BrandPalette.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

// `import Foundation` is explicit for `Scanner`. Do not rely on SwiftUI
// re-exporting it — the rest of this module states its imports the same way.
import Foundation
import SwiftUI

/// What a colour MEANS here, never which colour it is.
///
/// The brand doc (assets/art/README.md lines 18-20) forbids mixing `state` and
/// `action`: `action` is systemOrange and belongs to the web. The app therefore
/// carries no `action` case at all — the type makes the brand rule unstatable.
public enum ColorRole: Sendable, Equatable {
    /// The liquid, and the held segments. Roast.
    case state
    /// Released. Neutral grey.
    case rest
    /// Attention. A SYSTEM semantic colour, so it has no fixed value.
    case warning
}

/// What the panel draws beside the serving summary.
///
/// `symbolName` is load-bearing for accessibility, not decoration. The two
/// states differ in SHAPE — filled versus outline — so the indicator survives
/// Differentiate Without Color. Colour alone would not.
public struct IndicatorSpec: Equatable, Sendable {
    public let symbolName: String
    public let role: ColorRole

    public init(symbolName: String, role: ColorRole) {
        self.symbolName = symbolName
        self.role = role
    }
}

/// Every brand colour value in the app.
///
/// This exists because M1 design §5.4 rules out asserting on rendered AppKit
/// text. A colour chosen inside a `View` body is a decision no test can read.
/// `rgb` returns components so a test asserts numbers; `color` is the only call
/// a view makes.
public enum BrandPalette {
    public struct RGB: Equatable, Sendable {
        public let r: Double
        public let g: Double
        public let b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// Accepts `#RRGGBB`. Traps on anything else: every call site in this
        /// module passes a literal from the brand doc, so a malformed string is
        /// a programming error, not a runtime condition to recover from.
        public init(hex: String) {
            let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            precondition(s.count == 6, "BrandPalette.RGB(hex:) needs #RRGGBB, got \(hex)")
            var value: UInt64 = 0
            precondition(Scanner(string: s).scanHexInt64(&value),
                         "BrandPalette.RGB(hex:) could not parse \(hex)")
            self.r = Double((value & 0xFF0000) >> 16) / 255
            self.g = Double((value & 0x00FF00) >> 8) / 255
            self.b = Double(value & 0x0000FF) / 255
        }

        func blended(toward other: RGB, fraction f: Double) -> RGB {
            RGB(r: r + (other.r - r) * f,
                g: g + (other.g - g) * f,
                b: b + (other.b - b) * f)
        }
    }

    // Verbatim from assets/art/README.md lines 14-16.
    private static let stateLight = RGB(hex: "#A2571E")
    private static let stateDark = RGB(hex: "#B8682A")
    private static let rest = RGB(hex: "#6B7683")

    /// How far an increased-contrast variant moves toward the appearance's
    /// extreme. A COMPUTED rule rather than two more hand-picked hexes: a hex
    /// chosen by eye is an untested literal, and the tests assert the ratio it
    /// has to achieve instead.
    private static let increasedContrastBlend = 0.30

    /// `nil` for `.warning`, which is SwiftUI's semantic `.orange`. That colour
    /// already adapts to appearance and to Increase Contrast at no cost, so
    /// pinning a hex here would make it WORSE.
    public static func rgb(_ role: ColorRole,
                           scheme: ColorScheme,
                           contrast: ColorSchemeContrast) -> RGB? {
        let base: RGB
        switch role {
        case .state:
            base = (scheme == .dark) ? stateDark : stateLight
        case .rest:
            base = rest
        case .warning:
            return nil
        }
        guard contrast == .increased else { return base }
        // Light appearance darkens toward black; dark appearance lightens
        // toward white. Both move AWAY from their own backdrop.
        let extreme = (scheme == .dark) ? RGB(r: 1, g: 1, b: 1) : RGB(r: 0, g: 0, b: 0)
        return base.blended(toward: extreme, fraction: increasedContrastBlend)
    }

    public static func color(_ role: ColorRole,
                             scheme: ColorScheme,
                             contrast: ColorSchemeContrast) -> Color {
        guard let rgb = rgb(role, scheme: scheme, contrast: contrast) else {
            return .orange
        }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    /// WCAG 2.1 relative luminance and contrast ratio.
    public static func contrastRatio(_ a: RGB, against b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }
}
```

Append to `Sources/CoffeeBarUI/ServingModel.swift`, at the end of the file, outside the existing type body:

```swift
extension ServingModel {
    /// What the panel draws beside `servingSummary`.
    ///
    /// `static` and `nonisolated` on purpose. A swift-testing `@Test` function
    /// is nonisolated, and `ServingModel` is main-actor isolated, so an
    /// instance method here could not be called from a test without annotating
    /// the test `@MainActor` — which would hide the property rather than test
    /// it. This takes a Bool and returns a value; it holds no actor state.
    nonisolated public static func indicator(isServing: Bool) -> IndicatorSpec {
        isServing
            ? IndicatorSpec(symbolName: "cup.and.saucer.fill", role: .state)
            : IndicatorSpec(symbolName: "cup.and.saucer", role: .rest)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter BrandPalette`
Expected: PASS, 6 tests.

- [ ] **Step 5: Prove the shape test discriminates**

Temporarily change `"cup.and.saucer"` to `"cup.and.saucer.fill"` in the `indicator` function, so both states return the same symbol.

Run: `swift test --filter indicatorDiffersBySymbolNotOnlyColour`
Expected: FAIL. If it passes, the test is theater — fix it before continuing.

Revert the change. Re-run and confirm PASS.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS. Record the total count for the report.

- [ ] **Step 7: Commit**

```bash
git add Sources/CoffeeBarUI/BrandPalette.swift Tests/CoffeeBarUITests/BrandPalette_test.swift Sources/CoffeeBarUI/ServingModel.swift
git commit -s -S -m "feat(ui): add the brand palette and the indicator mapping

Colour decisions live in the model because M1 design §5.4 rules out
asserting on rendered AppKit text. ColorRole carries no action case, so
the brand rule that state and action never mix cannot be broken here.

Increased contrast is a computed blend rather than two more hand-picked
hexes, and the tests assert the ratio it must reach."
```

---

### Task 2: Wire the palette into the panel

**Files:**
- Modify: `Sources/CoffeeBarUI/PanelView.swift`

**Interfaces:**
- Consumes: `BrandPalette.color(_:scheme:contrast:)`, `ServingModel.indicator(isServing:)`, `IndicatorSpec`.
- Produces: nothing other tasks read.

- [ ] **Step 1: Read the current file**

Read `Sources/CoffeeBarUI/PanelView.swift` in full. The `.orange` advisory lines are at 193, 215 and 231. **They do not change.** Orange means attention, and only attention.

The panel has **three** segmented pickers, not two: Serving (110), Display (137) and Battery floor (159).

- [ ] **Step 1b: Write the failing guard test**

M1 design §5.4 rules out asserting on rendered AppKit text, so nothing can read what the panel DRAWS. This reads what it SAYS to draw. The repo already uses that shape in `AppLayerBoundary_test.swift` and `DocsClaims_test.swift`.

Create `Tests/CoffeeBarUITests/PanelPaletteWiring_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// Reads `PanelView.swift` as text. `#filePath` anchors the lookup to THIS
/// source file, never to an installed or deployed copy, so the guard cannot
/// green-light a different tree than the one under test.
private func panelSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    return try String(
        contentsOf: root.appendingPathComponent("Sources/CoffeeBarUI/PanelView.swift"),
        encoding: .utf8)
}

@Test("the panel tints from the model, never from a literal")
func panelTintsFromTheModel() throws {
    let source = try panelSource()
    #expect(source.contains(".tint(brand(.state))"),
            "the panel must take its tint from BrandPalette via brand(.state)")

    // The bug this catches: someone hardcodes a hex in the view, where no test
    // can read it. That is the exact failure BrandPalette exists to prevent.
    let hexLiteral = try Regex("#[0-9A-Fa-f]{6}")
    #expect(source.firstMatch(of: hexLiteral) == nil,
            "PanelView must contain no colour literal; values live in BrandPalette")
}

@Test("the indicator comes from the model, not from a symbol name typed here")
func indicatorComesFromTheModel() throws {
    let source = try panelSource()
    #expect(source.contains("ServingModel.indicator("),
            "the indicator must come from ServingModel.indicator(isServing:)")
}

@Test("orange is spent on exactly the three advisory lines")
func orangeIsSpentOnlyOnTheAdvisories() throws {
    let source = try panelSource()
    let occurrences = source.components(separatedBy: ".foregroundStyle(.orange)").count - 1

    // A COUNT, not a presence check. A guard reads what a file says and cannot
    // see what it omits, so presence alone would stay green if a fourth orange
    // element appeared or an advisory silently lost its colour. This panel has
    // already shipped one undocumented control; the count is what catches the
    // next one.
    #expect(occurrences == 3,
            "expected 3 orange advisory lines, found \(occurrences)")
}
```

- [ ] **Step 1c: Run it and watch it fail**

Run: `swift test --filter PanelPaletteWiring`
Expected: FAIL on `panelTintsFromTheModel` — `.tint(brand(.state))` does not exist yet. `orangeIsSpentOnlyOnTheAdvisories` should already PASS at 3; that is the pre-existing state it pins.

- [ ] **Step 2: Add the environment readers**

Inside `public struct PanelView: View`, directly after `@Bindable var model: ServingModel`, add:

```swift
    // Read here rather than inside BrandPalette so the palette stays a pure
    // value type that a test can call without an Environment.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private func brand(_ role: ColorRole) -> Color {
        BrandPalette.color(role, scheme: colorScheme, contrast: colorSchemeContrast)
    }
```

- [ ] **Step 3: Put the indicator on the serving summary**

Replace the `Text(model.servingSummary)` block (it currently carries `.font(.caption)`, `.foregroundStyle(.secondary)` and `.fixedSize`) with:

```swift
            // The indicator is the only place brand colour touches the panel
            // body, and it is a GRAPHIC, not text — 3:1, not 4.5:1. The symbol
            // changes shape as well as colour (filled versus outline), so the
            // state survives Differentiate Without Color. The sentence beside
            // it stays, so colour is never the sole carrier.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                let spec = ServingModel.indicator(isServing: model.isServing)
                Image(systemName: spec.symbolName)
                    .foregroundStyle(brand(spec.role))
                    .accessibilityHidden(true)
                Text(model.servingSummary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
```

`accessibilityHidden(true)` is deliberate: the sentence already states the same fact, so an unhidden image would make VoiceOver say it twice.

- [ ] **Step 4: Tint the controls**

On the outermost `VStack`, directly after `.frame(width: 260)`, add. This
reaches all three pickers, the Quit button and `AttentionListView` — that is
intended, not a side effect:

```swift
        // `state` colours the held segments, which is exactly what a selected
        // segment is (assets/art/README.md lines 18-20). `action` is the web's
        // colour and never appears in the app.
        .tint(brand(.state))
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds with no error and no new warning.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS, same count as Task 1 Step 6.

- [ ] **Step 7: Look at it**

```bash
scripts/build-app.sh
open build/CoffeeBar.app
```

Open the panel from the menu bar. Confirm by eye:
1. the selected segment of all THREE pickers (Serving, Display, Battery floor) is roast, not blue;
2. the cup beside the summary is filled and roast while holding;
3. it becomes a grey outline after choosing `Off`;
4. any advisory line is still orange.

Screenshot the open panel. Check the file is larger than 10 kB before reading it — a truncated capture is a common false pass. Attach it to the task report.

- [ ] **Step 8: Commit**

```bash
git add Sources/CoffeeBarUI/PanelView.swift Tests/CoffeeBarUITests/PanelPaletteWiring_test.swift
git commit -s -S -m "feat(ui): tint the panel with the brand state colour

The selected segment of a picker is a held segment, so state is the
correct role for it. Orange stays reserved for the three advisory lines,
so one hue now means exactly one thing.

The indicator changes shape as well as colour, which is what keeps it
readable under Differentiate Without Color."
```

---

### Task 3: Ship an app icon in the bundle

The bundle has never carried an icon. `git log --all --diff-filter=A -- '*.icns'` is empty.

**Files:**
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `assets/art/appicon/AppIcon.iconset/` (10 PNGs).
- Produces: `build/CoffeeBar.app/Contents/Resources/AppIcon.icns` and the `CFBundleIconFile` key.

- [ ] **Step 1: Confirm the gap**

```bash
scripts/build-app.sh
ls build/CoffeeBar.app/Contents/Resources/
plutil -extract CFBundleIconFile raw -o - build/CoffeeBar.app/Contents/Info.plist; echo "rc=$?"
```
Expected: only the 8 glyph files, and a non-zero rc for the missing key. Record both.

- [ ] **Step 2: Add the icon step**

In `scripts/build-app.sh`, after the block that ends `echo "    ${glyph_count} glyph files copied"` and before the `--- Info.plist ---` section, insert:

```bash
# --- app icon ---------------------------------------------------------------
#
# The bundle carried no icon at all until now, so Finder drew the generic one.
#
# `iconutil` is used rather than `actool` deliberately. `actool` is the shared
# xcrun shim and needs a full Xcode: `DEVELOPER_DIR=/nonexistent actool
# --version` fails with "missing DEVELOPER_DIR path". `iconutil` is a real
# binary and still runs without one. The Homebrew formula builds from a tarball
# on machines that may carry only the Command Line Tools, so requiring Xcode
# here would break install for those users.
#
# The iconset is COPIED before use. `assets/art/appicon/make-icns.sh` renames
# `-2x` to `@2x` in place, and a build must never mutate the tracked tree.

ICONSET_SRC="${REPO_ROOT}/assets/art/appicon/AppIcon.iconset"
[ -d "${ICONSET_SRC}" ] || die "iconset not found at ${ICONSET_SRC}"

ICON_TMP="$(mktemp -d)"
trap 'rm -rf "${ICON_TMP}"' EXIT

command cp -R "${ICONSET_SRC}" "${ICON_TMP}/AppIcon.iconset"

# The export pipeline strips `@` from filenames (assets/art/README.md). iconutil
# requires it back. Rename inside the COPY.
for f in "${ICON_TMP}/AppIcon.iconset"/*-2x.png; do
    [ -f "${f}" ] || continue
    mv "${f}" "${f%-2x.png}@2x.png"
done

iconutil -c icns "${ICON_TMP}/AppIcon.iconset" -o "${CONTENTS}/Resources/AppIcon.icns" \
    || die "iconutil failed to build AppIcon.icns"

# `iconutil` can report success and write nothing useful.
[ -s "${CONTENTS}/Resources/AppIcon.icns" ] \
    || die "AppIcon.icns is missing or empty in the bundle"
echo "    app icon: $(wc -c <"${CONTENTS}/Resources/AppIcon.icns" | tr -d ' ') bytes"
```

- [ ] **Step 3: Add the plist key**

In the `Info.plist` heredoc, add these two lines directly after the `CFBundleExecutable` string line:

```
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
```

- [ ] **Step 4: Assert the key reads back**

After the existing `LSUIElement` check and its `echo`, add:

```bash
# -lint accepts any well-formed plist, so read the icon key back explicitly.
icon_file="$(plutil -extract CFBundleIconFile raw -o - "${CONTENTS}/Info.plist")"
[ "${icon_file}" = "AppIcon" ] || die "CFBundleIconFile is '${icon_file}', expected AppIcon"
echo "    CFBundleIconFile=AppIcon"
```

- [ ] **Step 5: Build and verify**

```bash
scripts/build-app.sh
ls -la build/CoffeeBar.app/Contents/Resources/AppIcon.icns
plutil -extract CFBundleIconFile raw -o - build/CoffeeBar.app/Contents/Info.plist
sips -g pixelWidth -g pixelHeight build/CoffeeBar.app/Contents/Resources/AppIcon.icns
```
Expected: the file exists and is non-empty, the key prints `AppIcon`, and `sips` reports a real size.

- [ ] **Step 6: Confirm the tracked tree is clean**

Run: `git status --short assets/`
Expected: **empty**. A non-empty result means the rename escaped the temporary copy — fix it before committing.

- [ ] **Step 7: See it in Finder**

```bash
open -R build/CoffeeBar.app
```
Confirm by eye that the bundle shows the cup icon rather than the generic one. It is still green at this point; Task 4 recolours it.

- [ ] **Step 8: Commit**

```bash
git add scripts/build-app.sh
git commit -s -S -m "feat(build): put an app icon in the bundle

The bundle has never carried one: no .icns was ever committed and the
generated Info.plist set no icon key, so Finder drew the generic bundle
icon and the whole appicon/ tree reached no user.

iconutil rather than actool: actool is the shared xcrun shim and needs a
full Xcode, which a Homebrew tarball build may not have. iconutil is a
real binary and runs without one.

The iconset is copied to a temp dir before the @2x rename, so a build
never dirties the tracked tree."
```

---

### Task 4: Re-cut the 34 rasters that have a source

Track A of design spec §9.1. Recolour five SVGs, then re-rasterise.

**Files:**
- Modify: `assets/art/appicon/layers/default-3-liquid.svg`, `assets/art/appicon/layers/dark-3-liquid.svg`, `assets/art/appicon/AppIcon.icon/Assets/liquid.svg`, `assets/art/appicon/svg/AppIcon-default.svg`, `assets/art/appicon/svg/AppIcon-dark.svg`
- Create: `assets/art/recut.sh`, `assets/art/census.py`
- Regenerate: 24 files under `assets/art/appicon/`, 8 under `assets/art/web/`, 2 under `assets/art/github/`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `assets/art/census.py`, reused by Task 5.

- [ ] **Step 1: Install the rasteriser**

```bash
brew install librsvg
rsvg-convert --version
```
Expected: a version prints. If the install fails, stop and report — headless Chrome is the documented fallback and needs its own brief.

- [ ] **Step 2: Record the before-state**

```bash
python3 - <<'PY'
from PIL import Image
import glob, hashlib
for p in sorted(glob.glob('assets/art/**/*.png', recursive=True)):
    im = Image.open(p).convert('RGBA')
    print(f"{p}\t{im.size[0]}x{im.size[1]}\t{im.mode}\t{hashlib.sha256(im.tobytes()).hexdigest()[:12]}")
PY
```
Save the output to `"${TMPDIR:-/tmp}/art-before-app-ui-alignment.txt"`. Task 4 Step 8 compares against it.

- [ ] **Step 3: Write the census script**

Create `assets/art/census.py`:

```python
#!/usr/bin/env python3
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""Assert that no raster under assets/art still carries the retired accent.

A failed image conversion leaves the OLD file in place and exits 0, so a
green pipeline is not evidence. This opens every file and looks.

It also asserts the NUMBER of files inspected. A guard reads what a file
says and cannot see a file it never opened, so a silently skipped path
would otherwise pass.
"""
import colorsys
import glob
import sys
from PIL import Image

RETIRED = (0x76, 0xB9, 0x00)
EXPECTED_TOTAL = 62  # every PNG under assets/art, measured 2026-08-05


def green_band(rgb):
    """True for any hue a #76B900 pixel could have blended into."""
    r, g, b = (c / 255 for c in rgb[:3])
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    return 70 / 360 <= h <= 100 / 360 and s > 0.25 and v > 0.20


def main():
    paths = sorted(glob.glob("assets/art/**/*.png", recursive=True))
    failures = []
    for path in paths:
        image = Image.open(path).convert("RGBA")
        colours = image.getcolors(1_000_000) or []
        exact = sum(n for n, c in colours if c[:3] == RETIRED)
        banded = sum(n for n, c in colours if c[3] > 0 and green_band(c))
        if exact or banded:
            failures.append(f"{path}: {exact} exact #76B900, {banded} in the green band")

    if len(paths) != EXPECTED_TOTAL:
        failures.append(
            f"inspected {len(paths)} PNGs, expected {EXPECTED_TOTAL}. "
            "A file was added, removed, or silently skipped."
        )

    for line in failures:
        print(f"FAIL {line}", file=sys.stderr)
    print(f"checked {len(paths)} rasters, {len(failures)} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the census to verify it FAILS now**

Run: `python3 assets/art/census.py; echo "rc=$?"`
Expected: `rc=1`, and exactly **40** `FAIL` lines naming files. If it reports 0 failures the script is broken — the tree is known to carry 40 green rasters.

- [ ] **Step 5: Recolour the five SVGs**

```bash
cd assets/art/appicon
sed -i '' 's/#76B900/#A2571E/g' layers/default-3-liquid.svg AppIcon.icon/Assets/liquid.svg svg/AppIcon-default.svg
sed -i '' 's/#76B900/#B8682A/g' layers/dark-3-liquid.svg svg/AppIcon-dark.svg
cd -
grep -rl "76B900" assets/art/ || echo "no SVG carries it now"
```

Expected: only `assets/art/README.md` still matches. `mono` layers carry no accent and are untouched.

- [ ] **Step 6: Prove the substitution landed**

A scripted replacement can change nothing and still exit 0.

```bash
diff assets/art/appicon/svg/AppIcon-default.svg site/appicon-light.svg && echo "MATCHES the site twin"
diff assets/art/appicon/svg/AppIcon-dark.svg site/appicon-dark.svg && echo "MATCHES the site twin"
```
Expected: both report no difference. These files were byte-identical apart from the liquid fill, so an exact match proves the edit.

- [ ] **Step 7: Write and run the re-cut script**

Create `assets/art/recut.sh`:

```bash
#!/bin/bash
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
#
# Re-rasterises every raster that has a vector source. Six files have none —
# github/readme-header, github/social-preview and the four wordmarks — and are
# handled separately.
#
# Several outputs are byte-identical to each other in the shipped package, so
# this renders each unique image once and copies. `command cp` bypasses an
# interactive `cp -i` alias, which would decline and still exit 0.

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

A=assets/art
LIGHT=$A/appicon/svg/AppIcon-default.svg
DARK=$A/appicon/svg/AppIcon-dark.svg
WEB=site/appicon-web.svg

render() {  # render <svg> <size> <out>
    rsvg-convert -w "$2" -h "$2" "$1" -o "$3"
    [ -s "$3" ] || { echo "error: $3 is empty" >&2; exit 1; }
}

for s in 16 32 64 128 256 512 1024; do
    render "$LIGHT" "$s" "$A/appicon/png/default/AppIcon-$s.png"
    render "$DARK"  "$s" "$A/appicon/png/dark/AppIcon-$s.png"
done

# The iconset duplicates the light renders under Apple's naming.
IS=$A/appicon/AppIcon.iconset
command cp -f "$A/appicon/png/default/AppIcon-16.png"   "$IS/icon_16x16.png"
command cp -f "$A/appicon/png/default/AppIcon-32.png"   "$IS/icon_16x16-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-32.png"   "$IS/icon_32x32.png"
command cp -f "$A/appicon/png/default/AppIcon-64.png"   "$IS/icon_32x32-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-128.png"  "$IS/icon_128x128.png"
command cp -f "$A/appicon/png/default/AppIcon-256.png"  "$IS/icon_128x128-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-256.png"  "$IS/icon_256x256.png"
command cp -f "$A/appicon/png/default/AppIcon-512.png"  "$IS/icon_256x256-2x.png"
command cp -f "$A/appicon/png/default/AppIcon-512.png"  "$IS/icon_512x512.png"
command cp -f "$A/appicon/png/default/AppIcon-1024.png" "$IS/icon_512x512-2x.png"

# web/ sits on the web tile #F2F0EB, which is why it has its own source.
for s in 16 32 48; do render "$WEB" "$s" "$A/web/favicon-$s.png"; done
render "$WEB" 180 "$A/web/apple-touch-icon-180.png"
render "$WEB" 192 "$A/web/icon-192.png"
render "$WEB" 512 "$A/web/icon-512.png"

# The dark web icon and both GitHub avatars are the DARK appicon render.
command cp -f "$A/appicon/png/dark/AppIcon-512.png"  "$A/web/icon-512-dark.png"
command cp -f "$A/appicon/png/dark/AppIcon-512.png"  "$A/github/repo-avatar-512.png"
command cp -f "$A/appicon/png/dark/AppIcon-1024.png" "$A/github/repo-avatar-1024.png"

# Maskable insets the art by 0.72 about the canvas centre for the platform
# safe zone (assets/art/README.md).
python3 - "$A/web/icon-512.png" "$A/web/icon-512-maskable.png" <<'PY'
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
image = Image.open(src).convert("RGBA")
size = image.size[0]
inner = round(size * 0.72)
canvas = Image.new("RGBA", (size, size), image.getpixel((0, 0)))
canvas.paste(image.resize((inner, inner), Image.LANCZOS), ((size - inner) // 2,) * 2)
canvas.save(dst)
PY

echo "re-cut complete"
```

```bash
chmod +x assets/art/recut.sh
assets/art/recut.sh
```

**Expect one deliberate change beyond the accent.** The shipped `web/` rasters
carry ink `#101013`, while `site/appicon-web.svg` specifies `#121214`. Rendering
from that source therefore shifts the ink by 2/255 per channel. That is
invisible in practice and makes `web/` consistent with the vector source for the
first time, but it is a real change — record it in the report rather than let a
reviewer discover it. Confirm the shift is only that:

```bash
python3 - <<'PY'
from PIL import Image
im = Image.open('assets/art/web/icon-512.png').convert('RGBA')
top = sorted(im.getcolors(1_000_000), reverse=True)[:3]
for count, colour in top:
    print(f"#{colour[0]:02X}{colour[1]:02X}{colour[2]:02X}  {count}")
PY
```
Expected: the tile `#F2F0EB`, ink `#121214`, and the accent `#A2571E`. No green.

- [ ] **Step 8: Verify sizes and modes did not drift**

```bash
python3 - "${TMPDIR:-/tmp}/art-before-app-ui-alignment.txt" <<'PY'
import sys
from PIL import Image
import glob
before = {}
for line in open(sys.argv[1]):
    path, dims, mode, _ = line.rstrip('\n').split('\t')
    before[path] = (dims, mode)
bad = 0
for p in sorted(glob.glob('assets/art/**/*.png', recursive=True)):
    im = Image.open(p).convert('RGBA')
    now = (f"{im.size[0]}x{im.size[1]}", im.mode)
    if p in before and before[p] != now:
        print(f"DRIFT {p}: was {before[p]}, now {now}"); bad += 1
print("size/mode drift:", bad)
PY
```
Expected: `size/mode drift: 0`.

- [ ] **Step 9: Rebuild the icns and confirm the icon changed**

```bash
scripts/build-app.sh
open -R build/CoffeeBar.app
```
Confirm by eye that the Finder icon is now roast, not green.

- [ ] **Step 10: Run the census**

Run: `python3 assets/art/census.py; echo "rc=$?"`
Expected: `rc=0`, `checked 62 rasters, 0 failures` — **unless** Task 5 is still outstanding, in which case exactly the 6 sourceless files fail. Record which.

- [ ] **Step 11: Commit**

```bash
git add assets/art/ 
git commit -s -S -m "feat(art): re-cut every raster that has a vector source

The liquid layers were a single rect, so the recolour is one substitution
per file. site/appicon-{light,dark}.svg already carried the recoloured
geometry and differed from the appicon sources by exactly that token, so
the edit is verified by diffing against them.

recut.sh renders each unique image once and copies the duplicates: the
iconset, the dark web icon and both GitHub avatars are byte-identical to
appicon renders in the shipped package.

census.py opens every raster rather than trusting an exit code, and
asserts the file COUNT so a silently skipped path fails."
```

---

### Task 5: Re-cut the 6 rasters with no source

Track B of design spec §9.2. These carry typography or composite layout, so a hue remap can degrade them. **If a visual check fails, stop and report — they do not ship degraded.**

**Files:**
- Modify: `assets/art/github/readme-header-1600x400.png`, `assets/art/github/social-preview-1280x640.png`, `assets/art/wordmark/coffee-bar-wordmark-light.png`, `assets/art/wordmark/coffee-bar-wordmark-light-2x.png`, `assets/art/wordmark/coffee-bar-wordmark-dark.png`, `assets/art/wordmark/coffee-bar-wordmark-dark-2x.png`
- Create: `assets/art/remap.py`

**Interfaces:**
- Consumes: `assets/art/census.py` from Task 4.
- Produces: nothing later tasks read.

- [ ] **Step 1: Write the remap**

Create `assets/art/remap.py`:

```python
#!/usr/bin/env python3
# Copyright 2026 Carlos Eduardo Arango Gutierrez
# SPDX-License-Identifier: Apache-2.0
"""Recolour the rasters that have no vector source.

Four wordmarks and two composite GitHub images were delivered as an external
export with no vector behind them, so they cannot be re-cut. This rotates the
retired accent's HUE and keeps each pixel's saturation, value and alpha, which
is what stops anti-aliased edges fringing: a partly-green edge pixel stays
partly-roast at the same lightness.
"""
import colorsys
import sys
from PIL import Image

RETIRED = "#76B900"
TARGETS = {"light": "#A2571E", "dark": "#B8682A"}


def hsv_of(hex_colour):
    h = hex_colour.lstrip("#")
    rgb = tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return colorsys.rgb_to_hsv(*rgb)


def remap(path, target_hex):
    src_h, src_s, src_v = hsv_of(RETIRED)
    target_h, target_s, target_v = hsv_of(target_hex)
    # RATIOS, derived, not constants picked by eye. A pixel that is exactly the
    # retired accent lands exactly on the target, and a half-blended edge pixel
    # keeps its blend. Verified: #76B900 maps to #A2571E and to #B8682A exactly.
    s_ratio = target_s / src_s
    v_ratio = target_v / src_v
    image = Image.open(path).convert("RGBA")
    pixels = image.load()
    width, height = image.size
    touched = 0
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if not (70 / 360 <= h <= 100 / 360 and s > 0.25 and v > 0.20):
                continue
            # Scale s and v by the derived ratios so the edge ramp survives.
            nr, ng, nb = colorsys.hsv_to_rgb(target_h,
                                             min(1.0, s * s_ratio),
                                             min(1.0, v * v_ratio))
            pixels[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
            touched += 1
    if touched == 0:
        raise SystemExit(f"error: {path} had no pixel in the green band")
    image.save(path)
    print(f"{path}: {touched} pixels remapped -> {target_hex}")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        remap(arg, TARGETS["dark"] if "dark" in arg else TARGETS["light"])
```

- [ ] **Step 2: Copy the originals so the change is reviewable**

```bash
mkdir -p "${TMPDIR:-/tmp}/art-b-before-app-ui-alignment"
command cp -f assets/art/github/readme-header-1600x400.png assets/art/github/social-preview-1280x640.png assets/art/wordmark/coffee-bar-wordmark-light.png assets/art/wordmark/coffee-bar-wordmark-light-2x.png assets/art/wordmark/coffee-bar-wordmark-dark.png assets/art/wordmark/coffee-bar-wordmark-dark-2x.png "${TMPDIR:-/tmp}/art-b-before-app-ui-alignment"/
ls "${TMPDIR:-/tmp}/art-b-before-app-ui-alignment"/ | wc -l
```
Expected: `6`.

- [ ] **Step 3: Run the remap**

```bash
python3 assets/art/remap.py \
    assets/art/github/readme-header-1600x400.png \
    assets/art/github/social-preview-1280x640.png \
    assets/art/wordmark/coffee-bar-wordmark-light.png \
    assets/art/wordmark/coffee-bar-wordmark-light-2x.png \
    assets/art/wordmark/coffee-bar-wordmark-dark.png \
    assets/art/wordmark/coffee-bar-wordmark-dark-2x.png
```
Expected: six lines, each with a non-zero pixel count.

- [ ] **Step 4: Verify sizes and modes held**

```bash
python3 - "${TMPDIR:-/tmp}/art-b-before-app-ui-alignment" <<'PY'
import sys
from PIL import Image
import glob, os
bad = 0
for after in sorted(glob.glob(os.path.join(sys.argv[1], '*.png'))):
    name = os.path.basename(after)
    live = ('assets/art/github/' if name.startswith(('readme', 'social')) else 'assets/art/wordmark/') + name
    a, b = Image.open(after).convert('RGBA'), Image.open(live).convert('RGBA')
    if a.size != b.size or a.mode != b.mode:
        print(f"DRIFT {live}"); bad += 1
print("drift:", bad)
PY
```
Expected: `drift: 0`.

- [ ] **Step 5: Look at all six**

```bash
open "${TMPDIR:-/tmp}/art-b-before-app-ui-alignment"/ assets/art/wordmark/ assets/art/github/
```

Compare each pair side by side. Reject and report if you see any of:
- a green or olive fringe on a letter edge;
- a halo where the accent meets the background;
- a shift in any colour that was never green.

**If any file fails, revert all six** (`git checkout -- assets/art/github assets/art/wordmark`), keep `remap.py` uncommitted, and report BLOCKED. The design spec says these do not ship degraded.

- [ ] **Step 6: Run the census**

Run: `python3 assets/art/census.py; echo "rc=$?"`
Expected: `rc=0`, `checked 62 rasters, 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add assets/art/remap.py assets/art/github assets/art/wordmark
git commit -s -S -m "feat(art): recolour the six rasters that have no vector source

Four wordmarks and two composite GitHub images arrived as an external
export with nothing vector behind them, so they cannot be re-cut.

The remap rotates hue and keeps each pixel's saturation, value and alpha,
so an anti-aliased edge stays an edge instead of fringing. It refuses to
write a file where it matched no pixel, because a silent no-op is how a
substitution appears to succeed while changing nothing."
```

---

### Task 6: Bring the brand doc back in step

Design spec §10. Four defects, all verified.

**Files:**
- Modify: `assets/art/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Confirm the doc is now the only thing carrying the old accent**

```bash
grep -rl "76B900" assets/art/
```

Expected: **five** files.

`assets/art/README.md` is the only one that carries the retired accent as
brand prose, and it is the one you rewrite. The other four name the hex because
they are the tools that DETECT it, and they must keep it:

| File | Why it names `#76B900` |
|---|---|
| `census.py` | `RETIRED` — the value it searches every raster for |
| `census_test.py` | fixtures that must flip the detector |
| `remap.py` | `RETIRED` — the source hue it maps away from |
| `remap_test.py` | fixtures proving the round-trip |

Removing the hex from any of those four would disarm the guard that keeps the
accent from coming back. Change none of them.

- [ ] **Step 2: Replace the unfinished-recolour note**

Delete the block quote at lines 40–45 that begins `> **The recolour is not finished.**` and ends `> lands, the installed app icon stays green while the site is roast.`

Replace it with:

```markdown
> **The recolour landed on 2026-08-05.** Every raster under `assets/art/**`
> now carries `state`. `appicon/**`, `web/**` and both GitHub avatars are
> re-cut from vector sources by `recut.sh`. The four `wordmark/**` files and
> the two composite `github/**` images have no vector source and were
> recoloured by `remap.py`; authoring real sources for them is open work.
> `census.py` opens every raster and fails if the retired accent returns.
```

This fixes three defects at once. The old note omitted `wordmark/`, which carried four green rasters. It claimed "the installed app icon stays green", when no installed icon existed at all. It called the re-cut "a tracked follow-up", and no such issue exists.

- [ ] **Step 3: Record where the retired accent is named**

The sentence at line 36 that begins `The accent moved off `#76B900`` is history and stays. It is now the only mention.

- [ ] **Step 4: Document the app's use of the roles**

After the `Never mix` paragraph (lines 18–20), add:

```markdown
In the **app**, `state` colours the status indicator and the selected segment
of each picker — both are held segments. Warnings use SwiftUI's semantic
`.orange`, which is a system colour rather than the `action` role, so it keeps
adapting to Increase Contrast. `action` itself appears on the web only.
```

- [ ] **Step 5: Verify the doc claims match the tree**

```bash
python3 assets/art/census.py; echo "census rc=$?"
ls assets/art/recut.sh assets/art/remap.py assets/art/census.py
grep -c "76B900" assets/art/README.md
```
Expected: census `rc=0`; all three scripts exist; exactly `1` mention of the retired accent.

- [ ] **Step 6: Run every gate**

```bash
swift test
node --test site/assets/bench.test.js
```
Expected: both pass. Paste the real output into the report.

- [ ] **Step 7: Commit**

```bash
git add assets/art/README.md
git commit -s -S -m "docs(art): record the finished recolour in the brand doc

The unfinished-recolour note carried three errors. It listed appicon, web
and github but omitted wordmark, which held four green rasters — a page
states what it covers and cannot state what it forgot. It said the
installed app icon stays green, when the bundle shipped no icon at all.
It called the re-cut a tracked follow-up, and no such issue exists.

Also states how the app uses the roles, so the next reader does not have
to infer it from PanelView."
```

---

## Verification before calling this done

Run all of it, in the worktree, and paste real output:

```bash
swift test
node --test site/assets/bench.test.js
python3 assets/art/census.py
scripts/build-app.sh
plutil -extract CFBundleIconFile raw -o - build/CoffeeBar.app/Contents/Info.plist
git status --short
```

Then launch the app and screenshot the open panel. `swift test` cannot see rendered AppKit text, so a green suite is not evidence the panel looks right. Confirm the screenshot is larger than 10 kB before reading it.

## Known follow-ups, not in this plan

- `github/readme-header`, `github/social-preview` and `wordmark/**` still have no vector source. Authoring them makes the package rebuildable.
- An `AccentColor` asset becomes cheap once M4 requires full Xcode on the release machine. Design spec D2 is revisitable then.
- `assets/art/README.md` line 49 says to run `make-icns.sh` after unzipping. `scripts/build-app.sh` now builds the icns itself, so that instruction is only for a fresh art delivery.
