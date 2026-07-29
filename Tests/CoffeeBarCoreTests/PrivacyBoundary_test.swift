// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// Design §7 forbids reading conversation content. Two fields carry it, and the
// second one was found only by capturing real payloads (design §7.1):
//
//   transcript_path        — a path to the whole conversation. Never open it.
//   last_assistant_message — 2747 characters of assistant reply text delivered
//                            DIRECTLY in the `Stop` payload, behind no path.
//
// `HookEvent` therefore declares NO property for either: a field that does not
// exist cannot be opened, logged or rendered, and `Codable` drops unknown keys,
// so both are discarded at the decode boundary.
//
// Each field gets three independent guards, because each catches a leak the
// others miss:
//
//   1. the wire key is absent from the re-encoded payload — catches a property
//      that carries the field under its own name;
//   2. the field's VALUE reaches no stored property and no rendered string —
//      catches a property that carries the field under a DIFFERENT name, which
//      guard 1 cannot see;
//   3. no file under `Sources` names the key — the second line of defence. It
//      cannot prove no route exists, only that no source file names one.
//
// Every guard runs against a recorded fixture that really carries the field. A
// guard built from the same assumption as the code tests nothing.

private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/PrivacyBoundary_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // the package root
}

private var fixtureDirectory: URL {
    packageRoot.appending(path: "Tests/Fixtures/claude-hooks")
}

/// The wire key, then the property name a Swift author would most likely give
/// it. Both are forbidden.
private let forbiddenTranscript = ["transcript_path", "transcriptPath"]
private let forbiddenMessage = ["last_assistant_message", "lastAssistantMessage"]

private func fixtureNames() throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: fixtureDirectory.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
}

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureDirectory.appending(path: name))
}

private func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: fixtureDirectory.appending(path: name), encoding: .utf8)
}

/// The value Claude Code really sent for `key`, read straight off the fixture.
///
/// Read from the file rather than written into the test, so a re-capture that
/// replaces `REDACTED` with real text moves the needle with it.
private func recordedValue(_ key: String, in name: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: try fixtureData(name))
    let payload = try #require(object as? [String: Any], "\(name) is not a JSON object")
    let value = try #require(payload[key] as? String, "\(name) carries no `\(key)`")
    #expect(!value.isEmpty, "\(name) carries an empty `\(key)`; the needle is vacuous")
    return value
}

/// Every stored property of `event`, rendered for a substring scan.
///
/// Reflection rather than a hand-written property list: a property added later
/// is scanned without anybody remembering to add it here.
private func storedProperties(of event: HookEvent) -> [(name: String, rendered: String)] {
    Mirror(reflecting: event).children.map {
        ($0.label ?? "<unlabelled>", String(describing: $0.value))
    }
}

/// Proves `HookEvent` discards `key` from the recorded payload `fixture`.
///
/// Runs guards 1 and 2 from the header: the wire key survives no round trip,
/// and the recorded VALUE reaches no stored property and no rendered string.
private func expectHookEventDrops(_ key: String, named keys: [String],
                                  from fixture: String, describedAs subject: String) throws {
    let recorded = try recordedValue(key, in: fixture)
    let event = try JSONDecoder().decode(HookEvent.self, from: try fixtureData(fixture))

    // Guard 1 — the wire key survives no round trip.
    let encoded = try JSONEncoder().encode(event)
    let reencoded = try #require(String(data: encoded, encoding: .utf8))
    for name in keys {
        #expect(!reencoded.contains(name),
                Comment(rawValue: "HookEvent round-tripped \(name); design §7 forbids carrying \(subject)"))
    }

    // Guard 2a — no stored property holds the value, whatever it is named.
    let properties = storedProperties(of: event)
    #expect(properties.count >= 2,
            Comment(rawValue: "reflected \(properties.count) properties of HookEvent; the scan would be vacuous"))
    for property in properties {
        #expect(!property.rendered.contains(recorded),
                Comment(rawValue: "HookEvent.\(property.name) holds \(subject)"))
    }

    // Guard 2b — the log line and the panel string. Whatever a caller prints
    // for a `HookEvent` goes through one of these two.
    for rendered in [String(describing: event), String(reflecting: event)] {
        #expect(!rendered.contains(recorded),
                Comment(rawValue: "a rendered HookEvent shows \(subject)"))
    }
}

private func everySwiftSourceFile() throws -> [URL] {
    let sources = packageRoot.appending(path: "Sources")
    guard let walk = FileManager.default.enumerator(
        at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }

    var found: [URL] = []
    for case let entry as URL in walk where entry.pathExtension == "swift" {
        found.append(entry)
    }
    return found.sorted { $0.path < $1.path }
}

// MARK: - Positive controls

@Test func theFixturesDoCarryTheFieldsTheseGuardsForbid() throws {
    // The reason the guards below are not theater.
    //
    // If the redaction in Task 1 had stripped either key, every guard would
    // pass against a needle that exists nowhere, and would keep passing after
    // somebody added the property. This proves both needles are real first.
    let names = try fixtureNames()
    #expect(!names.isEmpty, "no fixtures found at \(fixtureDirectory.path)")

    let carryingPath = try names.filter { try fixtureText($0).contains("transcript_path") }
    #expect(!carryingPath.isEmpty,
            "no fixture carries transcript_path; the transcript guards test nothing")

    let carryingMessage = try names.filter { try fixtureText($0).contains("last_assistant_message") }
    #expect(carryingMessage.contains("stop.json"),
            "stop.json no longer carries last_assistant_message; design §7.1 guards test nothing")
}

// MARK: - transcript_path

@Test func hookEventDropsTheTranscriptPath() throws {
    try expectHookEventDrops("transcript_path", named: forbiddenTranscript,
                             from: "permission-denied.json",
                             describedAs: "the transcript path")
}

// MARK: - last_assistant_message, design §7.1

@Test func hookEventDropsTheLastAssistantMessage() throws {
    // Asserted against stop.json, the payload that really carries the field.
    // §7.1 measured 2747 characters of assistant reply text in the first sample.
    try expectHookEventDrops("last_assistant_message", named: forbiddenMessage,
                             from: "stop.json",
                             describedAs: "the assistant reply text")
}

// MARK: - The source scan

@Test func noSourceFileNamesAForbiddenField() throws {
    let files = try everySwiftSourceFile()
    // Without this, a broken walk passes by reading nothing — a leak scan over
    // an empty directory reports zero matches and looks like success.
    #expect(files.count >= 20,
            "the privacy scan reached \(files.count) files at \(packageRoot.path)")

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for needle in forbiddenTranscript + forbiddenMessage {
            #expect(!source.contains(needle),
                    "\(file.lastPathComponent) names \(needle); design §7 forbids reading it")
        }
    }
}
