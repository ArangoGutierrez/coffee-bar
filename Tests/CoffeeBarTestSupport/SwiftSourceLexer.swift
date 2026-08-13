// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing

// The comment-stripping lexer, declared ONCE for every test target.
//
// **Why this target exists.** `swiftCodeWithoutComments` was declared inside
// `Tests/CoffeeBarUITests/AppLayerBoundary_test.swift`, so it was reachable
// only from `CoffeeBarUITests`. Two other targets needed the same
// discriminator and could not import it:
//
//   * `CoffeeBarPowerTests/PolicyDocumentClaims_test.swift` re-implemented a
//     cruder `commentFragments` and said why — "because a precise answer needs
//     the tokenizer that `swiftCodeWithoutComments` has, in a target this one
//     cannot import".
//   * `CoffeeBarCoreTests/DocsClaims_test.swift`'s `sourcesContain` was a raw
//     `body.contains`, so a control named only in a Swift COMMENT satisfied
//     the guard that exists to prove the control is real (issue #40).
//
// A third copy would make issue #54's detect-and-refuse fix apply twice, or
// silently keep the hole in whichever copy was forgotten. One declaration
// closes that for every caller at once.
//
// **Why it is a plain `.target` and not a `.testTarget`.** SwiftPM refuses a
// test target as a dependency, and a test target's `@Test` functions would be
// compiled into every bundle that took it. It lives under `Tests/` rather than
// `Sources/` because it is test scaffolding and must never ship: no product
// names it, so `scripts/build-app.sh --product coffee-bar` cannot reach it.
// `DocsClaims_test.swift`'s `sourcesContain` walks `Sources/` alone, so a
// phrase written here can never satisfy a control-existence claim either.
//
// It imports `Testing` for one reason — `Issue.record` below, which is issue
// #54's refusal. Moving that refusal to the callers would put it back in three
// places, which is the duplication this target removes.

/// Swift source with every COMMENT removed and every STRING LITERAL kept.
///
/// This is the discriminator the whole below-app scan rests on. A doc comment
/// that names `PreventUserIdleDisplaySleep` is exactly what
/// `AssertionHolder.swift` must keep saying; the same word in CODE raises the
/// assertion this product exists not to hold. A plain `contains` cannot tell
/// the two apart, so the comments go first and the check reads what is left.
///
/// String literals are KEPT, deliberately. `kIOPMAssertionTypePreventUserIdle`
/// `DisplaySleep` is a `String` constant whose value is the plain text
/// `"PreventUserIdleDisplaySleep"`, so
/// `IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString, …)`
/// raises a live display assertion while naming no constant anywhere. Stripping
/// literals would open that route.
///
/// LIMIT, stated rather than hidden: this is a small lexer, not the Swift
/// grammar. It handles `//`, nested `/* */`, escapes, multi-line `"""` and raw
/// `#"…"#` strings, all of which are what the scanned targets contain today. A
/// BARE REGEX LITERAL (`/…/`) it cannot tokenise at all.
///
/// INVARIANT, and it is the whole of issue #54: this returns a verdict only for
/// source it can TOKENISE. Anything that might be a regex literal makes it
/// refuse — loudly, as a recorded issue — because a wrong GREEN on the network
/// scan is a guard reporting a forbidden capability absent while it is present,
/// and a false alarm is not. The refusal is therefore one-sided on purpose: it
/// may cry wolf over source that is really division, and it may not stay quiet
/// over source that is really a literal.
///
/// Every guard in this package reaches the lexer through THIS function, so the
/// refusal covers all of them rather than the three the issue names. Reach for
/// `swiftSourceReading` instead only to state what the walk itself does, which
/// is what the pinning table is for.
public func swiftCodeWithoutComments(_ source: String) -> String {
    let reading = swiftSourceReading(source)
    if let suspect = reading.regexLiteralSuspect {
        Issue.record("""
            this scan REFUSES a verdict rather than reporting one it cannot \
            support. The source it was handed carries what may be a bare regex \
            literal — \(suspect.debugDescription) — and this lexer cannot \
            tokenise one: the text after it comes back mis-classified, a \
            comment as code or code as a comment, so a check downstream can \
            report a forbidden capability absent while it is present (issue \
            #54). Either take the literal out of that source, or teach the \
            lexer to read one and pin the new behaviour in \
            swiftCodeWithoutCommentsKeepsCodeAndDropsComments.
            """)
    }
    return reading.code
}

/// What one walk of `source` found: the code, and any reason to distrust it.
public struct SwiftSourceReading {
    /// `source` with every COMMENT removed and every STRING LITERAL kept.
    public let code: String

    /// The first line carrying something that might be a bare regex literal,
    /// or `nil` when the walk met none.
    ///
    /// A reading with a suspect is a reading `code` cannot be trusted for: the
    /// walk took the literal's contents for something else and everything
    /// after it may be mis-classified in either direction.
    public let regexLiteralSuspect: String?
}

