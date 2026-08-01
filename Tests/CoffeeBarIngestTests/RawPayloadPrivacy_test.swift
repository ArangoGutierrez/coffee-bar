// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation

// Design §7 forbids reading conversation content. `PrivacyBoundary_test` guards
// that at the FIELD level, and guards it well: `HookEvent` declares no property
// for `transcript_path` or `last_assistant_message`, neither wire key survives a
// round trip, neither RECORDED VALUE reaches a stored property or a rendered
// string, and no file under `Sources` names either key.
//
// Every one of those guards either reads a TYPED event or looks for a field
// NAME. This file covers the hole that leaves — audit finding I5.
//
// BEFORE the decode the payload is untyped `Data`. One line inside
// `UnixSocketIngestListener.receive`, immediately before the decode —
//
//     NSLog("coffee-bar ingest: %@", String(data: body, encoding: .utf8) ?? "")
//
// — writes the whole POST to the unified log, the assistant reply text among
// it, where Console.app reads it and where it outlives the app. That line names
// no forbidden field: the variable is called `body`, and the bytes never become
// a typed property, so neither the field-name scan nor the `HookEvent`
// reflection can see it. MEASURED: with that line planted, all 383 checks
// stayed green.
//
// So this file guards the SINK rather than the field name. The rule is:
//
//     a logging call in the ingest path carries constant text and nothing else.
//
// Four decisions that rule rests on, each with the reason it is not the
// obvious alternative:
//
//   1. SCOPE is the `CoffeeBarIngest` target, because that is where the untyped
//      bytes live and the only place they live. `HTTPRequestFramer.buffer` and
//      the `body` handed to `JSONDecoder` are the two copies. What LEAVES the
//      target is a decoded `HookEvent`, and `PrivacyBoundary_test` already
//      proves that a rendered `HookEvent` carries neither field under any name,
//      so a `print` one layer up leaks nothing this rule needs to catch.
//
//   2. CONSTANT TEXT, not a denylist of raw-byte identifiers (`body`, `buffer`,
//      `chunk`, `data`). A denylist dies to one rename, and to one intermediate
//      variable: `let text = String(data: body, encoding: .utf8) ?? ""` followed
//      by `NSLog("%@", text)` names nothing forbidden. Refusing EVERY
//      non-constant argument closes the rename and the laundering together, and
//      it still permits the one thing this layer could legitimately log — a
//      fixed status message with no value in it.
//
//   3. COMMENTS ARE STRIPPED, and that is load-bearing rather than tidy.
//      MEASURED on this tree: `IngestListener.swift:41` names `NSLog` inside a
//      doc comment today, so a plain `contains` scan is RED on a CORRECT tree.
//      `AppLayerBoundary_test` met the same prose-versus-code problem and solved
//      it the same way.
//
//   4. INTERPOLATION IS KEPT AS CODE. `print("ingest: \(body)")` is ONE string
//      literal from end to end, so a lexer that blanked whole literals would
//      pass the most idiomatic leak in Swift. `swiftCodeWithStaticTextBlanked`
//      therefore blanks a literal's static text and keeps what is inside
//      `\( … )`. That is the opposite choice from
//      `AppLayerBoundary.swiftCodeWithoutComments`, which KEEPS literals whole
//      because the value it hunts is a plain constant string. Same problem,
//      different needle, so the two are separate functions on purpose.
//
// LIMITS, stated rather than hidden:
//
//   - `loggingRoutes` is a denylist. It bounds the sinks known today against an
//     unbounded API surface; it cannot prove no other route exists. Add a name
//     when a new one is found, and never read a pass as proof of absence.
//   - It covers LOGGING only. Bytes written to a file, or posted somewhere, are
//     a different sink and design §4 answers them by other means.
//   - `messageMethodRoutes` is matched on a RECEIVER — `log.error(`,
//     `log?.error(`, or a newline chained off a `)`, `]` or `}` — and never as
//     a bare word, because `error` is the name of every `NWConnection`
//     completion parameter in the file this scans. The price is a space:
//     `log .error(` reads as nothing, because stepping back over that space
//     reaches `case .error:` too. Nobody writes the first; the second is
//     ordinary Swift, and a guard that reports ordinary Swift gets deleted.
//   - A member route must be CALLED. `task.error`, `Level.error` and
//     `results[0].error` are member READS, and this rule reads the method name
//     without the receiver's type, so it cannot tell one from a `Logger`. Eight
//     such reads were measured as findings before that rule existed. The cost
//     is the alias: `let write = log.error` escapes, where `let write = NSLog`
//     does not. Two deliberate edits are needed to use it, and the alternative
//     was a guard that reported ordinary Swift.
//   - It reads the METHOD, never the receiver's type, so `Darwin.log(x)` and a
//     qualified enum case built with a value — `Level.error(code)` — are
//     reported as well. The ingest path does no arithmetic and declares no such
//     case, and a rule that had to resolve types would be a compiler.
//   - The lexer is small, not the Swift grammar. It handles `//`, nested
//     `/* */`, escapes, interpolation, multi-line `"""` and raw `#"…"#`, which
//     is what the scanned target contains. A bare regex literal (`/…/`) would
//     confuse it; the package uses none, and
//     `theScanTellsCodeFromCommentsAndKeepsWhatInterpolationCarries` pins the
//     behaviour either way.
//
// Nothing here can echo a payload: a failure quotes the call with its literals
// already blanked to `""`.

