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
