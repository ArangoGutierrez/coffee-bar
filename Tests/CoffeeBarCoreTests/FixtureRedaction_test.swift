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
