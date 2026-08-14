// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

// The brace reader, declared ONCE for every test target.
//
// `Foundation` for `String.range(of:)` alone. `SwiftSourceLexer.swift` in this
// target needs no import for the same walk because it indexes a `[Character]`;
// this reader works in `String.Index` so that a caller can slice the original
// text without re-encoding it.
//
// **Why it lives here.** `braceBlock(after:in:)` was declared inside
// `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`, so only
// `CoffeeBarUITests` could reach it. `CoffeeBarCoreTests/DocsClaims_test.swift`
// needs the same reader to answer WHERE a control renders — a documented
// control is on the surface whose `body` block draws it, and a `body` block is
// exactly what this returns — and a test target cannot import another test
// target.
//
// This is the route `SwiftSourceLexer.swift` in this same target already took,
// and for the same reason: a second copy of a source reader is a second thing
// to get wrong, and two copies that drift disagree about what a block IS, which
// leaves two guards arguing rather than one answering.

/// The body of the first `{ … }` block that follows `needle` in `code`, and
/// `code` with that block cut out of it.
///
/// Written for a TRAILING closure, which a paren-balanced reader cannot reach:
/// the closure sits OUTSIDE the parentheses, so such a reader stops before it.
/// Splitting the file into "inside that block" and "everything else" is what
/// lets one guard hold two call sites of the SAME method INDEPENDENTLY. A
/// `contains` cannot: one call satisfies it for both.
///
/// Order does not take part. The block is removed wherever it sits, so moving
/// the registration above or below the other call site does not change either
/// answer.
///
/// LIMIT, stated rather than hidden, and it is the same limit
/// `argumentSpans(of:in:)` in `AppLayerBoundary_test.swift` carries:
/// `swiftCodeWithoutComments` KEEPS string literals, so a `{` or `}` inside one
/// would misbalance the count. Nothing the callers read carries a brace in a
/// literal today. It is a structural reader and not the Swift grammar.
///
/// It finds the FIRST `{` after `needle`, so a needle appearing more than once
/// in a file scopes to the earliest match. `PreferencesView_test.swift` composes
/// two calls — type first, then `body` — because `PanelView.swift` declares two
/// `View`s and the first `var body: some View` in it belongs to `MenuBarLabel`.
/// `DocsClaims_test.swift` composes the same two for the same reason.
public func braceBlock(after needle: String, in code: String)
    -> (block: String, rest: String)? {
    guard let found = code.range(of: needle),
          let open = code[found.upperBound...].firstIndex(of: "{")
    else { return nil }

    var depth = 0
    var cursor = open
    while cursor < code.endIndex {
        if code[cursor] == "{" { depth += 1 }
        if code[cursor] == "}" {
            depth -= 1
            if depth == 0 {
                let close = code.index(after: cursor)
                return (String(code[open ..< close]),
                        String(code[code.startIndex ..< open]) + String(code[close...]))
            }
        }
        cursor = code.index(after: cursor)
    }
    // Unbalanced. Reported as "no block" rather than as a span running to the
    // end of the file, so the caller fails rather than reads the whole file as
    // the block and passes.
    return nil
}
