// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarTestSupport
@testable import CoffeeBarUI

/// Asserts the seam the panel renders, not the drawn text.
///
/// M1 design §5.4 forbids asserting on rendered AppKit text, so a sentence
/// composed inline in `body` is a sentence no check reads. `PanelVersionLine_test`
/// makes the same argument for the version line.
///
/// WHERE the line sits is a second question, and the seam cannot answer it:
/// `legalLine()` returns the same string wherever it is rendered. The two guards
/// at the foot of this file read `PanelView.swift` as SOURCE instead, which is
/// the route `AppLayerBoundary_test.swift` and `PreferencesView_test.swift`
/// already take for claims about a `body` no test target can render.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/PanelLegalLine_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

@Test func thePanelNamesTheLicenceTheRepositoryActuallyShips() throws {
    // Named bug: the panel keeps saying Apache-2.0 after the project relicenses.
    // That is a false legal claim displayed inside the product, and the two
    // facts live in different files, so nothing else would notice.
    let licence = try String(contentsOf: packageRoot.appending(path: "LICENSE"),
                             encoding: .utf8)
    #expect(licence.contains("Apache License") && licence.contains("Version 2.0"),
            "LICENSE is not Apache-2.0, so the panel line is a false claim")
    #expect(PanelView.legalLine().contains("Apache-2.0"),
            "the panel no longer names the licence the repository ships")
}

@Test func thePanelSaysThereIsNoWarranty() {
    // Named bug: the line is shortened to just the licence name to fit the
    // 260pt panel. The licence name alone tells a user nothing; "no warranty"
    // is the part that sets an expectation.
    #expect(PanelView.legalLine().contains("no warranty"))
}

@Test func theLegalLinkPointsAtThePublishedTermsPage() {
    // Named bug: a typo in the URL, or a link left pointing at the repository
    // root, so the one route from the product to its terms is dead.
    #expect(PanelView.legalURL().absoluteString
            == "https://arangogutierrez.github.io/coffee-bar/terms.html")
}

@Test func theTermsPageTheLinkPromisesExistsInThisRepository() {
    // Named bug: the link ships before the page does, or the page is renamed
    // and the panel is not updated. The site is served from `site/`, so the
    // last path component must be a file there.
    let file = PanelView.legalURL().lastPathComponent
    #expect(FileManager.default.fileExists(
        atPath: packageRoot.appending(path: "site/\(file)").path),
        "the panel links to \(file), which does not exist under site/")
}

private enum PanelScanError: Error, CustomStringConvertible {
    /// `PanelView.swift` does not declare the type this guard reads.
    case noDeclaration
    /// The declaration carries no `body`, so there is no footer to measure.
    case noBody

    var description: String {
        switch self {
        case .noDeclaration:
            return """
                PanelView.swift no longer declares `public struct PanelView: View`, so the \
                footer guards below read nothing and would otherwise have passed on an \
                empty string.
                """
        case .noBody:
            return """
                PanelView's declaration carries no balanced `var body: some View` block, so \
                the footer guards below measured nothing.
                """
        }
    }
}

/// `PanelView.body`, COMMENT-STRIPPED.
///
/// SCOPED TO THE TYPE FIRST, then to `body`, and both steps are load-bearing.
/// `PanelView.swift` declares two `View`s — `MenuBarLabel` at the top — so the
/// first `var body: some View` in the file is not this one, the trap
/// `PreferencesView_test.swift` records. Scoping to `body` then puts
/// `legalLine()`'s own declaration out of reach, so the offsets below measure
/// where the line is DRAWN and not where the string is defined.
///
/// COMMENT-STRIPPED for the reason every source guard in this package gives, and
/// here it decides the answer rather than tidying it: the paragraph beside the
/// `Link` says in prose where the line sits, and against raw text that sentence
/// alone would satisfy — or invert — an order check. `swiftCodeWithoutComments`
/// is the lexer `AppLayerBoundary_test.swift` rests on, reused rather than
/// re-implemented.
///
/// LIMITS, stated rather than hidden:
///
///   1. This reads SOURCE ORDER, never pixels. A `VStack` lays its children out
///      in declaration order, so the two are the same thing here — but an
///      `.overlay`, a `.position` or a second container would break that
///      correspondence and this guard would not see it. Design §5.4 rules out
///      the alternative: no check in this package may watch the panel draw.
///   2. `swiftCodeWithoutComments` KEEPS string literals, so a `{` or `}` inside
///      one would misbalance both readers. There is none in this file today —
///      its literals are labels like "Check now" and "Quit coffee-bar".
private func panelBody() throws -> String {
    let source = swiftCodeWithoutComments(try String(
        contentsOf: packageRoot.appending(path: "Sources/CoffeeBarUI/PanelView.swift"),
        encoding: .utf8))
    guard let declared = braceBlock(after: "public struct PanelView: View", in: source)
    else { throw PanelScanError.noDeclaration }
    guard let body = braceBlock(after: "var body: some View", in: declared.block)?.block
    else { throw PanelScanError.noBody }
    return body
}

