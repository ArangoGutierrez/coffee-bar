// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// `HookHealth.requiredEvents(for:)` existed as DATA and no production code read
// it. `status(ofSettings:)` filtered the Claude-Code CONSTANT whatever tool the
// user runs, so the panel handed a Claude Code advisory to a Codex user and to a
// Cursor user. These checks drive the per-tool entry point instead.
//
// Every expectation is a LITERAL. The fixture is only the INPUT, exactly as
// `HookHealth_test.swift` requires.
//
// **The two hook files were MEASURED, not researched**, against `codex-cli
// 0.146.0` and `cursor-agent 2026.07.23-e383d2b`. `captured.json` in each
// fixture directory is that machine's real file. Both already write `~` rather
// than an absolute home path, so redaction removed nothing — which is why the
// captured bytes may sit in a public repository unchanged.

private func fixture(_ directory: String, _ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/\(directory)/\(name)"))
}

private func codex(_ name: String) throws -> Data { try fixture("codex-settings", name) }
private func cursor(_ name: String) throws -> Data { try fixture("cursor-settings", name) }
private func claude(_ name: String) throws -> Data { try fixture("claude-settings", name) }

/// Each tool's fixture directory and the files it must hold.
///
/// A literal, for the reason `theSettingsFixturesAreOnDiskWhereTheseChecksLookForThem`
/// keeps one: a missing fixture makes every `fixture(...)` call THROW, and a
/// thrown error is a different failure from a wrong verdict. Naming the files
/// stops a rename quietly shrinking the set the checks below exercise.
private let settingsFixtures: [(tool: AgentTool, directory: String, files: [String])] = [
    (.codex, "codex-settings",
     ["captured.json", "malformed.json", "missing-stop.json", "missing-two.json",
      "no-hooks.json", "wired.json"]),
    (.cursor, "cursor-settings",
     ["captured.json", "malformed.json", "missing-session-start.json",
      "missing-two.json", "no-hooks.json", "wired.json"]),
]

@Test(arguments: settingsFixtures)
func theSettingsFixturesForEachToolAreOnDisk(
    _ entry: (tool: AgentTool, directory: String, files: [String])
) throws {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(entry.directory)")

    let found = try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()

    #expect(found == entry.files,
            "the \(entry.tool.rawValue) settings fixtures at \(directory.path) changed")
}

// MARK: - Codex: the nested shape, its OWN event list

@Test func aFullyWiredCodexFileReportsWired() throws {
    // Named bug this catches: reading Codex with Claude Code's required list.
    // This file wires Codex's five and NOT `PermissionDenied`, which no Codex
    // payload has ever carried, so a check that filtered the Claude Code
    // constant reports a fault the user could never clear.
    #expect(try HookHealth.status(of: codex("wired.json"), for: .codex) == .wired)
}

@Test func aCodexFileWithNoHooksAsksForCodexEventsAndNotClaudeCodes() throws {
    // The discriminating half of the check above. `PermissionDenied` is absent
    // and `UserPromptSubmit` is present: that pair is exactly the difference
    // between the two lists, so a reader wired to the wrong constant fails here
    // rather than passing by coincidence.
    #expect(try HookHealth.status(of: codex("no-hooks.json"), for: .codex)
            == .missing(["PostToolUse", "PreToolUse", "SessionStart", "Stop",
                         "UserPromptSubmit"]))
}

@Test func aMissingCodexEntryIsNamed() throws {
    // `Stop` carries another tool's command. The user has to know WHICH entry to
    // paste back, so "ingest is broken" is not an answer.
    #expect(try HookHealth.status(of: codex("missing-stop.json"), for: .codex)
            == .missing(["Stop"]))
}

@Test func twoMissingCodexEntriesAreNamedInASortedOrder() throws {
    // `UserPromptSubmit` is absent outright and `Stop` points elsewhere. The
    // panel joins this list, so the order is pinned as a literal.
    #expect(try HookHealth.status(of: codex("missing-two.json"), for: .codex)
            == .missing(["Stop", "UserPromptSubmit"]))
}

@Test func aMalformedCodexFileIsReportedNotCrashed() throws {
    #expect(try HookHealth.status(of: codex("malformed.json"), for: .codex) == .unreadable)
}

