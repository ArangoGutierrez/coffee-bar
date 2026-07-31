// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// This repository is public. `Tests/Fixtures/claude-hooks/` holds payloads
// captured from a live Claude Code session, so every value in them is a
// candidate leak until somebody scrubs it.
//
// `scripts/redact-hook-fixtures.py` scrubs by KEY: identifiers get stable fakes
// and the keys it lists in CONTENT_KEYS get the literal "REDACTED". That pass
// handled paths and identifiers. It missed free prose, because `reason` is not
// in CONTENT_KEYS — and 599 characters of real session text reached `origin/main`
// inside `permission-denied.json`.
//
// The guards below are the second line of defence. They scan the corpus for the
// content markers that leak carried, so the same class of miss fails here rather
// than shipping.
//
// Why markers and not length: `transcript_path` is 121 characters in all six
// fixtures and is a legitimate synthetic path. A pure length rule flags every
// fixture and gets switched off.

private var fixtureDirectory: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/FixtureRedaction_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-hooks")
}

private func fixtureNames() throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: fixtureDirectory.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
}

private func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: fixtureDirectory.appending(path: name), encoding: .utf8)
}

/// Substrings taken from the prose that leaked. Each one names live session
/// content, so none of them belongs in a public fixture.
private let forbiddenContentMarkers = [
    "capture.jsonl",
    "Sensitive-Source Provenance",
    "assistant message text",
    "tool inputs/responses",
]

/// The real username. `scripts/redact-hook-fixtures.py` refuses to emit a
/// fixture containing it; this guard refuses to let one sit in the tree.
private let forbiddenUsername = "eduardoa"

/// The marker that says `permission-denied.json` carries the synthetic reason
/// rather than a recaptured one. No real payload contains it.
private let syntheticReasonSentinel = "SYNTHETIC-FIXTURE-REASON-1f4a9c"

@Test func noFixtureCarriesLiveSessionProse() throws {
    // Named bug this catches: a re-capture, or a new event kind, whose free-prose
    // field is not in the redaction script's CONTENT_KEYS. That is exactly how
    // 599 characters of live session text reached a public repository once.
    let names = try fixtureNames()

    // The count guard comes first and is not decoration. A scan over an empty
    // or misresolved directory finds zero matches and reads as success.
    #expect(names.count >= 6,
            "scanned \(names.count) fixtures at \(fixtureDirectory.path); the corpus shrank and this scan is weaker than it looks")

    for name in names {
        let text = try fixtureText(name)
        for marker in forbiddenContentMarkers {
            #expect(!text.contains(marker),
                    "\(name) contains \(marker); that is live session content in a public repository")
        }
        #expect(!text.contains(forbiddenUsername),
                "\(name) contains the real username; re-run scripts/redact-hook-fixtures.py")
    }
}

@Test func theDenialReasonIsSyntheticAndStillProvesTheCap() throws {
    // Two properties in one place, because they trade off against each other.
    //
    // Named bug this catches: replacing the leaked prose with a short string.
    // That closes the leak and silently guts `lastMessageIsCappedAt140Characters`
    // in SessionHub_test, whose input is this very field. Under 141 characters
    // the cap test truncates nothing and proves nothing.
    let text = try fixtureText("permission-denied.json")
    #expect(text.contains(syntheticReasonSentinel),
            "permission-denied.json lost its synthetic marker; its reason may be recaptured prose")

    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    let payload = try #require(object as? [String: Any])
    let reason = try #require(payload["reason"] as? String,
                              "permission-denied.json carries no reason; the cap test has no input")
    #expect(reason.count > 140,
            "the fixture reason is \(reason.count) characters; SessionHub's 140-character cap can no longer be proved")
}

/// Every file git TRACKS, as repo-relative paths.
///
/// `git ls-files` and not a directory walk: the leak this catches reached a
/// public repository by being COMMITTED, and an untracked scratch file with the
/// same markers is nobody's problem. Binary files are excluded by extension
/// rather than by sniffing, because the corpus is text.
private func trackedTextFiles() throws -> [String] {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // repo root

    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    git.arguments = ["git", "-C", repoRoot.path, "ls-files"]
    let out = Pipe()
    git.standardOutput = out
    git.standardError = FileHandle.nullDevice
    try git.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    git.waitUntilExit()

    guard git.terminationStatus == 0 else { return [] }

    let skip = [".png", ".jpg", ".jpeg", ".gif", ".icns", ".pdf", ".zip"]
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .map(String.init)
        .filter { name in !skip.contains(where: { name.hasSuffix($0) }) }
        .sorted()
}

@Test func noTrackedFileCarriesLiveSessionProse() throws {
    // Named bug this catches: the leaked prose being re-published somewhere the
    // fixtures-only scan cannot see. That is exactly what commit f419de0 did —
    // it put the session path, a description of its contents, and a verbatim
    // user quote into a TRACKED plan document while the fixture guard stayed
    // green.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let files = try trackedTextFiles()

    // The count guard is not decoration. A scan that resolved the wrong root
    // finds zero files and reads as success.
    #expect(files.count >= 50,
            "scanned \(files.count) tracked files at \(repoRoot.path); this scan is weaker than it looks")

    // This guard file NAMES the markers, so it must be exempt or it reports itself.
    let selfPath = "Tests/CoffeeBarCoreTests/FixtureRedaction_test.swift"

    for name in files where name != selfPath {
        let url = repoRoot.appending(path: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for (index, marker) in forbiddenContentMarkers.enumerated() {
            // Bind the result to a Bool BEFORE the expectation, and interpolate
            // NEITHER the file text NOR the marker into the message.
            //
            // swift-testing captures and prints every subexpression inside
            // `#expect`, so the obvious `#expect(!text.contains(marker))` dumps
            // the ENTIRE offending file — and the marker itself — into the test
            // log, and from there into a public CI build log. A guard against
            // re-publishing live session content must not re-publish it while
            // reporting. Measured: that form printed all 979 lines of the
            // offending document, four times over.
            //
            // The index names the offender without quoting it. `forbiddenContentMarkers`
            // is right here in this file for anyone who needs to look it up.
            let carriesMarker = text.contains(marker)
            #expect(carriesMarker == false,
                    "\(name) carries forbidden content marker #\(index); that is live session content in a public repository")
        }
    }
}