/// The package root, resolved from `#filePath`.
///
/// Never from the working directory: under `swift test` the working directory
/// is not the package root, and a guard that silently scans nothing is worse
/// than no guard at all.
private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarIngestTests/RawPayloadPrivacy_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarIngestTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

/// Every file the ingest path is allowed to compile, package-root relative and
/// sorted.
///
/// A literal, deliberately, and the same friction `AppLayerBoundary_test` uses:
/// a new file in this target turns `theScanReadsExactlyTheIngestPathsFiles` red
/// until a human updates the list, and updating it is the moment somebody reads
/// that file against design §7.
///
/// Cross-checked by a second instrument. `AppLayerBoundary_test` pins the same
/// two paths inside `expectedAppLayerEntries`, read from `swift package
/// describe` — what SwiftPM COMPILES — while this list is compared against a
/// directory walk. A file that defeats one of those is caught by the other.
private let ingestPathEntries = [
    "Sources/CoffeeBarIngest/HTTPRequestFramer.swift",
    "Sources/CoffeeBarIngest/IngestListener.swift",
]

/// Where a value could leave this process as text.
///
/// A denylist, and the second line of defence rather than the first — see the
/// LIMITS at the top of this file. `assert` and `precondition` are deliberately
/// ABSENT: their first argument is a boolean CONDITION, so a non-constant
/// argument is correct there and this rule would reject working code. The
/// `…Failure` forms take a message and nothing else, so they belong.
private let loggingRoutes = [
    "NSLog",
    "NSLogv",
    "os_log",
    "os_signpost",
    "OSLog",
    "OSSignposter",
    "Logger",
    "print",
    "debugPrint",
    "dump",
    "printf",
    "fprintf",
    "fputs",
    "fwrite",
    "syslog",
    "fatalError",
    "preconditionFailure",
    "assertionFailure",
    "FileHandle.standardOutput",
    "FileHandle.standardError",
]

/// The instance methods that take a message: `os.Logger`, then `OSSignposter`.
///
/// A SECOND list, because these are reached by a different route and matched by
/// a different rule. `Logger` is the sink that replaces `NSLog` on this
/// platform, and a message goes through an INSTANCE: `log.error("…")` names
/// neither `Logger` nor `os_log` anywhere on the line, so `loggingRoutes` —
/// which reads whole words — cannot see it. The receiver's name is the author's
/// to pick, so the method is the only fixed part to match on.
///
/// The 9 `Logger` methods are the whole message surface of that type. The 3
/// `OSSignposter` methods carry an interpolated message to the SAME unified log,
/// so leaving them out while `os_log` and `os_signpost` are both listed would be
/// an inconsistency a reader trips over.
///
/// These CANNOT be read as bare words the way `loggingRoutes` are. `error` is
/// what `NWConnection` calls the completion parameter, and
/// `IngestListener.receive` takes that parameter and tests it twice; a bare-word
/// rule reports those three lines, and none of them logs anything. `memberRoute`
/// therefore asks for a receiver before the dot, and for an argument list after
/// the name — see the LIMITS at the top of this file for what that costs.
private let messageMethodRoutes = [
    "log",
    "trace",
    "debug",
    "info",
    "notice",
    "warning",
    "error",
    "critical",
    "fault",
    "emitEvent",
    "beginInterval",
    "endInterval",
]

private func isIdentifierCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
}

