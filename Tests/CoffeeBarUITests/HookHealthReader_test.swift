// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarUI

// Design §6: coffee-bar PRINTS the hook snippet and NEVER writes
// `~/.claude/settings.json`. It READS that file so a clobbered snippet becomes
// visible failure instead of silent failure.
//
// Two of the checks below exist only to hold the "never writes" half of that
// sentence, from two directions: one runs the reader and proves the bytes on
// disk did not move, the other reads the sources and proves no write call is
// written anywhere near the path.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarUITests/HookHealthReader_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarUITests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private var fixtures: URL {
    packageRoot.appending(path: "Tests/Fixtures/claude-settings")
}

/// A scratch copy of a fixture, so a check that writes would be caught here
/// rather than by corrupting a committed file.
private func scratchCopy(of fixture: String) throws -> URL {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-health-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let destination = scratch.appending(path: fixture)
    try Data(contentsOf: fixtures.appending(path: fixture)).write(to: destination)
    return destination
}

// MARK: - The four states, read from a real file

@Test func theReaderReportsWiredForARealFileOnDisk() {
    let reader = HookHealthReader(settingsURL: fixtures.appending(path: "wired.json"))
    #expect(reader.status() == .wired)
}

@Test func theReaderNamesTheMissingEventForARealFileOnDisk() {
    let reader = HookHealthReader(settingsURL: fixtures.appending(path: "missing-stop.json"))
    #expect(reader.status() == .missing(["Stop"]))
}

@Test func theReaderDoesNotCrashOnAMalformedFile() {
    let reader = HookHealthReader(settingsURL: fixtures.appending(path: "malformed.json"))
    #expect(reader.status() == .unreadable)
}

@Test func theReaderDoesNotCrashOnAnAbsentFile() {
    // A user who has never run Claude Code has no settings.json at all.
    let reader = HookHealthReader(
        settingsURL: fixtures.appending(path: "definitely-not-here.json"))
    #expect(reader.status() == .unreadable)
}

@Test func theReaderDoesNotCrashOnADirectory() {
    // `Data(contentsOf:)` on a directory throws rather than returning empty.
    let reader = HookHealthReader(settingsURL: fixtures)
    #expect(reader.status() == .unreadable)
}

@Test func theDefaultSettingsURLIsTheUsersClaudeSettings() {
    // Design §6 fixes the location. coffee-bar READS it and never writes it.
    //
    // The expected path is built from `NSHomeDirectory()`, which is a different
    // API from the `FileManager.homeDirectoryForCurrentUser` the reader uses.
    // Asserting a suffix alone would let a reader that resolved the wrong home
    // directory pass.
    #expect(HookHealthReader().settingsURL.path
            == NSHomeDirectory() + "/.claude/settings.json")
}

// MARK: - One file per tool

@Test func theDefaultHookFilesAreTheThreeToolsOwnFiles() {
    // Named bug this catches: a second tool's advisory measured against Claude
    // Code's file. `defaultSettingsURL` was the only location this type knew, so
    // a Codex user's verdict came from a file their tool never reads.
    //
    // Every path is a literal built from `NSHomeDirectory()`, a different API
    // from the `FileManager.homeDirectoryForCurrentUser` the reader uses, so a
    // reader that resolved the wrong home directory cannot pass.
    let files = HookHealthReader().hookFiles
    #expect(files.count == 3, "the reader covers \(files.count) tool(s): \(files.keys)")

    #expect(files[.claudeCode]?.path == NSHomeDirectory() + "/.claude/settings.json")
    #expect(files[.codex]?.path == NSHomeDirectory() + "/.codex/hooks.json")
    #expect(files[.cursor]?.path == NSHomeDirectory() + "/.cursor/hooks.json")
}

@Test func aReaderBuiltForClaudeCodeAloneReadsNoOtherToolsFile() throws {
    // Named bug this catches, and it would have been INVISIBLE in CI: a
    // `HookHealthReader(settingsURL:)` that quietly kept the real default paths
    // for the other two. Every check that injects a fixture would then read the
    // developer's own `~/.codex/hooks.json`, pass on a machine with no Codex
    // installed, and fail on one that has it.
    let reader = HookHealthReader(settingsURL: fixtures.appending(path: "wired.json"))

    #expect(reader.hookFiles.count == 1,
            "the single-file reader covers \(reader.hookFiles.keys)")
    #expect(reader.status(for: .codex) == nil, "it reached a Codex file")
    #expect(reader.status(for: .cursor) == nil, "it reached a Cursor file")
    #expect(reader.status(for: .claudeCode) == .wired)
}

