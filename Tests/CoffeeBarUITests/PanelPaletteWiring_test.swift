// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarTestSupport

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
///
/// TAKES A FILE NAME, and that parameter is issue #30's remainder in one line.
/// This read was hard-wired to `PanelView.swift`, and the advisory guard below
/// was trusted for a rule that spans the whole UI module — so a FIFTH advisory,
/// the same sentence in the same pigment, sat in `PreferencesView.swift` and
/// survived the change whose entire purpose was removing it. The guard did not
/// miss it; the guard could not see the file it was in, and reported green.
private func uiSource(_ fileName: String) throws -> String {
    swiftCodeWithoutComments(try String(
        contentsOf: uiSourceDirectory().appendingPathComponent(fileName),
        encoding: .utf8))
}

/// `Sources/CoffeeBarUI`, anchored to THIS source file.
///
/// `#filePath` and never a working directory or a bundle path, for the reason
/// `uiSource` states: it pins the lookup to the tree under test, so the guard
/// cannot green-light an installed or deployed copy.
private func uiSourceDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources/CoffeeBarUI")
}

private func panelSource() throws -> String { try uiSource("PanelView.swift") }

/// The modifier chain that follows a view expression, as one string.
///
/// `tail` starts at the character AFTER the expression's closing `}`, so the
/// chain is the remainder of that line plus every following continuation line —
/// one whose first non-space character is `.`. The first line that is neither
/// blank nor a continuation ends it, and that boundary is the entire point: it
/// is what tells a `.pickerStyle(.segmented)` ON this view from the same
/// modifier on the next sibling down.
///
/// Blank lines are SKIPPED rather than treated as the end, and that is not a
/// convenience. `panelSource()` strips comments and keeps line structure, so a
/// comment inside a chain arrives here as a whitespace-only line — and Swift
/// itself continues an expression across a blank line anyway. `PanelView.swift`
/// explains its `.tint` in four comment lines MID-CHAIN, so ending on the first
/// blank would read the shipped panel as a chain of two modifiers.
private func modifierChain(after tail: Substring) -> String {
    var lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.isEmpty == false else { return "" }

    var chain = String(lines.removeFirst())
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        guard trimmed.hasPrefix(".") else { break }
        chain += "\n" + trimmed
    }
    return chain
}

