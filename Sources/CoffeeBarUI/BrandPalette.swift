// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

// `import Foundation` is explicit for `pow`. Do not rely on SwiftUI
// re-exporting it — the rest of this module states its imports the same way.
import Foundation
import SwiftUI

/// What a colour MEANS here, never which colour it is.
///
/// The brand doc (assets/art/README.md lines 18-20) restricts `action` — Apple
/// systemOrange — to the web, and forbids mixing it with `state`. This type
/// carries no `action` case, so no caller can name that role directly.
///
/// That is a narrowing, NOT a proof. `.warning` resolves to SwiftUI `.orange`,
/// which IS systemOrange, so the app does put the `action` pigment on screen.
/// The exception is deliberate: `warning` means attention, and the system
/// semantic colour is the one macOS users already read that way. Omitting the
/// case removes the ROLE from the vocabulary, not the pigment from the screen.
///
/// `.warning` HAS NO PRODUCTION CALLER. This comment says so outright, because
/// the case reads as though the app routed warnings through it, and it does
/// not. The case earns its place by keeping the role vocabulary complete and
/// testable: `rgb` answers `nil` for it, and `CaseIterable` then carries it
/// through the contrast walk described below.
///
/// AND THE APP NO LONGER RENDERS THAT PIGMENT ANYWHERE. It used to: `PanelView`
/// wrote the semantic orange as a literal on its four advisory lines — the ones
/// driven by `suppressionAdvisory`, `hookAdvisory`, `ingestAdvisory` and
/// `staleHelperAdvisory` — without ever naming this role. Issue #30 measured
/// what that cost: as caption TEXT on a light backdrop the pigment reaches
/// 1.75:1 to 2.31:1 against a 4.5:1 floor. Those lines now render through
/// `advisoryRow`, which carries an `exclamationmark.triangle` and a `.primary`
/// sentence, so the meaning is in the SHAPE and the panel is back inside the
/// rule assets/art/README.md line 22 states: neither accent carries body text.
///
/// So `brand(.warning)` is not the route back. It resolves to the same
/// systemOrange the advisories just gave up, and
/// `advisoriesCarryShapeRatherThanColour` in `PanelPaletteWiring_test.swift`
/// refuses it by reading the ARGUMENT of every paint modifier on an advisory
/// and allowing only the two neutral semantics — which is why that guard is a
/// shape check and not the count of `.orange` literals it replaced. A count
/// could only have moved from four to zero, and zero is also what a panel with
/// no advisories at all scores.
///
/// `CaseIterable` is load-bearing. `fixedRolesClearNonTextContrast` walks
/// `allCases` and skips a role only because `rgb` answered `nil`. A role added
/// here with a fixed value therefore cannot escape the 3:1 floor by being
/// missing from a hand-written list in a test.
public enum ColorRole: Sendable, Equatable, CaseIterable {
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

        /// Parses `#RRGGBB`, answering `nil` for anything else.
        ///
        /// Split out of `init(hex:)` so a test can observe a refusal WITHOUT a
        /// subprocess. The exit-test form needs swift-testing from Swift 6.2,
        /// and CI runs 6.1.2 — a guard that compiles only on the developer's
        /// machine gates nothing.
        ///
        /// `UInt64(_:radix:)` rather than `Scanner.scanHexInt64`. The scanner
        /// answers `true` after a PARTIAL scan, so it accepted "ABCXYZ" as
        /// 0xABC and "12 345" as 0x12 — a wrong colour would have shipped
        /// looking deliberate. `UInt64(_:radix:)` answers `nil` unless the
        /// WHOLE string parses, but it ALSO accepts a leading sign, so
        /// "+ABCDE" would parse as 0xABCDE. `allSatisfy(\.isHexDigit)` is what
        /// refuses that.
        static func parse(hex: String) -> RGB? {
            let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard s.count == 6, s.allSatisfy(\.isHexDigit),
                  let value = UInt64(s, radix: 16) else { return nil }
            return RGB(r: Double((value & 0xFF0000) >> 16) / 255,
                       g: Double((value & 0x00FF00) >> 8) / 255,
                       b: Double(value & 0x0000FF) / 255)
        }

        /// Accepts `#RRGGBB`. Traps on anything else: every call site in this
        /// module passes a literal from the brand doc, so a malformed string is
        /// a programming error, not a runtime condition to recover from.
        ///
        /// The parse itself lives in `parse(hex:)` so it stays observable
        /// without killing a process; this initialiser only turns a refusal
        /// into the trap those literal call sites want.
        public init(hex: String) {
            guard let parsed = RGB.parse(hex: hex) else {
                preconditionFailure("BrandPalette.RGB(hex:) needs #RRGGBB, got \(hex)")
            }
            self = parsed
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

    /// `nil` for `.warning`, which resolves to SwiftUI's semantic `.orange`.
    /// The system colour tracks the appearance and the Increase Contrast
    /// setting on its own, and a hex pinned here would freeze it.
    ///
    /// It does NOT clear text contrast in the light appearance, and that is
    /// permanent rather than pending. Measured as TEXT, systemOrange reaches
    /// 1.75:1 to 2.31:1 on plausible light backdrops, where 4.5:1 is required;
    /// on dark backdrops it reaches 7.02:1 to 8.11:1. No darker orange rescues
    /// it: anything clearing 4.5:1 on a light backdrop has reached about
    /// `#8C5200`, which is no longer distinguishable from the roast `state`
    /// colour, so that fix would delete the distinction it exists to draw.
    ///
    /// Issue #30 was therefore answered by spending SHAPE instead. The panel's
    /// advisories dropped the pigment for a symbol and a `.primary` sentence;
    /// see `advisoryRow` in `PanelView.swift`. This value is unchanged because
    /// nothing here was wrong — the role was never the carrier.
    ///
    /// So: `.warning` marks an icon or a rule, never body text in the light
    /// appearance, and nothing in the app asks for it today.
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