// MARK: - The lexer

/// One frame of `swiftCodeWithStaticTextBlanked`'s state.
///
/// A STACK rather than a flag, because the two nest without limit: an
/// interpolation holds code, that code may open another string literal, and
/// that literal may interpolate again.
private enum LexicalFrame {
    /// Inside a string literal. Its static text is dropped.
    case literal(closing: [Character], pounds: [Character])
    /// Inside `\( … )`. Its contents are CODE, and `depth` counts the
    /// parentheses opened since, so the right `)` closes it.
    case interpolation(depth: Int)
}

/// Swift source with every COMMENT removed, every literal's STATIC TEXT blanked
/// to `""`, and everything inside `\( … )` kept as code.
///
/// The discriminator this whole file rests on. See decisions 3 and 4 at the top:
/// a comment that names `NSLog` is what `IngestListener.swift` says today, and
/// `\(body)` inside a literal is the leak this must not blank away.
private func swiftCodeWithStaticTextBlanked(_ source: String) -> String {
    let characters = Array(source)
    var kept: [Character] = []
    kept.reserveCapacity(characters.count)
    var frames: [LexicalFrame] = []
    var index = 0

    /// Whether `text` sits at `start`.
    func matches(_ text: [Character], at start: Int) -> Bool {
        guard start >= 0, start + text.count <= characters.count else { return false }
        for (offset, character) in text.enumerated() where characters[start + offset] != character {
            return false
        }
        return true
    }

    while index < characters.count {
        // Inside a literal: everything is dropped except an interpolation.
        if let frame = frames.last, case .literal(let closing, let pounds) = frame {
            // `\` escapes — in a raw literal only when its run of `#` follows.
            if characters[index] == "\\" && matches(pounds, at: index + 1) {
                let opener = index + 1 + pounds.count
                if opener < characters.count && characters[opener] == "(" {
                    kept.append("(")
                    frames.append(.interpolation(depth: 0))
                    index = opener + 1
                    continue
                }
                index = min(index + pounds.count + 2, characters.count)
                continue
            }
            if matches(closing, at: index) {
                index += closing.count
                frames.removeLast()
                continue
            }
            index += 1
            continue
        }

        // Code: the top level, or the inside of an interpolation.
        var hashes = 0
        while index + hashes < characters.count && characters[index + hashes] == "#" { hashes += 1 }

        if index + hashes < characters.count && characters[index + hashes] == "\"" {
            let multiline = matches(["\"", "\"", "\""], at: index + hashes)
            let pounds = Array(repeating: Character("#"), count: hashes)
            let closing = Array(repeating: Character("\""), count: multiline ? 3 : 1) + pounds
            // One blanked literal, whatever its text was. A `""` carries no
            // payload into a failure message and reads as what it is.
            kept.append(contentsOf: ["\"", "\""])
            index += hashes + (multiline ? 3 : 1)
            frames.append(.literal(closing: closing, pounds: pounds))
            continue
        }

        if hashes > 0 {
            // A `#` that opens no literal: an attribute, a macro, `#filePath`.
            kept.append(contentsOf: characters[index ..< index + hashes])
            index += hashes
            continue
        }

        if matches(["/", "/"], at: index) {
            // To the end of the line. The newline is kept next turn, so the
            // blanked text keeps its line structure.
            while index < characters.count && characters[index] != "\n" { index += 1 }
            continue
        }

        if matches(["/", "*"], at: index) {
            // Swift nests block comments, so this counts rather than stopping
            // at the first `*/`.
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

        if let frame = frames.last, case .interpolation(let depth) = frame {
            if characters[index] == "(" {
                frames[frames.count - 1] = .interpolation(depth: depth + 1)
            } else if characters[index] == ")" {
                if depth == 0 {
                    kept.append(")")
                    frames.removeLast()
                    index += 1
                    continue
                }
                frames[frames.count - 1] = .interpolation(depth: depth - 1)
            }
        }

        kept.append(characters[index])
        index += 1
    }

    return String(kept)
}

// MARK: - The rule

/// The arguments of one call, split where a comma sits outside every bracket.
private func topLevelArguments(_ arguments: String) -> [String] {
    var pieces: [String] = []
    var current = ""
    var depth = 0

    for character in arguments {
        if character == "(" || character == "[" || character == "{" { depth += 1 }
        if character == ")" || character == "]" || character == "}" { depth -= 1 }
        if character == "," && depth == 0 {
            pieces.append(current)
            current = ""
            continue
        }
        current.append(character)
    }

    if !pieces.isEmpty || !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        pieces.append(current)
    }
    return pieces
}

