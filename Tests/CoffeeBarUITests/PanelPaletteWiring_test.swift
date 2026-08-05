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