@Test func aToolWithNoFileOnDiskGetsNoVerdictAtAll() throws {
    // Design decision this pins: an ABSENT hook file means the user does not run
    // that tool, so coffee-bar says nothing about it.
    //
    // Named bug this catches: a Claude-Code-only user being told to wire Cursor.
    // `.unreadable` is the wrong answer here — it is what the panel says when it
    // COULD NOT PARSE a file that exists, and it sends the user to a file that
    // is not theirs to fix.
    //
    // The gate is FILE EXISTENCE and never "has this tool ever posted an event".
    // That second rule is circular: a tool with no hooks wired never posts, so
    // it would never be advised, and the advisory exists for exactly that user.
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-health-\(UUID().uuidString)")
    let files = FileManager.default
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }

    let present = scratch.appending(path: "cursor-hooks.json")
    try Data(contentsOf: packageRoot.appending(path: "Tests/Fixtures/cursor-settings/wired.json"))
        .write(to: present)
    let absent = scratch.appending(path: "definitely-not-here.json")
    #expect(files.fileExists(atPath: absent.path) == false)

    let reader = HookHealthReader(hookFiles: [.codex: absent, .cursor: present])

    #expect(reader.status(for: .codex) == nil,
            "an absent file produced a verdict; the user is told to fix a file they do not have")
    #expect(reader.status(for: .cursor) == .wired,
            "the file that IS on disk was not read; this check would pass on nothing")
}

@Test func statusReadsThisReadersOwnFileAndNeverTheRealHomeOne() throws {
    // Named bug this catches, and it was LATENT rather than theoretical:
    // `status()` read `settingsURL`, which falls back to the design §6 default
    // when this reader covers no Claude Code file. A reader built for Codex
    // alone therefore opened the DEVELOPER'S REAL `~/.claude/settings.json` —
    // the machine-dependent read that the `hookFiles` comment says this design
    // exists to prevent. Probed on a machine with a wired home file, a
    // Codex-only reader returned `.wired` while `statuses()` returned `[:]`.
    //
    // No production path called it, so nothing shipped wrong. It was a trap
    // laid for the next caller, and closing it costs nothing.
    //
    // `.unreadable` is the honest answer: this reader has no Claude Code file,
    // so it cannot confirm the entries are installed. That is what `.unreadable`
    // means everywhere else in this type.
    let root = packageRoot.appending(path: "Tests/Fixtures")
    let codexOnly = HookHealthReader(
        hookFiles: [.codex: root.appending(path: "codex-settings/wired.json")])

    #expect(codexOnly.status() == .unreadable,
            "status() reached a file this reader does not cover")

    // The discriminating pair. A reader that DOES cover Claude Code still reads
    // its own file, so the check above cannot pass by making `status()` inert.
    let claudeCode = HookHealthReader(
        settingsURL: root.appending(path: "claude-settings/wired.json"))
    #expect(claudeCode.status() == .wired,
            "status() stopped reading the file this reader was given")

    // LIMIT, stated rather than hidden: the first expectation discriminates
    // only where `~/.claude/settings.json` exists and is not itself
    // `.unreadable`. On a machine with no such file the old fallback also
    // returned `.unreadable`, so this would pass vacuously there. It is
    // strongest exactly where the hazard is real, and the mutation record for
    // this branch proves it red against the old fallback.
    // `statuses()` was always right here — it reads the map and never the
    // fallback — so it reports Codex and says nothing about Claude Code. That
    // is the contrast that made the old `status()` behaviour visible as a bug
    // rather than a choice: the two methods disagreed about which files this
    // reader covers.
    #expect(codexOnly.statuses() == [.codex: .wired],
            "statuses() reported \(codexOnly.statuses())")
    #expect(codexOnly.statuses()[.claudeCode] == nil,
            "statuses() reached a Claude Code file this reader does not cover")
}

@Test func claudeCodeAloneIsExemptFromTheExistenceGate() throws {
    // Named bug this catches, and it shipped: the gate applied to Claude Code
    // as well, so a user who had never created `~/.claude/settings.json` got no
    // advisory at all. README says coffee-bar does nothing until those hooks
    // exist, so that user needs the advice most.
    //
    // An absent file means "not set up yet" for Claude Code, the primary
    // integration and the first-run path. It means "does not use this tool" for
    // the other two. The discriminating pair is asserted in ONE check, because
    // the exemption is only correct if it is narrow.
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-health-\(UUID().uuidString)")
    let files = FileManager.default
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }

    let absent = scratch.appending(path: "definitely-not-here.json")
    #expect(files.fileExists(atPath: absent.path) == false)
    #expect(try files.contentsOfDirectory(atPath: scratch.path) == [],
            "the scratch directory is not empty; this check would read a real file")

    let reader = HookHealthReader(hookFiles: [.claudeCode: absent,
                                              .codex: absent,
                                              .cursor: absent])

    #expect(reader.status(for: .claudeCode) == .unreadable,
            "an absent Claude Code file gives no verdict; a first-run user is told nothing")
    #expect(reader.status(for: .codex) == nil, "an absent Codex file reached a verdict")
    #expect(reader.status(for: .cursor) == nil, "an absent Cursor file reached a verdict")

    #expect(reader.statuses() == [.claudeCode: .unreadable],
            "statuses() reported \(reader.statuses())")
}

