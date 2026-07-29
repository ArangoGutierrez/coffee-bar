// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

/// The fixture directory, resolved from `#filePath`.
///
/// Never from the working directory: under `swift test` the working directory
/// is not the package root, and a fixture test that silently reads nothing is
/// worse than no test at all.
private var fixtures: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/HookEvent_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-hooks")
}

private func fixtureNames() throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: fixtures.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
}

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appending(path: name))
}

private func decode(_ name: String) throws -> HookEvent {
    try JSONDecoder().decode(HookEvent.self, from: fixtureData(name))
}

/// The payload as a raw dictionary, read by a decoder that is NOT `Codable`.
///
/// Every cross-check below compares the decoded property against this, so the
/// expectation is derived independently of the `CodingKeys` map under test.
private func rawPayload(_ name: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: try fixtureData(name))
    return try #require(object as? [String: Any])
}

@Test func everyCapturedPayloadDecodes() throws {
    // Named bug this catches: a CodingKeys map that does not match what Claude
    // Code actually sends. Design §9 is the reason this test reads recorded
    // bytes, so a renamed or missing key fails here rather than in the field
    // with an ingest that silently drops every event.
    let names = try fixtureNames()
    #expect(names.count >= 4,
            "found \(names.count) fixtures at \(fixtures.path); the corpus is missing events")

    for name in names {
        let event = try decode(name)
        let raw = try rawPayload(name)
        // Compared against `JSONSerialization`, not against another `Codable`
        // read of the same keys: a wrong CodingKey moves the value, and only an
        // independent reader of the wire name catches that.
        #expect(event.sessionID == raw["session_id"] as? String,
                "\(name): sessionID did not come from session_id")
        #expect(event.hookEventName == raw["hook_event_name"] as? String,
                "\(name): hookEventName did not come from hook_event_name")
        #expect(event.cwd == raw["cwd"] as? String, "\(name): cwd mismatch")
        #expect(!event.sessionID.isEmpty)
        #expect(!event.hookEventName.isEmpty)
    }
}

@Test func theCorpusCoversEveryEventTheHubActsOn() throws {
    // A corpus that lost an event would let Task 3 write a transition against
    // nothing.
    //
    // `SessionStart` and `SessionEnd` are NOT required: they need a session
    // boundary and the 2026-07-28 capture did not produce one. Design §3.2
    // records that nothing observed reports session end. Do not add them here
    // until a real payload lands in the corpus — a required name with no
    // fixture behind it is the M0 failure mode.
    let names = try Set(fixtureNames().map { try decode($0).hookEventName })
    for required in ["PreToolUse", "PostToolUse", "PermissionDenied", "Stop"] {
        #expect(names.contains(required), "no fixture for \(required)")
    }
}

@Test func preToolUseCarriesItsToolName() throws {
    let event = try decode("pre-tool-use.json")
    #expect(event.kind == .preToolUse)
    #expect(event.toolName == "Bash")
}

@Test func permissionDeniedCarriesItsReason() throws {
    // The captured `PermissionDenied` payload carries `reason`. Design §3 says
    // it carries `message`; the fixture disagrees and the fixture wins.
    //
    // Named bug this catches: keying the blocked-on-a-human explanation to a
    // field Claude Code does not send, which decodes to nil and leaves the
    // panel with nothing to show at the one moment the human is the bottleneck.
    let event = try decode("permission-denied.json")
    let raw = try rawPayload("permission-denied.json")
    #expect(event.kind == .permissionDenied)
    #expect(raw["message"] == nil, "the corpus grew a `message` field; design §3 may be right after all")
    #expect(event.reason == raw["reason"] as? String)
    #expect(event.reason?.contains("Sensitive-Source Provenance") == true)
}

@Test func aCapturedPayloadCarriesNoSourceBecauseSessionStartWasNotCaptured() throws {
    // `source` exists for `SessionStart`, which the capture never produced. The
    // property is declared for it and no test asserts a value we do not hold.
    // This pins the honest state of the corpus: if a `SessionStart` fixture
    // lands, this test goes red and whoever adds it must assert `source` for
    // real.
    for name in try fixtureNames() {
        #expect(try decode(name).source == nil, "\(name) carries `source`; assert it properly")
    }
}

@Test func anUnknownEventDecodesWithNoKind() throws {
    // Claude Code adds hook events over time. An unknown one must decode and
    // classify as nil, so the hub can ignore it. Named bug this catches: a
    // `HookEventKind` decoded directly, which makes the whole payload fail to
    // decode and takes the KNOWN events on that connection down with it.
    let raw = Data("""
        {"hook_event_name":"SomeFutureEvent","session_id":"s1"}
        """.utf8)
    let event = try JSONDecoder().decode(HookEvent.self, from: raw)
    #expect(event.hookEventName == "SomeFutureEvent")
    #expect(event.kind == nil)
}

@Test func aPayloadWithNoSessionIDFailsToDecode() throws {
    // `session_id` is the key everything is keyed by. A payload without one is
    // not a session event, and accepting it with an empty id would merge every
    // such payload into one phantom session that holds the machine awake.
    let raw = Data(#"{"hook_event_name":"Stop"}"#.utf8)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(HookEvent.self, from: raw)
    }
}