/// The foot of the panel, TOP TO BOTTOM, as `PanelView.body` must spell it.
///
/// The order of this array IS the assertion. Each entry also carries how deeply
/// it may be nested below the `VStack`, in braces, and what those braces ARE —
/// naming them is what keeps the number checkable by the next reader.
///
/// `Text("Preferences…")` is the needle for the middle control because that
/// button is a `Button { … } label: { … }` with no literal in its declaration,
/// and the label is the only part of it spelled distinctly. It is therefore the
/// one entry that sits a brace deeper than its siblings: the `label:` closure.
///
/// THIS TABLE IS A DESIGNED UPDATE POINT. A legitimate container around the
/// footer — an `HStack` for the buttons, a `Group` — turns the nesting half red,
/// and the fix is to raise the number here and say which brace was added.
private let panelFooterTopToBottom: [(needle: String, what: String, braces: Int, enclosing: String)] = [
    ("Button(\"Check now\")", "the Check now button", 0, "nothing"),
    ("Text(\"Preferences…\")", "the Preferences… button", 1, "its label: closure"),
    ("Button(\"Quit coffee-bar\")", "the Quit coffee-bar button", 0, "nothing"),
    ("PanelView.legalLine()", "the licence line", 0, "nothing"),
]

@Test func theLicenceLineIsDrawnUnderTheFooterControlsAndNotBetweenThem() throws {
    // Named bug this catches: the licence line put back between "Check now" and
    // "Preferences…", where it shipped until now. It splits the three controls
    // into two groups with an unrelated sentence in the gap, so a user scanning
    // a 260pt column for Quit reads past a licence to find it.
    //
    // ORDER is the whole assertion. A `contains` cannot make it: all four of
    // these are present both before and after the move, so presence is exactly
    // the thing that does not discriminate here.
    let body = try panelBody()

    var previous: (offset: Int, what: String)?
    for entry in panelFooterTopToBottom {
        let site = try #require(body.range(of: entry.needle), """
            PanelView.body no longer spells \(entry.needle), so \(entry.what) is not in \
            the footer and this guard could not measure where it sits.
            """)
        let offset = body.distance(from: body.startIndex, to: site.lowerBound)
        if let previous {
            #expect(offset > previous.offset, """
                PanelView.body draws \(entry.what) ABOVE \(previous.what). The panel's \
                foot reads top to bottom: Check now, Preferences…, Quit coffee-bar, and \
                the licence line LAST, so the three controls sit together.
                """)
        }
        previous = (offset, entry.what)
    }
}

@Test func theLicenceLineIsRenderedAsUnconditionallyAsTheControlsItSitsUnder() throws {
    // Named bug this catches: the line moved below Quit by being wrapped rather
    // than moved — `if false { Link(…) }`, or the `Link` dropped INSIDE the Quit
    // button's closure. Either one is textually last, so the order guard above
    // passes while the panel renders no route to its terms at all. That defeat
    // is not hypothetical in this package: wrapping three Preferences controls in
    // `if false { … }` once left 856 tests green and the window empty.
    //
    // BRACE DEPTH against the siblings, which is the mechanism
    // `everyMovedControlIsRenderedAsUnconditionallyAsTheHeadingsAboveIt` uses for
    // the same defeat. Wrapping a line in an `if`, a `switch` or a closure adds a
    // brace and moves it.
    let body = try panelBody()

    // The anchor is pinned ABSOLUTELY and not by inequality. Every check below
    // is relative, so wrapping the WHOLE footer in one `if false { … }` shifts
    // all four equally and every relative comparison still holds. Two braces:
    // `body`'s and the `VStack`'s. A container added around the panel turns this
    // red, and the fix is to raise the number here rather than to relax it.
    let anchor = try #require(braceDepth(atFirst: "Button(\"Quit coffee-bar\")", in: body), """
        PanelView.body no longer spells Button("Quit coffee-bar"), so this guard has no \
        unconditional neighbour to compare the licence line against and measured nothing.
        """)
    #expect(anchor == 2, """
        the Quit button sits at brace depth \(anchor) inside PanelView.body, not the two \
        that body's brace and the VStack's account for. Either the panel grew a container \
        — say so here and raise the number — or the whole footer is wrapped in something, \
        which every relative check below would pass over.
        """)

    for entry in panelFooterTopToBottom {
        let depth = try #require(braceDepth(atFirst: entry.needle, in: body), """
            PanelView.body no longer spells \(entry.needle), so \(entry.what) is not in \
            the footer and its nesting could not be measured.
            """)
        #expect(depth == anchor + entry.braces, """
            PanelView.body puts \(entry.what) at brace depth \(depth), where \
            \(anchor + entry.braces) is what \(entry.enclosing) accounts for. It is inside \
            something its siblings are not, so it can be disabled — or nested into a \
            neighbour — with the order guard above still green.
            """)
    }
}