@Test func eachToolIsReadThroughItsOwnParserAndItsOwnFile() throws {
    // The whole point of the task, driven end to end from real files on disk.
    //
    // Named bug this catches: one parser for all three. Cursor nests one level
    // LESS than Claude Code, so the shared nested reader reports a fully wired
    // Cursor file as missing every entry — and the `.wired` expectation below
    // goes red the moment that happens.
    let root = packageRoot.appending(path: "Tests/Fixtures")
    let reader = HookHealthReader(hookFiles: [
        .claudeCode: root.appending(path: "claude-settings/missing-stop.json"),
        .codex: root.appending(path: "codex-settings/wired.json"),
        .cursor: root.appending(path: "cursor-settings/captured.json"),
    ])

    #expect(reader.status(for: .claudeCode) == .missing(["Stop"]))
    #expect(reader.status(for: .codex) == .wired)
    // The captured Cursor file carries three of the five required event KEYS and
    // none of coffee-bar's commands, so the true answer is all five.
    #expect(reader.status(for: .cursor)
            == .missing(["afterFileEdit", "afterShellExecution", "beforeReadFile",
                         "beforeShellExecution", "sessionStart"]))

    #expect(reader.statuses().count == 3)
}

@Test func statusesReportsOnlyTheToolsWhoseFileIsOnDisk() throws {
    // `statuses()` is what the panel reads. Named bug this catches: reporting a
    // tool the user does not run, which is the whole complaint this task fixes,
    // arriving through the collection rather than through one lookup.
    let root = packageRoot.appending(path: "Tests/Fixtures")
    let reader = HookHealthReader(hookFiles: [
        .claudeCode: root.appending(path: "claude-settings/wired.json"),
        .codex: root.appending(path: "codex-settings/definitely-not-here.json"),
        .cursor: root.appending(path: "cursor-settings/no-hooks.json"),
    ])

    let statuses = reader.statuses()
    #expect(Set(statuses.keys) == [.claudeCode, .cursor],
            "statuses() reported \(statuses.keys.map(\.rawValue).sorted())")
    #expect(statuses[.claudeCode] == .wired)
    #expect(statuses[.cursor] == .missing(["afterFileEdit", "afterShellExecution",
                                           "beforeReadFile", "beforeShellExecution",
                                           "sessionStart"]))
}

@Test func readingEveryToolsStatusLeavesEveryFileExactlyAsItWas() throws {
    // `readingTheStatusLeavesTheFileExactlyAsItWas` holds this line for Claude
    // Code. Named bug this catches: a per-tool reader that repairs, seeds or
    // touches one of the two files that check never opens. Design §6 forbids
    // writing any of them, and `~/.cursor/hooks.json` is shared territory in
    // exactly the way `~/.claude/settings.json` is.
    let files = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-health-\(UUID().uuidString)")
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }

    let root = packageRoot.appending(path: "Tests/Fixtures")
    var copies: [AgentTool: URL] = [:]
    for (tool, source) in [(AgentTool.claudeCode, "claude-settings/missing-stop.json"),
                           (AgentTool.codex, "codex-settings/missing-two.json"),
                           (AgentTool.cursor, "cursor-settings/captured.json")] {
        let destination = scratch.appending(path: "\(tool.rawValue).json")
        try Data(contentsOf: root.appending(path: source)).write(to: destination)
        copies[tool] = destination
    }

    let before = try copies.mapValues { try Data(contentsOf: $0) }
    let listingBefore = try files.contentsOfDirectory(atPath: scratch.path).sorted()
    // A scratch directory holding nothing would make every check below vacuous.
    #expect(listingBefore == ["claudeCode.json", "codex.json", "cursor.json"])

    let reader = HookHealthReader(hookFiles: copies)
    _ = reader.statuses()
    _ = reader.statuses()

    for (tool, url) in copies {
        #expect(try Data(contentsOf: url) == before[tool],
                "reading \(tool.rawValue) changed the bytes of its hook file")
    }
    #expect(try files.contentsOfDirectory(atPath: scratch.path).sorted() == listingBefore,
            "reading the statuses left something new beside the hook files")
}

// MARK: - It never writes

