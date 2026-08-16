// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// The acceptance script, checked as far as a suite can check it.
///
/// `scripts/preferences-activation-acceptance.sh` drives the RUNNING app through
/// the accessibility API, so CI cannot execute it: it needs Accessibility
/// permission, a built bundle and a live window server. That is exactly why the
/// parts of it a static check CAN reach are worth reaching. A defect on a path
/// nobody runs in CI is found by a human, at the moment they are trying to
/// measure something else, on a machine whose state the script has already
/// changed.
///
/// **What this file does NOT do.** It never runs the script. Nothing here proves
/// the script measures the right thing, that its AppleScript is valid, or that
/// its refusals fire — only that a shell can parse it and that every helper it
/// calls is one it has.

/// The package root, resolved from `#filePath`.
///
/// A third resolver in this target. `AppLayerBoundary_test.swift` and
/// `LidClosedPanel_test.swift` each declare their own as `private`, which Swift
/// scopes to the file, and four lines is cheaper than widening either.
private func acceptancePackageRoot() -> URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/AcceptanceScript_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private let acceptanceScript = acceptancePackageRoot()
    .appending(path: "scripts/preferences-activation-acceptance.sh")

@Test func everyHelperTheAcceptanceScriptCallsIsOneItDefines() throws {
    // Named bug this catches, and it shipped: the `nobuttons)` branch called
    // `close_panel`, which is defined nowhere in the file. The script runs under
    // `set -uo pipefail` with NO `-e`, so bash prints
    //
    //     preferences-activation-acceptance.sh: line 233: close_panel: command not found
    //
    // and CARRIES ON to the next line. The refusal then exits 2 with the panel
    // still open, which is the one state every other refusal path is careful to
    // avoid — the next run reads that leftover as a stale window and refuses
    // too, so one typo costs two runs and a manual cleanup.
    //
    // WHY NOTHING ELSE SEES IT: an undefined function is not a syntax error, so
    // `bash -n` is silent, and the branch only runs on a machine where the panel
    // opens with no buttons in the accessibility tree. There is no shell in this
    // package's test path at all, so this is the whole net.
    //
    // SNAKE_CASE is the discriminator, and it is a property of this script
    // rather than a convention borrowed from elsewhere: every helper it defines
    // has an underscore, and every external command it calls — osascript, pgrep,
    // grep, head, cut, printf, sleep, echo — is a single word. So a lowercase
    // token with an underscore in it is a call to this file's own code, and it
    // has to resolve here.
    let script = try String(contentsOf: acceptanceScript, encoding: .utf8)

    let defined = try Set(matches(of: "^([a-z_][a-z0-9_]*)\\(\\)", in: script,
                                  options: [.anchorsMatchLines]))
    // ANTI-VACUITY. A rotted pattern finds no definitions, at which point every
    // call below is "undefined" and the failure reads as a script problem rather
    // than a guard problem — or, with the sense reversed, everything passes.
    #expect(defined.count >= 4, """
        this guard parsed \(defined.count) function definition(s) from \
        \(acceptanceScript.lastPathComponent): \(defined.sorted()). It defines \
        fail, refuse, open_window_count and reset_windows at least, so a smaller \
        number means the pattern no longer reads the file.
        """)

    let called = Set(try matches(of: "([a-z][a-z0-9]*(?:_[a-z0-9]+)+)", in: script))
    let undefined = called.subtracting(defined).sorted()

    #expect(undefined.isEmpty, """
        \(acceptanceScript.lastPathComponent) calls \(undefined), which it does \
        not define. Under `set -uo pipefail` with no `-e`, bash reports "command \
        not found" and RUNS ON, so the branch continues with its cleanup skipped \
        — the panel is left open and the next run refuses on a stale window.
        Define it, or call the helper that already does the job. If one of these \
        is genuinely an external command with an underscore in its name \
        (system_profiler, sw_vers), name it in this guard so the exception is \
        visible.
        """)
}

@Test func aShellCanParseTheAcceptanceScript() throws {
    // `bash -n` reads the file and builds it without running a line of it. This
    // is not a formality on THIS script: it embeds four AppleScript heredocs,
    // unquoted and inside `$( )`, so bash reads their contents too. Its own
    // comments record what that has cost — a lone apostrophe in a heredoc
    // comment is reported as "unexpected EOF while looking for matching quote"
    // against the END of the file, nowhere near the cause, and a backtick in one
    // ran what it enclosed on every pass.
    //
    // NOTHING IS EXECUTED, and that is what makes this safe to run in a suite:
    // the script clicks a real menu bar and can quit the app under test.
    let bash = Process()
    bash.executableURL = URL(fileURLWithPath: "/bin/bash")
    bash.arguments = ["-n", acceptanceScript.path]
    let err = Pipe()
    bash.standardError = err
    bash.standardOutput = Pipe()
    try bash.run()
    let complaint = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                           as: UTF8.self)
    bash.waitUntilExit()

    #expect(bash.terminationStatus == 0, """
        bash cannot parse \(acceptanceScript.lastPathComponent) (exit \
        \(bash.terminationStatus)):
        \(complaint.trimmingCharacters(in: .whitespacesAndNewlines))
        """)
}

@Test func noAppleScriptHeredocCarriesABacktickOrAnApostrophe() throws {
    // The script states this rule in its own prose and had no check for it, so
    // it was broken again the next time somebody wrote a comment in one of
    // those heredocs — this task, adding a third button to the panel.
    //
    // WHY IT MATTERS. The four AppleScript heredocs are UNQUOTED and sit inside
    // `$( )`, so bash reads their contents on the way past:
    //
    //   - a BACKTICK runs what it encloses. Observed here: an explanatory
    //     comment mentioning three AppleScript terms in backticks produced
    //     `line 290: rows: command not found` three times per probe, on a run
    //     that otherwise PASSED. The probe still answered, so nothing failed and
    //     the noise was the only trace.
    //   - an APOSTROPHE opens a quote bash never sees closed, and the complaint
    //     is `unexpected EOF while looking for matching quote` reported against
    //     the END of the file, nowhere near the cause.
    //
    // WHY `bash -n` CANNOT SEE IT, which is the whole reason this is separate
    // from `aShellCanParseTheAcceptanceScript`: a backtick inside a heredoc is
    // perfectly good syntax. It parses, it runs, and it runs the wrong thing.
    // Only the apostrophe half is a parse error, and only sometimes.
    let script = try String(contentsOf: acceptanceScript, encoding: .utf8)
    let lines = script.components(separatedBy: "\n")

    // The heredoc bodies, delimiter to delimiter. `<<OSA` opens one and a line
    // that is exactly `OSA` closes it.
    var inside = false
    var offenders: [String] = []
    var bodyLines = 0

    for (index, line) in lines.enumerated() {
        if !inside {
            if line.contains("<<OSA") { inside = true }
            continue
        }
        if line.trimmingCharacters(in: .whitespaces) == "OSA" {
            inside = false
            continue
        }
        bodyLines += 1
        if line.contains("`") || line.contains("'") {
            offenders.append("line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    // ANTI-VACUITY, and not a formality: a delimiter renamed from OSA leaves
    // this walking no heredoc at all, at which point the assertion below is
    // green over a file it never read. The four heredocs run to well over a
    // hundred lines between them.
    #expect(bodyLines > 60, """
        this guard found \(bodyLines) line(s) of AppleScript heredoc in \
        \(acceptanceScript.lastPathComponent). It looks for bodies between \
        <<OSA and a closing OSA; a renamed delimiter leaves it reading nothing \
        and passing everything.
        """)

    #expect(!inside, """
        \(acceptanceScript.lastPathComponent) opens an AppleScript heredoc that \
        is never closed by a bare OSA line, so this guard cannot tell where the \
        AppleScript ends and the shell begins.
        """)

    #expect(offenders.isEmpty, """
        \(acceptanceScript.lastPathComponent) carries a backtick or an \
        apostrophe inside an AppleScript heredoc:
          \(offenders.joined(separator: "\n  "))
        The heredocs are unquoted and inside $( ), so bash reads them: a \
        backtick RUNS what it encloses — measured as "rows: command not found" \
        on an otherwise passing run — and an apostrophe opens a quote reported \
        as unexpected EOF against the end of the file. Write the term without \
        quoting it.
        """)
}

/// Capture group 1 of every match of `pattern` in `text`.
private func matches(of pattern: String, in text: String,
                     options: NSRegularExpression.Options = []) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern, options: options)
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
}