/// One walk of `source`, reported whole: the stripped code, and whether the
/// walk met anything it cannot tokenise.
///
/// Separate from `swiftCodeWithoutComments` so the pinning table can state what
/// the lexer DOES with a regex literal without tripping the refusal that
/// entry point makes of it.
///
/// The suspect test is Swift's own disambiguation (SE-0354): a bare regex
/// literal may not open with a space or tab, may not close with one, and lives
/// on a single line. `total / 2 / 1` is division under that rule and reads
/// clean; `/"/` is not, and refuses. It is deliberately one-sided — it can cry
/// wolf over source that is really division, and that costs a false alarm,
/// where staying silent over a real literal costs a wrong GREEN.
public func swiftSourceReading(_ source: String) -> SwiftSourceReading {
    let characters = Array(source)
    var kept: [Character] = []
    kept.reserveCapacity(characters.count)
    var index = 0
    var regexLiteralSuspect: String?

    /// Whether `text` sits at `start`.
    func matches(_ text: [Character], at start: Int) -> Bool {
        guard start >= 0, start + text.count <= characters.count else { return false }
        for (offset, character) in text.enumerated() where characters[start + offset] != character {
            return false
        }
        return true
    }

    /// The whole line `start` sits on, so the refusal can quote it.
    func line(around start: Int) -> String {
        var from = start
        while from > 0 && characters[from - 1] != "\n" { from -= 1 }
        var through = start
        while through < characters.count && characters[through] != "\n" { through += 1 }
        return String(characters[from ..< through])
    }

    /// Whether the `/` at `start` could open a bare regex literal.
    ///
    /// Reached only for a `/` that opens neither `//` nor `/*`. It asks for the
    /// two halves SE-0354 requires of the literal and forbids of division: a
    /// non-blank character straight after the opening delimiter, and a closing
    /// `/` later on the SAME line with a non-blank character straight before
    /// it. A `//` or `/*` reached while looking for that close ends the search
    /// — the rest of the line is a comment, so no closing delimiter is there.
    func regexLiteralMightOpen(at start: Int) -> Bool {
        let opening = start + 1
        guard opening < characters.count, !characters[opening].isWhitespace else { return false }

        var cursor = opening
        while cursor < characters.count && characters[cursor] != "\n" {
            if matches(["/", "/"], at: cursor) || matches(["/", "*"], at: cursor) { return false }
            if characters[cursor] == "/"
                && characters[cursor - 1] != "\\"
                && !characters[cursor - 1].isWhitespace { return true }
            cursor += 1
        }
        return false
    }

    while index < characters.count {
        // A raw string opens with a run of `#` immediately before the quote.
        var hashes = 0
        while index + hashes < characters.count && characters[index + hashes] == "#" { hashes += 1 }
        let pounds = Array(repeating: Character("#"), count: hashes)

        if index + hashes < characters.count && characters[index + hashes] == "\"" {
            // A string literal. Copy it VERBATIM, delimiters and contents.
            let multiline = matches(["\"", "\"", "\""], at: index + hashes)
            let closing = Array(repeating: Character("\""), count: multiline ? 3 : 1) + pounds
            let opening = hashes + (multiline ? 3 : 1)
            kept.append(contentsOf: characters[index ..< index + opening])
            index += opening

            while index < characters.count {
                // `\` escapes the next character — in a raw string only when a
                // matching run of `#` follows it.
                if characters[index] == "\\" && matches(pounds, at: index + 1) {
                    let width = min(hashes + 2, characters.count - index)
                    kept.append(contentsOf: characters[index ..< index + width])
                    index += width
                    continue
                }
                if matches(closing, at: index) {
                    kept.append(contentsOf: characters[index ..< index + closing.count])
                    index += closing.count
                    break
                }
                kept.append(characters[index])
                index += 1
            }
            continue
        }

        if hashes > 0 {
            // A `#` that opens no string: an attribute, a macro, `#filePath`.
            // `#/` is the one thing it can be that this walk cannot read — an
            // EXTENDED regex literal, which unlike the bare form may run over
            // several lines, so `regexLiteralMightOpen` would not see its close.
            if regexLiteralSuspect == nil && matches(["/"], at: index + hashes) {
                regexLiteralSuspect = line(around: index)
            }
            kept.append(contentsOf: characters[index ..< index + hashes])
            index += hashes
            continue
        }

        if matches(["/", "/"], at: index) {
            // To the end of the line. The newline itself is kept next turn, so
            // the stripped text keeps its line structure.
            while index < characters.count && characters[index] != "\n" { index += 1 }
            continue
        }

        if matches(["/", "*"], at: index) {
            // Swift nests block comments, so this counts rather than scanning
            // for the first `*/`.
            var depth = 0
            while index < characters.count {
                if matches(["/", "*"], at: index) { depth += 1; index += 2; continue }
                if matches(["*", "/"], at: index) {
                    depth -= 1
                    index += 2
                    if depth == 0 { break }
                    continue
                }
                if characters[index] == "\n" { kept.append("\n") }
                index += 1
            }
            continue
        }

        // Reached only by a `/` that opens neither comment: division, or a bare
        // regex literal this walk is about to read as anything but one.
        if regexLiteralSuspect == nil && characters[index] == "/"
            && regexLiteralMightOpen(at: index) {
            regexLiteralSuspect = line(around: index)
        }

        kept.append(characters[index])
        index += 1
    }

    return SwiftSourceReading(code: String(kept), regexLiteralSuspect: regexLiteralSuspect)
}
