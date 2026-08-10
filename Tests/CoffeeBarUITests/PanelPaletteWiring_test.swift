// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// Reads `PanelView.swift` as CODE. `#filePath` anchors the lookup to THIS
/// source file, never to an installed or deployed copy, so the guard cannot
/// green-light a different tree than the one under test.
///
/// COMMENT-STRIPPED, and that is a repair, not a flourish. Read raw, every
/// guard in this file counted PROSE as CODE, and the count guard below was
/// measured to fail in BOTH directions at once — the only guard in this
/// package to manage both:
///
///   INVERTED — a two-line comment naming `.pickerStyle(.segmented)` took the
///   count to 2 and turned the guard RED on an otherwise correct tree.
///   BLIND — commenting out the ENTIRE Serving picker left it GREEN, because
///   the commented-out `.pickerStyle(.segmented)` still counted.
///
/// The second is the one that mattered: the guard reported a control present
/// after it had been removed from the render, which is the exact failure it
/// exists to catch.
///
/// Urgent rather than tidy, because the practice that trips it is now
/// established in the file it reads. `PanelView.swift` explains the three
/// controls that moved to Preferences in prose, deliberately — that paragraph
/// is itself a fixture for `eachMovedControlLivesInExactlyOneSurface` — and
/// Task 6 extends the practice. The next person to write a helpful comment
/// about the segmented picker would have reddened this suite on a correct
/// tree, and the obvious way to green it is to bump the literal to 2, which
/// silently widens the guard forever.
///
/// `swiftCodeWithoutComments` is the lexer `AppLayerBoundary_test.swift`
/// declares and `swiftCodeWithoutCommentsKeepsCodeAndDropsComments` pins.
/// Reused rather than re-implemented, for the reason its own doc gives: one
/// tested stripper in this target, not two.
///
/// ALL THREE guards in this file read through here, so all three are fixed at
/// once: the tint count, the orange count — same shape, same inflation — and
/// `indicatorComesFromTheModel`, which is the blind direction, where a comment
/// naming `ServingModel.indicator(` would satisfy it while the call was gone.
/// The hex-literal check stops matching hex inside prose as a bonus.
private func panelSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    return swiftCodeWithoutComments(try String(
        contentsOf: root.appendingPathComponent("Sources/CoffeeBarUI/PanelView.swift"),
        encoding: .utf8))
}