/// How many `.pickerStyle(.segmented)` modifiers sit on a `Picker` that is
/// actually declared.
///
/// ADJACENCY, and it replaces a comparison of two FILE-WIDE TOTALS — the count
/// of `.pickerStyle(.segmented)` against the count of `Picker(` — that issue
/// #59 opened against. TWO CANCELLING EDITS passed that check: delete the
/// Serving control so its segmented style chains onto the `Group` above it, add
/// a second `Picker(` anywhere else in the file, and the totals balance at
/// 1 == 1 over a panel that renders no segmented control at all. Measured, not
/// reasoned, and pinned by `aSegmentedStyleNoPickerEnclosesIsNotAttached`.
///
/// The old message already CLAIMED adjacency — "a segmented style with no
/// picker under it" — while the check compared totals, so it asserted more than
/// it verified. That is the defect class this file exists to keep out of its own
/// guards; this is the claim made true rather than the message walked back.
///
/// `\bPicker\(` and not a substring match, so `DatePicker(` and `ColorPicker(`
/// cannot supply the declaration half. Both are real SwiftUI controls, both are
/// plausible here, and neither is a segmented picker.
///
/// The brace walk is `braceBlock(after:in:)` from `AppLayerBoundary_test.swift`,
/// the reader the version guard already uses. Reused rather than
/// re-implemented, for the reason its own doc gives: one tested brace reader in
/// this target, not two. Its LIMIT comes with it — a `{` inside a string literal
/// would misbalance the count, and `swiftCodeWithoutComments` keeps literals.
/// Nothing this reads carries a brace in one today.
///
/// A `Picker(` with no block, or an unbalanced one, counts as enclosing
/// NOTHING. Skipping it is what makes the guard fail rather than pass on a file
/// the walk cannot parse.
private func segmentedStylesOnAPicker(in code: String) throws -> Int {
    let declaration = try Regex(#"\bPicker\("#)
    var attached = 0

    for site in code.ranges(of: declaration) {
        let fromDeclaration = String(code[site.lowerBound...])
        let afterNeedle = fromDeclaration.index(fromDeclaration.startIndex,
                                                offsetBy: "Picker(".count)
        guard let open = fromDeclaration[afterNeedle...].firstIndex(of: "{"),
              let block = braceBlock(after: "Picker(", in: fromDeclaration)?.block
        else { continue }

        let tail = fromDeclaration[fromDeclaration.index(open, offsetBy: block.count)...]
        if modifierChain(after: tail).contains(".pickerStyle(.segmented)") {
            attached += 1
        }
    }
    return attached
}

@Test("the tint is applied per-picker, so state never paints a non-segment control")
func tintIsConfinedToTheHeldSegments() throws {
    let source = try panelSource()

    let tints = source.components(separatedBy: ".tint(brand(.state))").count - 1
    let pickers = source.components(separatedBy: ".pickerStyle(.segmented)").count - 1

    // The styles that a `Picker` ACTUALLY ENCLOSES, which closes a hole that
    // comment-stripping alone does not.
    //
    // `pickers` counts `.pickerStyle(.segmented)`, which is a MODIFIER and not
    // a control. Comment out a `Picker`'s body and leave its modifiers behind
    // and they simply chain onto whatever view precedes them — `Text` accepts
    // `.pickerStyle` and `.labelsHidden()` happily, and it all compiles. Every
    // other assertion here then holds over a panel with no Serving control at
    // all: measured GREEN, and still GREEN after the stripping fix, which is
    // why this is here and not left to the reader.
    let onAPicker = try segmentedStylesOnAPicker(in: source)

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

    // ADJACENCY. Every segmented style must sit in the modifier chain of a
    // `Picker` that is actually declared. Named bug this catches: the control
    // removed while its modifiers stay, which every other assertion here reads
    // as a healthy panel. Why this is not the file-wide comparison it replaces
    // — issue #59, two cancelling edits — is on `segmentedStylesOnAPicker`.
    #expect(onAPicker == pickers, """
        \(pickers) .pickerStyle(.segmented) modifier(s) in PanelView.swift, but \
        \(onAPicker) of them sit in the modifier chain of a Picker( that is \
        actually declared. A segmented style no Picker encloses is a modifier \
        chained onto whatever view precedes it — the control is gone. Counting \
        Picker( declarations file-wide would not see this: a second picker \
        elsewhere balances the totals.
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

@Test("a segmented style no Picker encloses fails, even when the file-wide totals balance")
func aSegmentedStyleNoPickerEnclosesIsNotAttached() throws {
    // The exact shape issue #59 names: TWO CANCELLING EDITS. The Serving
    // control is gone — its `.pickerStyle(.segmented)` now chains onto a
    // `Group` — and a second `Picker(` elsewhere in the file puts the
    // file-wide totals back to 1 == 1. The check this replaces compared
    // exactly those two totals, and it was MEASURED green on this shape
    // rendered into `PanelView.swift`.
    let cancelled = """
        Picker("Roast", selection: $roast) {
            Text("light").tag(Roast.light)
        }
        .pickerStyle(.menu)
        Group {
            Text("stop")
            Text("auto")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(brand(.state))
        """

    // The fixture is only worth having if the OLD rule PASSES it — a fixture
    // the old totals already caught proves nothing new. Asserted rather than
    // claimed in prose, so the day someone edits this fixture into an
    // unbalanced one, this line says so instead of the coverage quietly
    // evaporating.
    #expect(cancelled.components(separatedBy: ".pickerStyle(.segmented)").count - 1 == 1)
    #expect(cancelled.components(separatedBy: "Picker(").count - 1 == 1)

    #expect(try segmentedStylesOnAPicker(in: cancelled) == 0, """
        a .pickerStyle(.segmented) chained onto a Group belongs to no Picker, \
        whatever the file-wide totals say
        """)

    // The positive control. Without it the assertion above is satisfied by a
    // function that returns 0 for every input.
    let intact = """
        Picker("Serving", selection: $model.intent) {
            Text("stop").tag(UserIntent.stop)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(brand(.state))
        """
    #expect(try segmentedStylesOnAPicker(in: intact) == 1,
            "the shipped shape — the style directly on the Picker — must count")

    // Comments reach the walk as WHITESPACE-ONLY lines: `panelSource()` strips
    // them and keeps line structure. A blank line does not end a Swift modifier
    // chain and must not end this one — the shipped panel explains its `.tint`
    // in four comment lines MID-CHAIN, so ending on the first blank would read
    // the real file wrong.
    let spaced = """
        Picker("Serving", selection: $model.intent) {
            Text("stop").tag(UserIntent.stop)
        }

        .pickerStyle(.segmented)
        """
    #expect(try segmentedStylesOnAPicker(in: spaced) == 1,
            "a blank line inside a modifier chain does not detach the style")
}

@Test("DatePicker and ColorPicker do not supply the Picker a segmented style needs")
func onlyAPickerDeclarationSatisfiesTheSegmentedCount() throws {
    // `DatePicker` and `ColorPicker` are real SwiftUI controls and both are
    // plausible in this panel. Neither is a segmented picker, and a substring
    // match on `Picker(` counts both — so a rename to either one keeps the
    // file-wide totals balanced with no segmented control left anywhere.
    for control in ["DatePicker", "ColorPicker"] {
        let code = """
            \(control)("Serving", selection: $value) {
                Text("stop")
            }
            .pickerStyle(.segmented)
            """
        #expect(try segmentedStylesOnAPicker(in: code) == 0,
                "\(control)( must not satisfy the Picker half of the count")
    }

    // The control: the same fixture with the real declaration counts 1, which
    // is what says the loop above measures the word boundary and not a walk
    // that is simply broken.
    let real = """
        Picker("Serving", selection: $value) {
            Text("stop")
        }
        .pickerStyle(.segmented)
        """
    #expect(try segmentedStylesOnAPicker(in: real) == 1,
            "the same fixture with a plain Picker( must count")
}

@Test("the indicator comes from the model, not from a symbol name typed here")
func indicatorComesFromTheModel() throws {
    let source = try panelSource()
    #expect(source.contains("ServingModel.indicator("),
            "the indicator must come from ServingModel.indicator(isServing:)")
}

/// EVERY surface that renders an advisory, and the model values each one reads.
///
/// TWO FILES, and that is the whole of issue #30's remainder. The list this
/// replaces was one flat array read against `PanelView.swift` alone, so the
/// identical `staleHelperAdvisory` sentence in `PreferencesView.swift` — same
/// model value, same systemOrange — was never looked at. Issue #30 closed with
/// four sites fixed, a fifth shipping the defect, and this guard green.
///
/// `staleHelperAdvisory(` keeps its parenthesis because that one is a CALL
/// taking the probe path while the others are properties, and the shorter
/// needle would also match the `ServingModel` mention in a neighbouring
/// expression. Every value is NAMED rather than counted, so an advisory DELETED
/// from a surface fails the guard instead of shrinking a total that still
/// balances.
///
/// The split between the two lists is a DESIGN DECISION, not a convenience.
///
///   `throughTheRow` — the advisories that carried systemOrange and now carry
///   the symbol instead. They must render through `AdvisoryRow`, so the four in
///   the panel and the one in the window cannot drift apart a site at a time.
///
///   `neutralOnly` — advisories that never carried the pigment and are
///   deliberately QUIETER than the panel's copy of the same sentence.
///   `PreferencesView.swift` states the reason on its `hookAdvisory`: the panel
///   is where the user notices the problem and this window is where they act on
///   it, so the window restates it in `.secondary` rather than shouting it
///   twice. They are still held to the no-pigment half — that rule is about
///   contrast and admits no exceptions — but not to the symbol.
///
/// BOTH lists require the value to be PRESENT. A surface that stops rendering an
/// advisory named here fails; it does not quietly drop out of the loop.
private let advisorySurfaces: [(file: String, throughTheRow: [String], neutralOnly: [String])] = [
    (file: "PanelView.swift",
     throughTheRow: ["model.suppressionAdvisory",
                     "model.hookAdvisory",
                     "model.ingestAdvisory",
                     "model.staleHelperAdvisory("],
     neutralOnly: []),
    (file: "PreferencesView.swift",
     throughTheRow: ["model.staleHelperAdvisory("],
     neutralOnly: ["model.hookAdvisory"]),
]

/// The two foreground styles that carry NO pigment.
private let neutralForegrounds: Set<String> = [".primary", ".secondary"]

/// Every colour a span of view code paints, as the ARGUMENT each paint modifier
/// was handed.
///
/// The caller then applies an ALLOWLIST, and that direction is the whole
/// design. Issue #30's guard was a count of `.foregroundStyle(.orange)`, which
/// pins one spelling of one pigment: `.foregroundColor(.orange)`,
/// `.foregroundStyle(Color.orange)` and `.foregroundStyle(brand(.warning))`
/// all put the same systemOrange on the same line and all walk straight past a
/// search for that literal. Reading the ARGUMENT and requiring it to be one of
/// the two non-colour semantics refuses every spelling of every pigment,
/// including one nobody has written yet — which is what a count of ZERO cannot
/// do, because a count of zero is also what an empty file scores.
///
/// The argument is read to the first `)` or newline, so a nested call arrives
/// truncated and unbalanced — `brand(.warning` — which is never `.primary` and
/// is therefore refused. That is the right answer rather than a limitation: a
/// call is exactly how a pigment reaches this modifier without naming a colour.
///
/// `tint(` is read alongside the two foreground modifiers because `.tint` is an
/// Environment value: one on a container paints every control below it, which
/// is the regression `tintIsConfinedToTheHeldSegments` above already measured.
private func paints(in code: String) -> [String] {
    var arguments: [String] = []
    for modifier in ["foregroundStyle(", "foregroundColor(", "tint("] {
        for span in code.components(separatedBy: modifier).dropFirst() {
            arguments.append(String(span.prefix { $0 != ")" && $0 != "\n" })
                .trimmingCharacters(in: .whitespaces))
        }
    }
    return arguments
}

/// The paints in `code` that are not one of the two neutral semantics.
private func pigments(in code: String) -> [String] {
    paints(in: code).filter { neutralForegrounds.contains($0) == false }
}

/// The paints on a surface that neither name a neutral semantic nor ask
/// `BrandPalette` for a role.
///
/// The `brand(` prefix is what makes this an allowlist: every colour on these
/// surfaces asks the palette for a role, which is the route that lets a test
/// read the value. A hex or a system colour named in the view is refused
/// whatever it is.
private func unroutedPaints(in code: String) -> [String] {
    paints(in: code).filter {
        neutralForegrounds.contains($0) == false && $0.hasPrefix("brand(") == false
    }
}

/// The paints that reach systemOrange THROUGH the palette.
///
/// `unroutedPaints` accepts any `brand(` call as routed, and that is not by
/// itself evidence of a legible colour: `BrandPalette.rgb` returns `nil` for
/// `.warning` and `color(_:scheme:contrast:)` falls through to `.orange` for it,
/// so `brand(.warning)` puts the EXACT pigment issue #30 removed back on the
/// screen while satisfying the allowlist. Measured, not reasoned: `.warning` is
/// the one role with no hex, and `.orange` is the literal returned in its place.
///
/// This is a hole in the allowlist rather than in the advisory checks —
/// `pigments` already refuses `brand(.warning` on an advisory, because the
/// argument arrives truncated at the first `)` and truncated is never `.primary`
/// — so what it closes is the "and nowhere else on this surface" half: a heading
/// or a button free to take the pigment the advisories just gave up.
///
/// `.warning` still has no production caller. This keeps it that way in the two
/// files that used to spend the colour, rather than trusting a comment to.
private func warningPaints(in code: String) -> [String] {
    paints(in: code).filter { $0.contains(".warning") }
}

/// How many files under `Sources/CoffeeBarUI` declare the advisory treatment.
///
/// MODULE-WIDE, and the breadth is the point. The count this replaces read one
/// file, so a second declaration in a sibling file was invisible to it — which
/// is the same blindness, in the same guard, that let the fifth advisory ship.
/// Two treatments named `AdvisoryRow` is exactly how the surfaces drift apart
/// again with every assertion below still green, because each one would be
/// reading whichever declaration it found first.
private func advisoryRowDeclarations() throws -> Int {
    try filesUnderCoffeeBarUI(naming: "struct AdvisoryRow: View").count
}

/// The files under `Sources/CoffeeBarUI` whose CODE contains `needle`.
///
/// Comment-stripped through `uiSource`, so the prose in `AdvisoryRow.swift` that
/// explains the treatment cannot answer for the treatment.
private func filesUnderCoffeeBarUI(naming needle: String) throws -> [String] {
    let names = try FileManager.default
        .contentsOfDirectory(atPath: uiSourceDirectory().path)
        .filter { $0.hasSuffix(".swift") }
        .sorted()
    return try names.filter { try uiSource($0).contains(needle) }
}

@Test("one advisory treatment exists in the module, and no surface keeps its own")
func exactlyOneSurfaceDeclaresTheAdvisoryTreatment() throws {
    // THE LEFTOVER, which is a real state this branch passed through rather
    // than a hypothetical. Lifting `advisoryRow` out of `PanelView` and
    // forgetting to delete the original leaves the module with TWO treatments:
    // `AdvisoryRow.swift` and a private copy on the panel. Every other check in
    // this file stays green through that — `advisoryRowDeclarations()` counts
    // `struct AdvisoryRow: View` and a leftover `func advisoryRow(` is not one,
    // and the per-advisory checks pass the moment the call sites are repointed.
    //
    // Two treatments is the precondition for the drift issue #30 shipped: the
    // panel's four advisories and the window's one rendered from different
    // declarations, so a change to either reached only half the product.
    let privateCopies = try filesUnderCoffeeBarUI(naming: "func advisoryRow(")
    #expect(privateCopies.isEmpty, """
        \(privateCopies) still declare their own func advisoryRow(. The \
        treatment lives in AdvisoryRow.swift; a surface that keeps a private \
        copy is how the advisories drifted apart in the first place, and \
        repointing the call sites does not remove it.
        """)

    // THE SYMBOL, module-wide, which catches the same leftover under any other
    // name. A duplicate treatment called `warningRow(` or written inline at a
    // call site walks straight past the check above, and the one thing it
    // cannot do without is the mark that replaced the colour.
    let symbolSites = try filesUnderCoffeeBarUI(naming: "exclamationmark.triangle")
    #expect(symbolSites == ["AdvisoryRow.swift"], """
        the warning symbol is rendered by \(symbolSites). It belongs to exactly \
        one file: every advisory on every surface draws it through AdvisoryRow, \
        so a second file naming it is a second treatment whatever it is called.
        """)
}

@Test("on every surface, each advisory carries the warning symbol and no colour")
func advisoriesCarryShapeRatherThanColour() throws {
    // REPLACES a count of `.foregroundStyle(.orange)` that asserted exactly
    // four. That guard pinned the defect issue #30 is about: systemOrange as
    // caption TEXT reaches 1.75:1 to 2.31:1 on the light backdrops this panel
    // draws on, where WCAG asks 4.5:1 below ~18pt. Dark appearance passes at
    // 7.62:1 and up; light does not, and darkening the pigment until it clears
    // 4.5:1 lands on roughly `#8C5200` — the roast `state` colour, which
    // collapses the one distinction the two accents exist to draw.
    //
    // The count could not simply move to 0, and that is the reason this guard
    // is shaped the way it is. Zero is what a correct panel scores AND what a
    // panel with no advisories at all scores, AND what a panel that paints them
    // `.foregroundColor(.orange)` scores. Every assertion below is therefore
    // POSITIVE — it names what the advisory must BE — and the one negative
    // check is an allowlist over what it may paint, never a search for the
    // spelling that happened to ship.
    //
    // COUPLED TO `ColorRole.warning`, and this note is one half of a pair.
    // `.warning` still has no production caller: routing the advisories through
    // `brand(.warning)` would resolve to the same systemOrange this guard now
    // refuses. `BrandPalette.swift` carries the other half, on the `ColorRole`
    // declaration, and its note about a count of four is what this replaces.

    // BOTH SURFACES, asserted rather than assumed. The defect this guard now
    // exists to catch is not "an advisory went orange" — it is "an advisory went
    // orange somewhere this guard does not read". Shrinking the table back to
    // one file is that defect, and it would otherwise be a silent edit.
    #expect(advisorySurfaces.map(\.file).sorted() == ["PanelView.swift", "PreferencesView.swift"], """
        this guard reads \(advisorySurfaces.map(\.file).sorted()). Issue #30's \
        remainder was a FIFTH orange advisory in PreferencesView.swift that \
        survived a change whose whole purpose was removing them, because the \
        guard read PanelView.swift and nothing else. A surface dropped from \
        this table is a surface no check reads.
        """)

    // ONE treatment, MODULE-WIDE. The count is load-bearing: every check below
    // reaches the advisories through `AdvisoryRow`, so a second declaration of
    // that name would let the surfaces drift apart while this guard stayed
    // green, each half reading whichever declaration it happened to find.
    let declarations = try advisoryRowDeclarations()
    #expect(declarations == 1, """
        Sources/CoffeeBarUI declares struct AdvisoryRow: View \(declarations) \
        times. This guard reads ONE treatment and requires every advisory on \
        every surface to route through it; at any other count it is measuring \
        something else.
        """)

    let treatment = try #require(braceBlock(after: "var body: some View",
                                            in: try uiSource("AdvisoryRow.swift"))?.block, """
        AdvisoryRow.swift opens no balanced body block, so this guard cannot \
        tell what an advisory renders.
        """)

    // THE SYMBOL, which is what carries the meaning now that the colour is
    // gone. Issue #30's own words: the warnings get quieter, and the dead
    // socket is the line users most need to notice. Drop the symbol and the
    // advisory is an unremarkable caption in a column of captions — the exact
    // cost this change accepted and undertook to pay in shape instead.
    #expect(treatment.contains("exclamationmark.triangle"), """
        the advisory treatment in AdvisoryRow.swift renders no \
        exclamationmark.triangle. With the orange gone the symbol is the ONLY \
        thing separating a warning from the ordinary caption above it.
        """)

    // ANTI-VACUITY for the check above: a treatment that draws a symbol and no
    // sentence would satisfy it while telling the user nothing.
    #expect(treatment.contains("Text(line)"), """
        the advisory treatment in AdvisoryRow.swift draws no Text(line), so \
        whatever the model published reaches the user nowhere.
        """)

    // The treatment states its own non-colour foreground rather than inheriting
    // one. `.primary` and not `.secondary`: the summary line beside it is
    // already `.secondary`, and an advisory that reads lighter than the neutral
    // sentence above it is quieter than the thing it interrupts.
    #expect(paints(in: treatment).contains(".primary"), """
        the advisory treatment in AdvisoryRow.swift states no .primary \
        foreground, so the advisory takes whatever the enclosing stack happens \
        to set — including .secondary, which draws a warning fainter than the \
        neutral line beside it.
        """)

    #expect(pigments(in: treatment).isEmpty, """
        the advisory treatment in AdvisoryRow.swift paints \
        \(pigments(in: treatment)). Painting it once, in the shared treatment, \
        colours every advisory on every surface at a stroke.
        """)

    // Every advisory on every surface, and the loop is what makes this guard
    // span the module rather than one file.
    for surface in advisorySurfaces {
        let source = try uiSource(surface.file)

        for value in surface.throughTheRow {
            let block = try #require(braceBlock(after: value, in: source)?.block, """
                \(surface.file) does not open a balanced block after \(value), \
                so this guard cannot read what that advisory renders. A missing \
                advisory is a failure, not a skip.
                """)

            #expect(block.contains("AdvisoryRow("), """
                the advisory driven by \(value) in \(surface.file) does not \
                render through AdvisoryRow(, so it carries neither the symbol \
                nor the foreground the others do. A treatment written out at \
                one site is how the surfaces drift apart.
                """)

            #expect(pigments(in: block).isEmpty, """
                the advisory driven by \(value) in \(surface.file) paints \
                \(pigments(in: block)). Advisory text carries no pigment at \
                all: assets/art/README.md line 22 states the rule — "Neither \
                accent carries body text" — and issue #30 measured why \
                systemOrange in particular cannot, at 1.75:1 to 2.31:1 on a \
                light backdrop against a 4.5:1 floor.
                """)
        }

        // The no-pigment half ALONE for these, and the asymmetry is deliberate:
        // see `advisorySurfaces`. They never carried the colour and are meant
        // to read quieter than the panel's copy of the same sentence, so the
        // symbol would be a change issue #30 never asked for. The contrast rule
        // still binds them, because that one is about legibility.
        for value in surface.neutralOnly {
            let block = try #require(braceBlock(after: value, in: source)?.block, """
                \(surface.file) does not open a balanced block after \(value), \
                so this guard cannot read what that advisory renders. A missing \
                advisory is a failure, not a skip.
                """)

            #expect(pigments(in: block).isEmpty, """
                the advisory driven by \(value) in \(surface.file) paints \
                \(pigments(in: block)). An advisory carries no pigment on any \
                surface — this one is exempt from the SYMBOL, never from the \
                colour rule.
                """)
        }

        // AND NOWHERE ELSE ON THIS SURFACE. The guard this replaces said
        // "orange is spent on exactly the four advisory lines", so it also held
        // the rest of the file; dropping that half would leave a surface free
        // to paint a heading or a button with the pigment the advisories just
        // gave up.
        let surfacePaints = paints(in: source)
        #expect(surfacePaints.isEmpty == false, """
            this guard found no foreground style at all in \(surface.file), \
            which means it is reading something other than that surface.
            """)

        #expect(unroutedPaints(in: source).isEmpty, """
            \(surface.file) paints \(unroutedPaints(in: source)) directly. \
            Colour on this surface comes from brand(_:) — so a test can read \
            the value — or it is one of the neutral semantics. A colour named \
            in the view is a colour no check reads.
            """)

        // The allowlist above admits ANY brand( call, and one of the roles is
        // the pigment this whole issue is about. See `warningPaints`.
        #expect(warningPaints(in: source).isEmpty, """
            \(surface.file) paints \(warningPaints(in: source)). brand(.warning) \
            resolves to SwiftUI .orange — BrandPalette.rgb returns nil for that \
            role and color(_:scheme:contrast:) falls through to the literal — so \
            it puts back the exact systemOrange issue #30 removed while \
            satisfying the brand( allowlist above.
            """)
    }
}

@Test("the advisory guard refuses every spelling of a pigment, not just the one that shipped")
func theAdvisoryGuardRefusesEverySpellingOfAPigment() throws {
    // The four routes to systemOrange on a caption. The first is what shipped
    // and what the count this replaces was written against; the other three
    // paint the identical pigment and walk past a search for it. `.red` is here
    // because the defect is a COLOUR on advisory text, not an orange one.
    for spelling in [".orange", "Color.orange", "brand(.warning)", ".red"] {
        let painted = """
            if let line = model.hookAdvisory {
                AdvisoryRow(line: line)
                    .foregroundStyle(\(spelling))
            }
            """
        #expect(pigments(in: painted).isEmpty == false,
                "a .foregroundStyle(\(spelling)) on an advisory must be refused")
    }

    // `.foregroundColor` is the deprecated spelling and still compiles, so a
    // guard that reads only `.foregroundStyle` has a hole the size of one
    // autocomplete.
    #expect(pigments(in: "Text(line).foregroundColor(.orange)").isEmpty == false,
            "the deprecated foregroundColor spelling must be refused too")

    // `.tint` descends through the Environment, so one on the container above
    // an advisory paints it without ever naming it.
    #expect(pigments(in: "VStack { AdvisoryRow(line: line) }.tint(.orange)").isEmpty == false,
            "a .tint above an advisory must be refused")

    // THE HOLE IN THE OTHER HALF, and this pair is the whole argument for
    // `warningPaints` existing at all.
    //
    // `unroutedPaints` is the "and nowhere else on this surface" check, and it
    // treats any `brand(` call as routed — which is right for `.state` and
    // `.rest`, and wrong for exactly one role. The first assertion PROVES the
    // hole rather than describing it: the allowlist really does wave
    // `brand(.warning)` through. The second is what closes it.
    let throughThePalette = "Text(line).foregroundStyle(brand(.warning))"
    #expect(unroutedPaints(in: throughThePalette).isEmpty, """
        the brand( allowlist is supposed to admit this spelling — that is the \
        hole warningPaints closes. If this line ever fails, the allowlist \
        changed and warningPaints may now be dead weight.
        """)
    #expect(warningPaints(in: throughThePalette).isEmpty == false,
            "brand(.warning) resolves to systemOrange and must be refused")

    // THE POSITIVE CONTROL for that second reader. Without it, a `warningPaints`
    // that answers non-empty for every input passes the line above while turning
    // the two shipped surfaces red for their legitimate roast colour.
    for legible in ["brand(.state)", "brand(spec.role)", ".secondary"] {
        #expect(warningPaints(in: "Text(x).foregroundStyle(\(legible))").isEmpty,
                "\(legible) does not resolve to systemOrange and must pass")
    }

    // THE POSITIVE CONTROL. Without it every assertion above is satisfied by a
    // `pigments` that answers non-empty for any input at all — including the
    // shipped panel, where this guard would then be red forever and get
    // deleted rather than believed.
    let neutral = """
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(line)
        }
        .foregroundStyle(.primary)
        """
    #expect(pigments(in: neutral).isEmpty,
            "the shipped shape — a symbol and a .primary sentence — must pass")

    // The second control, on the other half: a paint that is neutral in one
    // place and a pigment in another is a reader that cannot tell them apart.
    #expect(paints(in: neutral) == [".primary"],
            "the reader must return the argument it was handed, not a verdict")
}