/// The index just past an argument LABEL, or `nil` when `text` opens with none.
///
/// A label is not a value, so `terminator: ""` has to read as constant. The
/// colon must follow the identifier directly, which is what keeps a ternary
/// (`a ? b : c`) from being read as one.
private func labelEnd(of text: String) -> String.Index? {
    var index = text.startIndex
    guard index < text.endIndex, text[index].isLetter || text[index] == "_" else { return nil }
    while index < text.endIndex, isIdentifierCharacter(text[index]) {
        index = text.index(after: index)
    }
    while index < text.endIndex, text[index] == " " || text[index] == "\t" {
        index = text.index(after: index)
    }
    guard index < text.endIndex, text[index] == ":" else { return nil }
    return text.index(after: index)
}

/// Whether `text` is a leading-dot member reference, such as `.error`.
///
/// A leading dot resolves to a CASE or a static member of the inferred type, so
/// it names a level and never a payload: `logger.log(level: .error, "…")` is the
/// documented way to log a constant message, and reporting it would report
/// correct code. `.error(payload)` is not one of these — it carries
/// parentheses, so it still reads as a value.
private func isLeadingDotMemberReference(_ text: String) -> Bool {
    guard text.hasPrefix(".") else { return false }
    let name = text.dropFirst()
    return !name.isEmpty && name.allSatisfy(isIdentifierCharacter)
}

