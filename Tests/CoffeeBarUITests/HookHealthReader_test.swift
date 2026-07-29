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
    #expect(knowsThePath.sorted() == ["HookHealth.swift",
                                      "HookHealthReader.swift",
                                      "TelemetryRecon.swift"],
            "the set of files that know the settings path changed: \(knowsThePath.sorted())")
}