@Test func theCapturedCodexFileReportsEveryRequiredEventMissing() throws {
    // The REAL `~/.codex/hooks.json` from the machine this was written on.
    //
    // Named bug this catches: matching on the EVENT KEY. `PreToolUse` is present
    // in this file, so a key match would report four missing instead of five —
    // and would tell a user four entries were absent while the one it credited
    // runs somebody else's script.
    #expect(try HookHealth.status(of: codex("captured.json"), for: .codex)
            == .missing(["PostToolUse", "PreToolUse", "SessionStart", "Stop",
                         "UserPromptSubmit"]))
}

// MARK: - Cursor: the FLAT shape

@Test func aFullyWiredCursorFileReportsWired() throws {
    // **The defect this task exists to fix.** Cursor nests one level LESS —
    // `hooks.<event>[].command`, no `matcher`, no inner `hooks` array — so the
    // nested reader casts each entry to `[[String: Any]]`, finds no `hooks` key
    // inside, and reports every Cursor entry as not wired.
    //
    // Named bug this catches: applying Claude Code's nesting to Cursor. A
    // correctly wired Cursor user is then told to wire all five entries they
    // have already wired, which is a fault they cannot clear.
    #expect(try HookHealth.status(of: cursor("wired.json"), for: .cursor) == .wired)
}

@Test func aCursorFileWithNoHooksAsksForCursorEventsInCursorsOwnVocabulary() throws {
    // camelCase, and Cursor's own names. Named bug this catches: translating
    // Claude Code's event names into a Cursor advisory, which would send the
    // user to add keys their tool does not read.
    #expect(try HookHealth.status(of: cursor("no-hooks.json"), for: .cursor)
            == .missing(["afterFileEdit", "afterShellExecution", "beforeReadFile",
                         "beforeShellExecution", "sessionStart"]))
}

@Test func aMissingCursorEntryIsNamed() throws {
    // `sessionStart` is present and runs another tool's script.
    #expect(try HookHealth.status(of: cursor("missing-session-start.json"), for: .cursor)
            == .missing(["sessionStart"]))
}

@Test func twoMissingCursorEntriesAreNamedInASortedOrder() throws {
    // `beforeReadFile` is absent outright; `sessionStart` points elsewhere.
    #expect(try HookHealth.status(of: cursor("missing-two.json"), for: .cursor)
            == .missing(["beforeReadFile", "sessionStart"]))
}

@Test func aMalformedCursorFileIsReportedNotCrashed() throws {
    #expect(try HookHealth.status(of: cursor("malformed.json"), for: .cursor) == .unreadable)
}

@Test func theCapturedCursorFileReportsEveryRequiredEventMissing() throws {
    // The REAL `~/.cursor/hooks.json`, and the sharpest guard in this file.
    //
    // THREE of the five required event KEYS are present in it —
    // `sessionStart`, `beforeShellExecution` and `afterFileEdit` — and NONE of
    // its commands is coffee-bar's. So a reader that matched on the key answers
    // `.missing(["afterShellExecution", "beforeReadFile"])`, and the true answer
    // is all five.
    //
    // Named bug this catches: exactly that two-element answer. It would tell a
    // Cursor user three entries were healthy while no event could ever arrive.
    #expect(try HookHealth.status(of: cursor("captured.json"), for: .cursor)
            == .missing(["afterFileEdit", "afterShellExecution", "beforeReadFile",
                         "beforeShellExecution", "sessionStart"]))
}

@Test func anotherToolsFlatCursorEntryDoesNotCount() throws {
    // The flat twin of `anEntryPointingSomewhereElseDoesNotCount`, which drives
    // the nested shape only.
    //
    // The other tool's command is itself a `curl --unix-socket` POST aimed at a
    // DIFFERENT socket, for the same deliberate reason: a marker loosened to
    // "curl", or to "--unix-socket", has to fail here rather than pass.
    let raw = Data("""
        {"hooks": {"sessionStart": [{"command":\
        "curl -sS --unix-socket \\"$HOME/.other-tool/thing.sock\\" \
        -X POST --data-binary @- http://localhost/hook"}]}}
        """.utf8)

    let status = HookHealth.status(of: raw, for: .cursor)
    #expect(status != .wired)
    if case .missing(let events) = status {
        #expect(events.contains("sessionStart"))
    } else {
        Issue.record("expected .missing, got \(String(describing: status))")
    }
}

