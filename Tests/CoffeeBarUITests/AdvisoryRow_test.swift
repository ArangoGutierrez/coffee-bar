// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import CoffeeBarTestSupport

/// Reads `AdvisoryRow.swift` as CODE.
///
/// `#filePath` anchors the lookup to THIS source file, never to an installed or
/// deployed copy, so the guard cannot green-light a different tree than the one
/// under test. COMMENT-STRIPPED through `swiftCodeWithoutComments`, the lexer
/// `AppLayerBoundary_test.swift` declares and pins — reused rather than
/// re-implemented, for the reason its own doc gives: one tested stripper in this
/// target, not two. `AdvisoryRow.swift` explains its three compensations in
/// prose that names every symbol asserted below, so a raw read would find every
/// needle in the comments and pass over a body that renders none of them.
///
/// A file-private reader, which is this target's convention rather than an
/// oversight: `PanelPaletteWiring_test.swift` and `PreferencesView_test.swift`
/// each declare their own. What is shared is the STRIPPER and the brace reader,
/// which are the parts with logic to get wrong.
private func advisoryRowCode() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CoffeeBarUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
    return swiftCodeWithoutComments(try String(
        contentsOf: root.appendingPathComponent("Sources/CoffeeBarUI/AdvisoryRow.swift"),
        encoding: .utf8))
}

/// The three spans of the treatment, read apart so a modifier cannot satisfy an
/// assertion about the wrong subject.
///
/// SCOPING IS THE WHOLE POINT. `.accessibilityHidden(true)` on the SENTENCE
/// instead of the symbol hides the advisory from VoiceOver entirely — the exact
/// inverse of what it is there for — and a `contains` over the file reads that
/// catastrophe as healthy. The same holds for `.fixedSize`: on the image it does
/// nothing, on the text it is what stops a shell command truncating.
///
///   `image`  — the `Image` and its chain, up to where the sentence starts.
///   `text`   — the `Text` and its chain, to the end of the stack.
///   `row`    — what is chained onto the STACK, outside its block.
///
/// `row` comes from `braceBlock`'s `rest`, which is the code with the block cut
/// out: for a body of `{ HStack { … } .font(…) }` that is the `HStack(` opening
/// plus everything after the closing brace. A modifier on the stack and a
/// modifier on a child are different renders, and this is what tells them apart.
private struct TreatmentSpans {
    let image: String
    let text: String
    let row: String
    let stack: String
}