/// Whether every argument is a string literal or a level, with or without a
/// label.
///
/// Reads BLANKED code, so a literal is exactly `""` by then and anything else
/// left standing names a value.
private func argumentsAreConstantText(_ arguments: String) -> Bool {
    for piece in topLevelArguments(arguments) {
        var text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = labelEnd(of: text) { text = String(text[end...]) }
        text = text.replacingOccurrences(of: "\"\"", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || isLeadingDotMemberReference(text) { continue }
        return false
    }
    return true
}

/// Every logging call in `code` that carries anything but constant text.
///
/// `code` must have been through `swiftCodeWithStaticTextBlanked` already, so a
/// route named in a comment or inside a literal reaches this nowhere.
///
/// A route this cannot READ is reported too, never skipped. `let write = NSLog`
/// hands the sink to another name, and a guard that shrugged at what it could
/// not parse would pass exactly the cases worth stopping.
private func loggingCallsCarryingAValue(in code: String) -> [String] {
    let characters = Array(code)
    var findings: [String] = []
    var index = 0

    func matches(_ text: [Character], at start: Int) -> Bool {
        guard start >= 0, start + text.count <= characters.count else { return false }
        for (offset, character) in text.enumerated() where characters[start + offset] != character {
            return false
        }
        return true
    }

    /// The longest route naming a whole word at `index`.
    ///
    /// LONGEST, so `NSLogv` is not read as `NSLog` followed by a stray `v` and
    /// then missed altogether. A leading `.` is allowed, which is what catches
    /// `Swift.print`; a leading letter is not, which is what keeps `printer`
    /// from reading as `print`.
    func route(at index: Int) -> String? {
        loggingRoutes
            .filter { name in
                guard matches(Array(name), at: index) else { return false }
                if index > 0 && isIdentifierCharacter(characters[index - 1]) { return false }
                let after = index + name.count
                if after < characters.count && isIdentifierCharacter(characters[after]) {
                    return false
                }
                return true
            }
            .max { $0.count < $1.count }
    }

    /// Whether a RECEIVER ends at the `.` sitting at `dot`.
    ///
    /// The whole discriminator for `messageMethodRoutes`. `log.error(` is a call
    /// on an instance and the dot follows the instance; `type: .error` and
    /// `case .error:` are leading-dot member references, where the dot follows a
    /// colon, a comma or a keyword and no receiver exists. A receiver ends in an
    /// identifier character, or in the `)`, `]` or `}` that closes a call, a
    /// subscript or a closure.
    ///
    /// A `?` or a `!` may sit between the receiver and the dot, and it is read
    /// IMMEDIATELY, before any whitespace. `log?.error(…)` reaches exactly the
    /// same sink as `log.error(…)`, and an optional `Logger` is ordinary Swift:
    /// one character walked past this whole rule until this line existed.
    ///
    /// Whitespace before the dot is stepped over only back to a bracket, or to
    /// a `?` or `!` that itself follows a receiver. The bracket reads
    /// `Logger(…)\n    .error(`; the `?` reads `log?\n    .error(`. Both are
    /// chained calls, which is the one thing that can be meant there. It is NOT
    /// stepped over back to an identifier: `case .error:` reaches `case` that
    /// way, and reporting a switch is how a guard gets deleted.
    ///
    /// A `?` reached ACROSS whitespace needs the extra test, where one touching
    /// the dot does not. `isBad ? .error : .info` puts a space on both sides of
    /// the `?`, so demanding a receiver immediately before it refuses the
    /// ternary and keeps the chain.
    func receiverEnds(before dot: Int) -> Bool {
        guard dot > 0 else { return false }
        var end = dot
        if characters[end - 1] == "?" || characters[end - 1] == "!" {
            end -= 1
            guard end > 0 else { return false }
        }
        if isIdentifierCharacter(characters[end - 1]) { return true }
        var back = end - 1
        while back >= 0,
              characters[back] == " " || characters[back] == "\t" || characters[back] == "\n" {
            back -= 1
        }
        guard back >= 0 else { return false }
        if characters[back] == ")" || characters[back] == "]" || characters[back] == "}" {
            return true
        }
        // `log?\n    .error(` — the same optional chain, broken across a line.
        // Reading `?` only where it touches the dot walked past this spelling.
        // The `?` counts only when a receiver ends IMMEDIATELY before it: a
        // ternary writes a space there (`isBad ? .error : .info`), so this
        // refuses the ternary while accepting the chain.
        if characters[back] == "?" || characters[back] == "!" {
            guard back > 0 else { return false }
            let prior = characters[back - 1]
            return isIdentifierCharacter(prior)
                || prior == ")" || prior == "]" || prior == "}"
        }
        return false
    }

    /// The longest message method called on a receiver at `index`.
    ///
    /// The trailing check is what keeps `state.logging` from reading as `log`,
    /// and the receiver check is what keeps the `error` parameter of an
    /// `NWConnection` completion handler from reading as anything at all.
    func memberRoute(at index: Int) -> String? {
        guard index > 0, characters[index - 1] == ".", receiverEnds(before: index - 1) else {
            return nil
        }
        return messageMethodRoutes
            .filter { name in
                guard matches(Array(name), at: index) else { return false }
                let after = index + name.count
                return after >= characters.count || !isIdentifierCharacter(characters[after])
            }
            .max { $0.count < $1.count }
    }

    while index < characters.count {
        // `label` is how a finding names what it found: a message method is
        // reported as `.error(…)`, which is how it reads in the source.
        let found: (name: String, label: String, isMember: Bool)? =
            route(at: index).map { ($0, $0, false) }
            ?? memberRoute(at: index).map { ($0, ".\($0)", true) }
        guard let (name, label, isMember) = found else {
            index += 1
            continue
        }

        // Step over a member chain — `FileHandle.standardError.write(` — to the
        // call's own parenthesis. A newline is NOT stepped over: a `(` on the
        // next line belongs to another statement.
        var cursor = index + name.count
        while cursor < characters.count,
              isIdentifierCharacter(characters[cursor]) || characters[cursor] == "."
                || characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "(" else {
            // A whole-word route with no call is still reported: `let write =
            // NSLog` hands the sink to another name, and `NSLog` can be nothing
            // else.
            //
            // A MEMBER is not. `self.error = err`, `task.error`,
            // `results[0].error` and `Level.error` are ordinary Swift, and this
            // rule reads the method name only — it cannot know the receiver's
            // type, so it cannot tell a `Logger` from an error property. Eight
            // such reads were MEASURED as findings before this branch existed.
            // A guard that reports ordinary Swift is deleted by the next
            // maintainer, and then it guards nothing at all.
            if !isMember {
                findings.append("\(label) — named, and this guard reads no arguments for it")
            }
            index += name.count
            continue
        }

        var depth = 0
        var end = cursor
        var closed = false
        while end < characters.count {
            if characters[end] == "(" { depth += 1 }
            if characters[end] == ")" {
                depth -= 1
                if depth == 0 { closed = true; break }
            }
            end += 1
        }
        guard closed else {
            findings.append("\(label)( — unbalanced parentheses; this guard reads no arguments")
            index = cursor + 1
            continue
        }

        let arguments = String(characters[(cursor + 1) ..< end])
        if !argumentsAreConstantText(arguments) {
            findings.append("\(label)(\(arguments))")
        }
        index = end + 1
    }

    return findings
}

// MARK: - The scanned set

private func ingestPathSources() throws -> [URL] {
    let directory = packageRoot.appending(path: "Sources/CoffeeBarIngest")
    guard let walk = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }

    var found: [URL] = []
    for case let entry as URL in walk where entry.pathExtension == "swift" {
        found.append(entry)
    }
    return found.sorted { $0.path < $1.path }
}