@Test func readingTheStatusLeavesTheFileExactlyAsItWas() throws {
    // Named bug this catches: any repair-on-read. A `status()` that rewrote a
    // half-installed settings.json — even byte-identically — is the
    // last-writer-wins clobber design §6 refuses, and the panel would report
    // healthy on a file it had just overwritten.
    let file = try scratchCopy(of: "missing-stop.json")
    let directory = file.deletingLastPathComponent()
    let files = FileManager.default

    let bytesBefore = try Data(contentsOf: file)
    let attributesBefore = try files.attributesOfItem(atPath: file.path)
    let modifiedBefore = try #require(attributesBefore[.modificationDate] as? Date)
    let listingBefore = try files.contentsOfDirectory(atPath: directory.path)

    // A scratch directory holding nothing would make every check below vacuous.
    #expect(listingBefore == ["missing-stop.json"])

    let reader = HookHealthReader(settingsURL: file)
    #expect(reader.status() == .missing(["Stop"]))
    #expect(reader.status() == .missing(["Stop"]))

    #expect(try Data(contentsOf: file) == bytesBefore, "status() changed the bytes")
    let modifiedAfter = try #require(
        try files.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    #expect(modifiedAfter == modifiedBefore, "status() touched the modification date")
    #expect(try files.contentsOfDirectory(atPath: directory.path) == listingBefore,
            "status() left something new beside the settings file")

    try? files.removeItem(at: directory)
}

@Test func readingAnAbsentFileDoesNotCreateIt() throws {
    // Named bug this catches: a reader that opens the path for update, or that
    // seeds a default file for a user who has never run Claude Code. Either one
    // puts coffee-bar in the business of owning that file.
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "coffee-bar-health-\(UUID().uuidString)")
    let files = FileManager.default
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    let absent = scratch.appending(path: "settings.json")

    #expect(files.fileExists(atPath: absent.path) == false)

    #expect(HookHealthReader(settingsURL: absent).status() == .unreadable)

    #expect(files.fileExists(atPath: absent.path) == false,
            "status() created the settings file it was asked to read")
    #expect(try files.contentsOfDirectory(atPath: scratch.path) == [])

    try? files.removeItem(at: scratch)
}

/// Calls that put bytes on disk. Not a proof that no other route exists — the
/// behavioural checks above are the first line of defence, and this is the
/// second.
private let forbiddenWriteCalls = [
    "write(to:",
    ".write(",
    "createFile",
    "createDirectory",
    "forWritingTo",
    "forUpdating",
    "removeItem",
    "moveItem",
    "copyItem",
    "replaceItem",
    "O_WRONLY",
    "O_RDWR",
    "O_CREAT",
    "fopen",
]

@Test func noSourceFileThatKnowsTheSettingsPathCanWriteToIt() throws {
    // A behavioural check only covers the paths it drives. This one reads the
    // sources instead: whichever file knows where `~/.claude/settings.json`
    // lives must contain no call that puts bytes on disk.
    let files = FileManager.default
    let sources = packageRoot.appending(path: "Sources")

    let enumerator = try #require(files.enumerator(atPath: sources.path))
    let swiftFiles = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }

    // A walk that reached nothing would satisfy the loop below by never
    // entering it.
    #expect(swiftFiles.count >= 20,
            "the scan reached \(swiftFiles.count) files under \(sources.path)")

    var knowsThePath: [String] = []
    for relative in swiftFiles {
        let source = try String(contentsOf: sources.appending(path: relative), encoding: .utf8)
        guard source.contains(".claude/settings.json") || source.contains("settingsURL")
        else { continue }
        knowsThePath.append((relative as NSString).lastPathComponent)

        for call in forbiddenWriteCalls {
            #expect(!source.contains(call), """
                \(relative) knows where ~/.claude/settings.json lives and names \
                \(call). Design §6 forbids writing that file: print the snippet \
                for the user to paste instead.
                """)
        }
    }

    // The literal is the anchor. Without it a renamed reader would match
    // nothing, the loop would never run, and this check would pass by reading
    // no file at all.
    //
    // `TelemetryRecon.swift` is the one that was already there — handoff §15.4
    // reads the same file to decide the telemetry mode, and its `.ownIt` case
    // is described as a mode where "coffee-bar may write its own" config. That
    // is about coffee-bar's OWN config, and the loop above now makes the other
    // reading of that sentence fail here.
    //
    // `ServingModel.swift` joined the set when `hookAdvisory` landed: the panel
    // line has to NAME the file the user must fix, or it is not actionable, and
    // that spells the path out in the model. Admitting it here is the point of
    // the anchor rather than a cost of it — the loop above now holds the same
    // no-write line over the model that renders the advice as it does over the
    // reader that produced it.
    #expect(knowsThePath.sorted() == ["HookHealth.swift",
                                      "HookHealthReader.swift",
                                      "ServingModel.swift",
                                      "TelemetryRecon.swift"],
            "the set of files that know the settings path changed: \(knowsThePath.sorted())")
}
