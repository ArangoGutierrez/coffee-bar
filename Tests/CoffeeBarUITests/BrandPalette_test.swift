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

/// The two appearances, each with the backdrop that is hardest for it.
private let appearances: [(scheme: ColorScheme, backdrop: String)] = [
    (.light, worstLightBackdrop),
    (.dark, worstDarkBackdrop),
]

/// How many `(role, scheme)` pairs a correct scan reaches at one contrast
/// setting.
///
/// A literal floor, derived from the brand doc rather than from the code:
/// `assets/art/README.md` lines 14-16 give `state` and `rest` a fixed value in
/// both appearances, so 2 roles x 2 appearances. It is a FLOOR, not an
/// equality, so a role added later raises the coverage instead of failing.
/// Without it a `guard let ... else { continue }` loop would pass by checking
/// nothing at all, the moment `rgb` started answering `nil` everywhere.
private let fixedValuePairs = 4

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

@Test("every role that has a fixed value clears 3:1 on the worst plausible panel backdrop")
func fixedRolesClearNonTextContrast() {
    // Driven by `allCases`, never by a hand-written pair. A role is skipped
    // ONLY because `rgb` answered `nil` — that is, because it has no fixed
    // value to measure. The bug this shape catches: a role added to the enum
    // with a value nobody ever put on this list, which is exactly how the one
    // role that fails the floor becomes the one role never checked.
    var checked = 0
    for role in ColorRole.allCases {
        for (scheme, backdrop) in appearances {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                guard let rgb = BrandPalette.rgb(role, scheme: scheme, contrast: contrast) else {
                    continue
                }
                checked += 1
                let ratio = BrandPalette.contrastRatio(rgb, against: BrandPalette.RGB(hex: backdrop))
                #expect(ratio >= 3.0,
                        "\(role)/\(scheme)/\(contrast) on \(backdrop) was \(ratio), needs >= 3.0")
            }
        }
    }
    #expect(checked >= fixedValuePairs * 2,
            "scanned only \(checked) combinations; the loop measured almost nothing")
}

// The gain the increased-contrast blend must produce, as a multiple of the
// standard ratio. Measured at the shipped 0.30 blend: 1.61 to 1.73.
//
// Two bounds, because one is not enough. The floor refuses a token nudge — a
// blend of 0.02 gains only 1.03 and would satisfy a bare "raised > normal".
// The ceiling refuses a wash-out: a blend of 0.95 gains 3.80 and is no longer
// the brand colour at all. The band admits roughly 0.15 to 0.45.
private let minContrastGain = 1.25
private let maxContrastGain = 2.25

@Test("increased contrast raises the ratio by a real margin, without washing the colour out")
func increasedContrastRaisesTheRatioWithinABand() {
    var checked = 0
    for role in ColorRole.allCases {
        for (scheme, backdrop) in appearances {
            let back = BrandPalette.RGB(hex: backdrop)
            guard let normal = BrandPalette.rgb(role, scheme: scheme, contrast: .standard),
                  let raised = BrandPalette.rgb(role, scheme: scheme, contrast: .increased)
            else { continue }
            checked += 1
            let gain = BrandPalette.contrastRatio(raised, against: back)
                / BrandPalette.contrastRatio(normal, against: back)
            #expect(gain >= minContrastGain && gain <= maxContrastGain,
                    "\(role)/\(scheme) gain was \(gain), needs \(minContrastGain)...\(maxContrastGain)")
        }
    }
    #expect(checked >= fixedValuePairs,
            "scanned only \(checked) combinations; the loop measured almost nothing")
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

@Test("color hands a view the right components, in the right channels")
func colorCarriesTheRoleComponentsIntoSwiftUI() {
    // `color` is the ONLY member a view calls. Past this point M1 design §5.4
    // puts the decision beyond any check, so this is the last place a wrong
    // channel or a wrong appearance can still be read.
    #expect(BrandPalette.color(.state, scheme: .light, contrast: .standard)
            == Color(.sRGB, red: 162 / 255, green: 87 / 255, blue: 30 / 255, opacity: 1))
    #expect(BrandPalette.color(.state, scheme: .dark, contrast: .standard)
            == Color(.sRGB, red: 184 / 255, green: 104 / 255, blue: 42 / 255, opacity: 1))

    // The bug this catches: `red: rgb.b`. The components are all present and
    // the colour still looks deliberate, so nothing else would notice.
    #expect(BrandPalette.color(.state, scheme: .light, contrast: .standard)
            != Color(.sRGB, red: 30 / 255, green: 87 / 255, blue: 162 / 255, opacity: 1))
}

@Test("warning falls back to the system semantic orange, and only warning does")
func colorFallsBackToSystemOrangeForWarningOnly() {
    #expect(BrandPalette.color(.warning, scheme: .light, contrast: .standard) == Color.orange)
    #expect(BrandPalette.color(.warning, scheme: .dark, contrast: .increased) == Color.orange)

    // The bug this catches: the `guard let` inverted, or a role losing its
    // value, so a fixed role silently drops onto the fallback.
    for role in ColorRole.allCases
    where BrandPalette.rgb(role, scheme: .light, contrast: .standard) != nil {
        #expect(BrandPalette.color(role, scheme: .light, contrast: .standard) != Color.orange,
                "\(role) has a fixed value and must not resolve to the fallback")
    }
}

@Test("a hex string that is not six hex digits traps instead of parsing a prefix")
func malformedHexTraps() async {
    // `Scanner.scanHexInt64` answers `true` after a PARTIAL scan, so the
    // earlier implementation accepted "ABCXYZ" as 0xABC and "12 345" as 0x12 —
    // silently, while its own doc comment promised a trap. Every call site
    // passes a brand-doc literal, so a wrong value here would ship as a
    // plausible-looking colour that nobody measured.
    await #expect(processExitsWith: .failure) {
        _ = BrandPalette.RGB(hex: "ABCXYZ")
    }
    await #expect(processExitsWith: .failure) {
        _ = BrandPalette.RGB(hex: "12 345")
    }
    await #expect(processExitsWith: .failure) {
        _ = BrandPalette.RGB(hex: "0x1234")
    }
}