private func ingestPathEntriesFound() throws -> [String] {
    let prefix = packageRoot.path + "/"
    return try ingestPathSources().map { file in
        file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
    }
}

@Test func theScanReadsExactlyTheIngestPathsFiles() throws {
    // Without this, a walk that reached nothing reports zero leaks and looks
    // like success — the failure `PrivacyBoundary_test` guards against in two
    // places, for the same reason.
    let found = try ingestPathEntriesFound()

    #expect(found.isEmpty == false,
            "the raw-payload scan reached no file at \(packageRoot.path)")

    #expect(found == ingestPathEntries, """
        the ingest path's file set changed.
          unexpected: \(found.filter { !ingestPathEntries.contains($0) })
          missing:    \(ingestPathEntries.filter { !found.contains($0) })
        Every check in this file reads only these files. Update \
        `ingestPathEntries` deliberately, after reading the new file against \
        design §7.
        """)
}

@Test func theScanReadsRealSourceAndRealComments() throws {
    // The positive control, and it runs against the REAL files rather than a
    // fixture: proof that the reader read something, and proof that the
    // stripper stripped it.
    //
    // `SPDX-License-Identifier` is the needle because every file in this
    // repository opens with it, in a COMMENT, and the licence header is not
    // something a change deletes by accident. If it survives the stripper, the
    // stripper is doing nothing and every check below is vacuous.
    let files = try ingestPathSources()
    #expect(files.count == ingestPathEntries.count,
            "the raw-payload scan reached \(files.count) files at \(packageRoot.path)")

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains("SPDX-License-Identifier"), """
            \(file.lastPathComponent) carries no licence header, so this control \
            proves nothing about what the scan reads.
            """)
        #expect(!swiftCodeWithStaticTextBlanked(source).contains("SPDX-License-Identifier"), """
            the comment stripper left \(file.lastPathComponent)'s licence header \
            standing, so it is stripping nothing and every check in this file is \
            vacuous.
            """)
    }
}

// MARK: - The rule, against the real ingest path

@Test func noLoggingCallInTheIngestPathCarriesAValue() throws {
    // Finding I5. Named bug this catches, MEASURED on this branch: one
    // `NSLog("coffee-bar ingest: %@", String(data: body, encoding: .utf8) ?? "")`
    // in `UnixSocketIngestListener.receive`, immediately before the decode,
    // writes every Stop payload verbatim to the unified log — and all 383
    // checks stayed green, `PrivacyBoundary_test` among them, because the line
    // names no forbidden field and the bytes never become a typed property.
    let files = try ingestPathSources()

    // Anchored on the file the finding is about. A scan that reached the wrong
    // directory, or nothing at all, satisfies every check below.
    #expect(files.contains { $0.lastPathComponent == "IngestListener.swift" }, """
        the raw-payload scan never reached IngestListener.swift; it read \
        \(files.count) files under \(packageRoot.path)
        """)

    var leaks: [String] = []
    for file in files {
        let code = swiftCodeWithStaticTextBlanked(try String(contentsOf: file, encoding: .utf8))
        leaks += loggingCallsCarryingAValue(in: code)
            .map { "\(file.lastPathComponent): \($0)" }
    }

    #expect(leaks.isEmpty, """
        the ingest path logs a VALUE: \(leaks)
        Before the decode the payload is untyped bytes, so a value logged here \
        is the raw POST — `last_assistant_message` among it — written to the \
        unified log, where Console.app reads it and where it outlives the app. \
        Design §7 forbids reading conversation content at all. This layer \
        reports through `isReady` and the panel: log a fixed message with no \
        value in it, or report the condition as state.
        """)
}

// MARK: - The instrument itself

@Test func theScanTellsCodeFromCommentsAndKeepsWhatInterpolationCarries() {
    // Every check above is only as good as this function. Both directions are
    // pinned: strip too little and a doc comment naming `NSLog` fails a correct
    // tree, strip too much and `print("\(body)")` passes.
    //
    // Each case is a literal in and a literal out — never the function's own
    // logic re-run as the expectation.
    let cases: [(name: String, source: String, expected: String)] = [
        ("a line comment naming a route goes, the code around it stays",
         "let a = 1 // NSLog(body)\nlet b = 2",
         "let a = 1 \nlet b = 2"),

        // What `IngestListener.swift:41` says today.
        ("a doc comment naming a route goes",
         "/// main.swift writes that to NSLog, where no user looks\nlet a = 1",
         "\nlet a = 1"),

        ("a block comment goes and keeps its line breaks",
         "let a = 1\n/* NSLog\n   print */\nlet b = 2",
         "let a = 1\n\n\nlet b = 2"),

        ("nested block comments close at the outer end, not the inner one",
         "let a = 1 /* outer /* print */ still comment */ let b = 2",
         "let a = 1  let b = 2"),

        ("a literal's static text is blanked",
         "NSLog(\"coffee-bar ingest: %@\")",
         "NSLog(\"\")"),

        // The leak a whole-literal stripper would pass.
        ("an interpolation survives as code",
         "NSLog(\"ingest: \\(body)\")",
         "NSLog(\"\"(body))"),

        ("an interpolation carrying a call keeps its own parentheses balanced",
         "print(\"\\(String(data: body, encoding: .utf8) ?? \"none\")\")",
         "print(\"\"(String(data: body, encoding: .utf8) ?? \"\"))"),

        ("`//` inside a literal opens no comment",
         "let url = \"https://example.com/print\"\nlet a = 1",
         "let url = \"\"\nlet a = 1"),

        ("`/*` inside a literal opens no comment",
         "let glob = \"/*\"\nlet a = 1",
         "let glob = \"\"\nlet a = 1"),

        ("an escaped quote does not end the literal early",
         "let a = \"he said \\\"NSLog\\\" loudly\" // gone\nlet b = 2",
         "let a = \"\" \nlet b = 2"),

        ("a raw literal is blanked and its delimiters go with it",
         "let a = #\"x \\#(body) y\"# // gone",
         "let a = \"\"(body) "),

        // `\(` is plain text in a raw literal; only `\#(` interpolates.
        ("a raw literal's `\\(` is text rather than an interpolation",
         "let a = #\"x \\(body) y\"#",
         "let a = \"\""),

        ("a multi-line literal keeps only what it interpolates",
         "let a = \"\"\"\n// not a comment\n\\(body)\n\"\"\"\nlet b = 2",
         "let a = \"\"(body)\nlet b = 2"),

        ("a `#` that opens no literal is kept",
         "let p = #filePath // gone",
         "let p = #filePath "),

        ("division is not a comment",
         "let half = total / 2 / 1",
         "let half = total / 2 / 1"),
    ]

    for testCase in cases {
        #expect(swiftCodeWithStaticTextBlanked(testCase.source) == testCase.expected,
                "\(testCase.name): got \(swiftCodeWithStaticTextBlanked(testCase.source).debugDescription)")
    }
}

@Test func theRuleTellsAConstantMessageFromOneCarryingAValue() {
    // The other half of the instrument. It reads BLANKED code, which is what
    // the check above produces, so every `""` here stands for a literal.
    //
    // Literal in, literal out again: the expectation is a COUNT written by
    // hand, never the function's own answer.
    let cases: [(name: String, code: String, findings: Int)] = [
        ("a constant message is allowed",
         "NSLog(\"\")", 0),

        ("a constant message with a label is allowed",
         "print(\"\", terminator: \"\")", 0),

        ("a call with no arguments is allowed",
         "print()", 0),

        ("a value argument is refused",
         "NSLog(\"\", body)", 1),

        // What `NSLog("ingest: \(body)")` blanks to.
        ("an interpolated value is refused",
         "NSLog(\"\"(body))", 1),

        // The planted leak line, blanked.
        ("the leak this file exists for is refused",
         "NSLog(\"\", String(data: body, encoding: .utf8) ?? \"\")", 1),

        ("a route handed to another name is refused",
         "let write = NSLog\nlet a = 1", 1),

        ("parentheses this guard cannot balance are refused",
         "NSLog(\"\", body", 1),

        ("a longer route is not read as the shorter one it starts with",
         "NSLogv(\"\", arguments)", 1),

        ("a word that merely contains a route name is not a call",
         "let printer = makeOne()\nlet dumped = 1", 0),

        ("a qualified call is still a call",
         "Swift.print(chunk)", 1),

        ("a write to the standard error handle is refused",
         "FileHandle.standardError.write(Data(\"\".utf8))", 1),

        ("every leak is reported, not only the first",
         "NSLog(\"\", body)\nprint(chunk)", 2),

        ("a condition check is not a logging route",
         "precondition(length >= 0)\nassert(buffer.count > 0)", 0),

        // `os.Logger` is the sink that replaces `NSLog`, and its message goes
        // through an INSTANCE. The line below names neither `Logger` nor
        // `os_log`, so no whole-word route above can see it.
        ("a Logger instance method carrying a value is refused",
         "log.error(\"\"(body))", 1),

        ("a Logger instance method with a constant message is allowed",
         "log.notice(\"\")", 0),

        ("a Logger message on a call result is refused",
         "Logger(subsystem: \"\", category: \"\").fault(\"\"(body))", 1),

        ("a Logger message chained over a newline is refused",
         "Logger(subsystem: \"\")\n    .critical(\"\"(body))", 1),

        // ONE CHARACTER used to walk past the whole rule. An optional `Logger`
        // is ordinary Swift, and `log?.error(…)` reaches the same sink.
        ("a Logger reached through an optional is refused",
         "log?.error(\"\"(body))", 1),

        ("a Logger reached through a force unwrap is refused",
         "log!.error(\"\"(body))", 1),

        // The same sink again, with the chain broken across a line. A formatter
        // handling a long chain writes this, and reading `?` only when it
        // touches the dot walked past it.
        ("an optional chain broken across a line is refused",
         "log?\n    .error(\"\"(body))", 1),

        // A member READ is not a call, and this rule cannot know the receiver's
        // type. Reporting these would report ordinary Swift, which is how a
        // guard gets deleted. The cost is stated in the LIMITS: the alias
        // `let write = log.error` escapes.
        ("a member read that is not a call is not a route",
         "let write = log.error\nlet a = 1", 0),

        ("ordinary member reads are not logging calls",
         "self.error = err\nlet a = task.error\nlet b = response.info\n"
         + "let c = settings.debug\nlet d = Level.error\nlet e = decode(data).error\n"
         + "let f = self.notice\nlet g = results[0].error", 0),

        // MEASURED with `swiftc -typecheck`: both spellings compile, so the
        // space is not what makes a ternary safe. Not being a call is.
        ("a ternary choosing a level is not a call, spaced or not",
         "let a: Level = isBad ? .error : .info\nlet b: Level = isBad ?.error : .info", 0),

        ("a level argument names a level, not a value",
         "logger.log(level: .error, \"\")", 0),

        // `os_signpost` is `os_log`'s sibling and carries the same interpolated
        // message to the same unified log.
        ("a signpost carrying a value is refused",
         "os_signpost(.event, log: .default, name: \"\", \"\", text)", 1),

        ("a signpost with a constant message is allowed",
         "os_signpost(.event, log: .default, name: \"\", \"\")", 0),

        ("every signposter method that takes a message is read",
         "signposter.emitEvent(\"\", \"\"(body))\nsignposter.beginInterval(\"\", \"\"(body))\n"
         + "signposter.endInterval(\"\", state, \"\"(body))", 3),

        ("a signposter built from a value is refused",
         "OSSignposter(logger: makeLogger(name))", 1),

        // The discriminator. These three lines are `IngestListener.receive`
        // verbatim: `error` is what `NWConnection` calls its completion
        // parameter, and reading it as a bare word reports code that logs
        // nothing. A receiver before the dot is what tells the two apart.
        ("a completion handler's `error` parameter is not a logging route",
         "data, _, isComplete, error in\nif !isComplete && error == nil { return }\nif isComplete || error != nil { return }",
         0),

        ("a leading-dot enum case sharing a method name is not a call",
         "switch outcome {\ncase .fault: break\n}\nsend(type: .error, body)", 0),

        ("a name that merely starts with a method name is not one",
         "state.logging = true\nlet a = state.information", 0),
    ]

    for testCase in cases {
        let found = loggingCallsCarryingAValue(in: testCase.code)
        #expect(found.count == testCase.findings,
                "\(testCase.name): got \(found)")
    }
}