@Test func aCursorHooksValueOfTheWrongShapeIsNotAMatch() {
    // Cursor's file is hand-edited too, so any key can hold any JSON, and each
    // shape must reach a verdict rather than trap on a failed cast.
    let shapes = [
        #"{"hooks": {"sessionStart": "coffeebar-hook"}}"#,
        #"{"hooks": {"sessionStart": []}}"#,
        #"{"hooks": {"sessionStart": [{}]}}"#,
        #"{"hooks": {"sessionStart": [{"timeout": 10}]}}"#,
        #"{"hooks": {"sessionStart": [{"command": 5}]}}"#,
        #"{"hooks": []}"#,
    ]

    for shape in shapes {
        #expect(HookHealth.status(of: Data(shape.utf8), for: .cursor) != .wired,
                "\(shape) reported wired")
    }
}

// MARK: - The two shapes do not cross over

@Test func theNestedShapeIsNotAcceptedForCursor() throws {
    // Named bug this catches: giving Cursor the nested reader as well as the
    // flat one, "to be safe". Cursor never reads an inner `hooks` array, so a
    // file written that way is wired for nothing — and reporting it healthy is
    // the silent failure design §6 exists to remove.
    let nested = Data(#"""
        {"hooks": {"sessionStart": [{"hooks": [{"type": "command", \
        "command": "/usr/local/bin/coffeebar-hook --tool=cursor"}]}]}}
        """#.utf8)

    let status = HookHealth.status(of: nested, for: .cursor)
    #expect(status != .wired, "a Claude-Code-shaped entry counted as a wired Cursor hook")
    if case .missing(let events) = status {
        #expect(events.contains("sessionStart"))
    } else {
        Issue.record("expected .missing, got \(String(describing: status))")
    }
}

@Test func theFlatShapeIsNotAcceptedForCodex() throws {
    // The converse. Codex reads Claude Code's nesting — measured against
    // `~/.codex/hooks.json`, whose one entry carries `matcher` and an inner
    // `hooks` array — so a flat entry there runs nothing.
    let flat = Data(#"""
        {"hooks": {"Stop": [{"command": "/usr/local/bin/coffeebar-hook --tool=codex"}]}}
        """#.utf8)

    let status = HookHealth.status(of: flat, for: .codex)
    #expect(status != .wired, "a Cursor-shaped entry counted as a wired Codex hook")
    if case .missing(let events) = status {
        #expect(events.contains("Stop"))
    } else {
        Issue.record("expected .missing, got \(String(describing: status))")
    }
}

// MARK: - The command marker accepts the shim

@Test func theShimBinaryNameCountsAsOursAndTheSocketPathStillDoes() {
    // Issue #10d builds `coffeebar-hook`. Codex and Cursor accept COMMAND
    // handlers only, so their wiring invokes that binary and the command string
    // need not name the socket at all.
    //
    // Named bug this catches: one marker. `coffee-bar/ingest.sock` alone reports
    // a correctly wired Codex or Cursor user as broken, for ever, with nothing
    // they can do about it.
    #expect(HookHealth.commandMarkers.contains("coffee-bar/ingest.sock"),
            "the socket marker went away; a wired Claude Code user now reads as broken")
    #expect(HookHealth.commandMarkers.contains("coffeebar-hook"),
            "the shim marker is absent; a wired Codex or Cursor user reads as broken")

    // Both routes reach `.wired` through the SAME event, so the pair is what is
    // measured and not the marker list restated.
    let viaShim = Data(#"""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", \
        "command": "/usr/local/bin/coffeebar-hook --tool=claudeCode"}]}]}}
        """#.utf8)
    let viaSocket = Data(#"""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", \
        "command": "curl -sS --unix-socket \"$HOME/Library/Application Support/coffee-bar/ingest.sock\" -X POST --data-binary @- http://localhost/ingest"}]}]}}
        """#.utf8)

    for (name, raw) in [("shim", viaShim), ("socket", viaSocket)] {
        guard case .missing(let events) = HookHealth.status(ofSettings: raw) else {
            Issue.record("the \(name) command did not reach a .missing verdict")
            continue
        }
        #expect(!events.contains("Stop"),
                "the \(name) command was not recognised as coffee-bar's")
    }
}

@Test func noMarkerIsLooseEnoughToMatchAnotherToolsCommand() {
    // The guard on the guard. A marker widened to `hook`, to `coffee`, or to
    // `curl` would make every one of these count as ours, and the two guards
    // that defend this seam in `HookHealth_test.swift` name only the socket
    // case. Each string below is a real command another tool installs.
    let strangers = [
        "python3 ~/.codex/hooks/pre_tool_use.py",
        "~/.cursor/hooks/sign-commits.sh",
        "/opt/homebrew/bin/coffee --brew",
        "curl -sS --unix-socket \"$HOME/.other-tool/thing.sock\" -X POST http://localhost/hook",
        "/usr/local/bin/other-hook --tool=codex",
    ]

    for command in strangers {
        for marker in HookHealth.commandMarkers {
            #expect(!command.contains(marker),
                    "the marker \(marker) matches another tool's command: \(command)")
        }
    }
}

// MARK: - One parser for Claude Code, not two

@Test(arguments: ["wired.json", "missing-stop.json", "missing-two.json",
                  "no-hooks.json", "malformed.json"])
func theClaudeCodeVerdictIsTheSameThroughBothEntryPoints(_ name: String) throws {
    // Named bug this catches: a second Claude Code parser landing beside the
    // first. Two readers agree until they do not, and the disagreement is
    // invisible — the panel would show one verdict while every existing check
    // drove the other.
    let bytes = try claude(name)
    #expect(HookHealth.status(of: bytes, for: .claudeCode)
            == HookHealth.status(ofSettings: bytes),
            "\(name) reaches two different verdicts through the two entry points")
}

@Test func aToolWithAnAdvisoryAlwaysReachesAVerdict() {
    // `nil` from `status(of:for:)` means "this tool has no advisory", which is
    // NOT `.wired` and NOT an empty list. Every tool has an advisory today, so
    // nothing may return `nil` — and `status(ofSettings:)` rests on that for
    // Claude Code.
    //
    // Named bug this catches: folding the two claims together. An empty required
    // list satisfies every filter and reports `.wired` for a check that never
    // ran, which is the strongest form of a false healthy verdict.
    for tool in AgentTool.allCases {
        #expect(HookHealth.requiredEvents(for: tool) != nil,
                "\(tool.rawValue) lost its advisory")
        #expect(HookHealth.status(of: Data("{}".utf8), for: tool) != nil,
                "\(tool.rawValue) has an advisory but reaches no verdict")
    }
}

@Test func anAbsentOrEmptyFileIsUnreadableForEveryTool() {
    // A zero-byte file is what a truncating writer leaves behind. It carries no
    // evidence that the entries are gone, so it must never be reported as
    // missing entries — for any tool, not only for Claude Code.
    for tool in AgentTool.allCases {
        #expect(HookHealth.status(of: nil, for: tool) == .unreadable,
                "\(tool.rawValue) did not report an absent file as unreadable")
        #expect(HookHealth.status(of: Data(), for: tool) == .unreadable,
                "\(tool.rawValue) did not report an empty file as unreadable")
        #expect(HookHealth.status(of: Data(#"[1, 2, 3]"#.utf8), for: tool) == .unreadable,
                "\(tool.rawValue) did not report a top-level array as unreadable")
    }
}

// MARK: - Where each tool keeps the file

@Test func everyToolNamesItsOwnHookFileAndNoTwoShareOne() {
    // Named bug this catches: a second hardcoded path. `HookHealthReader` held
    // `.claude/settings.json` as the only location, so a Codex user's advisory
    // was measured against a file their tool never reads.
    //
    // The three paths are literals here, taken from the measured files. Deriving
    // them from the function under test would restate it rather than check it.
    #expect(HookHealth.settingsPath(for: .claudeCode) == ".claude/settings.json")
    #expect(HookHealth.settingsPath(for: .codex) == ".codex/hooks.json")
    #expect(HookHealth.settingsPath(for: .cursor) == ".cursor/hooks.json")

    // `~/.codex/config.toml` was the SHIPPED claim and it is FALSE for
    // codex-cli 0.146.0: that file carries `[features] hooks = true` and
    // `[hooks.state]` trust hashes, and every trust-hash key points AT
    // `~/.codex/hooks.json`. No TOML is parsed anywhere in this package.
    for tool in AgentTool.allCases {
        let path = HookHealth.settingsPath(for: tool)
        #expect(path.hasSuffix(".json"),
                "\(tool.rawValue) reads \(path), which this package cannot parse")
    }

    let paths = AgentTool.allCases.map { HookHealth.settingsPath(for: $0) }
    #expect(Set(paths).count == AgentTool.allCases.count,
            "two tools share one hook file: \(paths)")
}