@Test("the tint is applied per-picker, so state never paints a non-segment control")
func tintIsConfinedToTheHeldSegments() throws {
    let source = try panelSource()

    let tints = source.components(separatedBy: ".tint(brand(.state))").count - 1
    let pickers = source.components(separatedBy: ".pickerStyle(.segmented)").count - 1

    // The DECLARATIONS, counted separately from the style modifier, and this
    // pair closes a hole that comment-stripping alone does not.
    //
    // `pickers` counts `.pickerStyle(.segmented)`, which is a MODIFIER and not
    // a control. Comment out a `Picker`'s body and leave its modifiers behind
    // and they simply chain onto whatever view precedes them — `Text` accepts
    // `.pickerStyle` and `.labelsHidden()` happily, and it all compiles. Every
    // other assertion here then holds over a panel with no Serving control at
    // all: measured GREEN, and still GREEN after the stripping fix, which is
    // why this is here and not left to the reader.
    let declared = source.components(separatedBy: "Picker(").count - 1

    // A COUNT, not a presence check. One `.tint` on the enclosing VStack would
    // satisfy a `contains` assertion while painting the Quit button and every
    // focus ring roast — the exact regression this replaces.
    //
    // ONE, down from three, and the number is not incidental. The Display and
    // Battery floor pickers moved into the Preferences window, which draws no
    // brand tint at all: `brand(_:)` is `PanelView`'s own, and the window is a
    // system-styled form. Only the Serving picker still colours held segments,
    // which is what assets/art/README.md lines 18-20 assign `state` to.
    //
    // The count still discriminates at 1 — deleting the tint gives 0 — and the
    // adjacency check below is what carries the placement half, exactly as it
    // did at 3.
    //
    // It counts CODE, never prose. `panelSource()` strips comments and its doc
    // records the two measured failures that argument replaces; this note is
    // here because the rationale above argues only the NUMBER's soundness, and
    // a number is sound over the wrong text.
    #expect(pickers == 1, "expected 1 segmented picker, found \(pickers)")
    #expect(tints == pickers,
            "expected one .tint per segmented picker: \(pickers) pickers, \(tints) tints")

    // Every segmented style must belong to a Picker that is actually declared.
    // Named bug this catches: the control removed while its modifiers stay,
    // which every other assertion here reads as a healthy panel.
    #expect(declared == pickers, """
        \(pickers) .pickerStyle(.segmented) modifiers but \(declared) Picker( \
        declarations. A segmented style with no picker under it is a modifier \
        chained onto whatever view precedes it — the control is gone and the \
        counts still balance.
        """)

    // The count ALONE is still theater, and this was measured, not reasoned:
    // moving one picker's `.tint` up to the enclosing VStack leaves the
    // file-wide total at 3, so the two assertions above stayed green on the
    // exact regression they name. Placement needs its own two checks.

    // 1. ADJACENCY. The first modifier after each `.labelsHidden()`, comments
    //    skipped, must be the tint. That is what "on the picker" means.
    //
    //    The `hasPrefix("//")` filter is now belt-and-braces: `panelSource()`
    //    strips comments before this sees them. Kept rather than removed, so
    //    the check does not silently depend on the reader for correctness —
    //    it was skipping comments before the reader did, and it still would.
    let attached = source
        .components(separatedBy: ".labelsHidden()\n")
        .dropFirst()
        .filter { tail in
            tail.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("//") } == ".tint(brand(.state))"
        }
        .count
    #expect(attached == pickers,
            "expected a .tint directly on each picker: \(pickers) pickers, \(attached) attached")

    // 2. THE CONTAINER STAYS CLEAN. `.tint` is an Environment value, so one on
    //    the VStack descends to the Quit button and every focus ring. Anything
    //    after the container's own `.padding(14)` is a modifier ON the
    //    container, not on a control inside it.
    let containerModifiers = source.components(separatedBy: "\n        .padding(14)").last ?? ""
    #expect(!containerModifiers.contains(".tint("),
            "the enclosing VStack must carry no .tint: it descends to every control below it")

    // The bug this catches: someone hardcodes a hex in the view, where no test
    // can read it. That is the exact failure BrandPalette exists to prevent.
    let hexLiteral = try Regex("#[0-9A-Fa-f]{6}")
    #expect(source.firstMatch(of: hexLiteral) == nil,
            "PanelView must contain no #RRGGBB literal; values live in BrandPalette")
}

@Test("the indicator comes from the model, not from a symbol name typed here")
func indicatorComesFromTheModel() throws {
    let source = try panelSource()
    #expect(source.contains("ServingModel.indicator("),
            "the indicator must come from ServingModel.indicator(isServing:)")
}

@Test("orange is spent on exactly the four advisory lines")
func orangeIsSpentOnlyOnTheAdvisories() throws {
    let source = try panelSource()
    let occurrences = source.components(separatedBy: ".foregroundStyle(.orange)").count - 1

    // A COUNT, not a presence check. A guard reads what a file says and cannot
    // see what it omits, so presence alone would stay green if a fifth orange
    // element appeared or an advisory silently lost its colour. This panel has
    // already shipped one undocumented control; the count is what catches the
    // next one.
    //
    // It caught issue #81's line, which is why this says four. The
    // stale-helper advisory arrived, this guard went red at 4 against a
    // deliberate change, and the count moved in the same commit — which is the
    // note below working rather than a guard being edited to fit.
    //
    // COUPLED TO `ColorRole.warning`, and this note is one half of a pair.
    // The four advisories render `.orange` as a LITERAL, never through
    // `brand(.warning)`, so `.warning` has no production caller and this count
    // is what pins the literal down. Routing the advisories through the role —
    // which is what fixing issue #30 will want — takes this count to 0 and
    // turns this test red. That is the guard working, not a regression: move
    // the count in the same change. `BrandPalette.swift` carries the other
    // half of this note, on the `ColorRole` declaration.
    #expect(occurrences == 4,
            "expected 4 orange advisory lines, found \(occurrences)")
}