private func treatmentSpans() throws -> TreatmentSpans {
    let code = try advisoryRowCode()

    let body = try #require(braceBlock(after: "var body: some View", in: code)?.block, """
        AdvisoryRow.swift opens no balanced body block, so this guard cannot \
        read what an advisory renders.
        """)
    let stack = try #require(braceBlock(after: "HStack(", in: body), """
        AdvisoryRow's body opens no balanced HStack block. The treatment lays a \
        symbol beside a sentence; without the stack there is no beside.
        """)

    let symbol = try #require(stack.block.range(of: "Image(systemName:"), """
        AdvisoryRow's stack renders no Image(systemName:, so the symbol that \
        replaced the colour is not there at all.
        """)
    let sentence = try #require(stack.block.range(of: "Text("), """
        AdvisoryRow's stack renders no Text(, so whatever the model published \
        reaches the user nowhere.
        """)

    // ORDER, and it is asserted here rather than in a test of its own because
    // every span below is cut on it: read the other way round these two slices
    // silently swap, and each assertion would then be measuring the subject it
    // is named against. Bug it catches: the mark moved after the sentence,
    // where it reads as a trailing decoration rather than a warning.
    #expect(symbol.lowerBound < sentence.lowerBound, """
        AdvisoryRow renders its sentence BEFORE the warning symbol. The symbol \
        is the mark that says this line is a warning; after the sentence it is \
        a decoration the reader meets once the sentence is already read.
        """)

    return TreatmentSpans(
        image: String(stack.block[symbol.lowerBound ..< sentence.lowerBound]),
        text: String(stack.block[sentence.lowerBound...]),
        row: stack.rest,
        stack: stack.block)
}

@Test("the symbol is the filled triangle, sized as a mark rather than a character")
func theTreatmentCarriesTheFilledWarningSymbol() throws {
    let spans = try treatmentSpans()

    // THE FILLED VARIANT, not merely a triangle. `PanelPaletteWiring_test.swift`
    // asserts the prefix `exclamationmark.triangle`, which the OUTLINE satisfies
    // too — so swapping the fill away leaves that guard green. The fill is
    // load-bearing exactly as AdvisoryRow.swift states: at caption size a 1pt
    // stroke is nearly nothing, and with the colour gone this symbol is the only
    // thing separating a warning from the caption above it.
    #expect(spans.image.contains("exclamationmark.triangle.fill"), """
        AdvisoryRow does not render exclamationmark.triangle.fill. The outline \
        variant is a 1pt stroke at caption size — nearly invisible — and the \
        symbol is what pays for the pigment issue #30 removed.
        """)

    // A MARK BESIDE THE TEXT, not a character in it. Without this the symbol
    // renders at the caption's own size and reads as punctuation.
    #expect(spans.image.contains(".imageScale(.large)"), """
        AdvisoryRow does not scale its symbol up. At caption size an unscaled \
        symbol reads as a character inside the sentence rather than a mark \
        beside it, which is the distinction that makes it noticeable at all.
        """)
}

@Test("the symbol is hidden from VoiceOver and the sentence is not")
func theSymbolIsDecorativeAndTheSentenceCarriesTheMeaning() throws {
    let spans = try treatmentSpans()

    // ON THE IMAGE. The sentence beside it already says what the triangle
    // means, so VoiceOver announcing "warning triangle" before every advisory
    // is noise, not access — and colour never reached that route either, so
    // nothing was lost when it went.
    #expect(spans.image.contains(".accessibilityHidden(true)"), """
        AdvisoryRow does not hide its symbol from assistive technology. The \
        symbol restates what the sentence beside it already says; announced, it \
        prefixes every advisory with "warning triangle".
        """)

    // AND NOT ON THE SENTENCE, which is the catastrophic direction and the
    // reason these two spans are read apart at all. The sentence is the
    // accessible carrier — hidden, the advisory does not exist for a screen
    // reader, and every other assertion in this file still passes.
    #expect(spans.text.contains(".accessibilityHidden") == false, """
        AdvisoryRow hides its SENTENCE from assistive technology. The sentence \
        is the only accessible carrier the advisory has: colour never reached \
        VoiceOver and the symbol is deliberately hidden, so this removes the \
        advisory entirely rather than tidying it.
        """)
}

@Test("the sentence outweighs the neutral line it interrupts, and wraps rather than truncating")
func theSentenceIsWeightedAndWraps() throws {
    let spans = try treatmentSpans()

    // WEIGHT is the axis that replaced hue. `.primary` alone is asserted by
    // `PanelPaletteWiring_test.swift`; the semibold is not, and the pair is what
    // AdvisoryRow.swift names as the compensation — an advisory has to draw
    // DARKER and HEAVIER than the `.secondary` summary above it, and weight is
    // the half that survives a greyscale display and Differentiate Without
    // Color together.
    #expect(spans.text.contains(".fontWeight(.semibold)"), """
        AdvisoryRow does not weight its sentence. With hue spent, weight and \
        tone are the only axes left to separate a warning from the neutral \
        caption beside it; at the regular weight it is one more grey line.
        """)

    // WRAPPING, and this one has teeth: the stale-helper advisory carries a
    // command meant to be pasted into a root shell, rendered in a 260pt column.
    // Truncated, the user is shown the beginning of a command and no way to
    // reach the rest of it — the advisory actively misleads rather than merely
    // failing to help.
    #expect(spans.text.contains(".fixedSize(horizontal: false, vertical: true)"), """
        AdvisoryRow does not let its sentence grow vertically, so a long \
        advisory truncates in the 260pt panel. One of these sentences carries a \
        shell command; a truncated command is worse than no command.
        """)
}

@Test("the treatment states its own caption font rather than inheriting one")
func theTreatmentStatesItsOwnFont() throws {
    let spans = try treatmentSpans()

    // ON THE ROW, so both the symbol and the sentence take it, and STATED
    // rather than inherited. This treatment is now rendered from two different
    // surfaces with different ambient fonts — that is the whole reason it was
    // lifted out of PanelView — so a row that inherits its size renders one way
    // in the panel and another in the Preferences window from the same source.
    #expect(spans.row.contains(".font(.caption)"), """
        AdvisoryRow does not state its own font. It renders on two surfaces \
        with different ambient typography, so an inherited size means the same \
        advisory is a different size in each — from one declaration, which is \
        exactly what lifting it here was meant to prevent.
        """)
}

@Test("the row renders the line it was handed")
func theRowRendersTheLineItWasHanded() throws {
    let code = try advisoryRowCode()
    let spans = try treatmentSpans()

    // THE POSITIVE CONTROL for every assertion above. Without it they are all
    // satisfied by a treatment that draws a beautifully weighted symbol beside
    // a hardcoded string, or beside nothing at all — the reader would find each
    // needle and report a healthy row that tells the user nothing.
    #expect(code.contains("let line: String"), """
        AdvisoryRow declares no line property, so there is nothing for a caller \
        to hand it.
        """)
    #expect(spans.text.contains("Text(line)"), """
        AdvisoryRow does not render Text(line). Every check in this file passes \
        over a row that draws a symbol beside a literal; this is the one that \
        says the model's sentence is what reaches the user.
        """)
}
