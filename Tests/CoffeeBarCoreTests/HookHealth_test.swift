// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// Design §6 is explicit: read a fixture from disk, do not assert against a
// hand-built string that duplicates the parser's own logic.
//
// Every expectation below is a LITERAL — `.wired`, `.missing(["Stop"])` — never
// a value the parser produced. The fixture is only the INPUT.

private var fixtureDirectory: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/HookHealth_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/claude-settings")
}

private func settings(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureDirectory.appending(path: name))
}

@Test func theSettingsFixturesAreOnDiskWhereTheseChecksLookForThem() throws {
    // A missing fixture directory would make every `settings(...)` call throw,
    // and a thrown error is not the same failure as a wrong verdict. This names
    // the five files as a literal so a rename cannot quietly shrink the set the
    // checks below exercise.
    let found = try FileManager.default
        .contentsOfDirectory(atPath: fixtureDirectory.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()

    #expect(found == ["malformed.json", "missing-stop.json", "missing-two.json",
                      "no-hooks.json", "wired.json"],
            "the settings fixtures at \(fixtureDirectory.path) changed")
}

@Test func aFullyWiredSettingsFileReportsWired() throws {
    #expect(try HookHealth.status(ofSettings: settings("wired.json")) == .wired)
}

@Test func aMissingEventIsNamed() throws {
    // The user has to know WHICH entry to paste back. "Ingest is broken" sends
    // them to re-paste all five and risk clobbering the other four.
    #expect(try HookHealth.status(ofSettings: settings("missing-stop.json"))
            == .missing(["Stop"]))
}

@Test func twoMissingEventsAreNamedInASortedOrder() throws {
    // The panel prints this list. An order that follows the settings file's own
    // key order would reshuffle the line every time the user edited an
    // unrelated hook, so the order is fixed here as a literal.
    #expect(try HookHealth.status(ofSettings: settings("missing-two.json"))
            == .missing(["PermissionDenied", "Stop"]))
}

@Test func aSettingsFileWithNoHooksNamesEveryRequiredEvent() throws {
    #expect(try HookHealth.status(ofSettings: settings("no-hooks.json"))
            == .missing(["PermissionDenied", "PostToolUse", "PreToolUse",
                         "SessionStart", "Stop"]))
}

@Test func aMalformedSettingsFileIsReportedNotCrashed() throws {
    // Someone else's editor half-wrote the file. The panel must say so, not
    // die, and must not claim the hooks are missing — that would send the user
    // to paste entries that are already there.
    #expect(try HookHealth.status(ofSettings: settings("malformed.json"))
            == .unreadable)
}

@Test func anAbsentSettingsFileIsReportedNotCrashed() {
    #expect(HookHealth.status(ofSettings: nil) == .unreadable)
}

@Test func anEmptyFileIsUnreadableRatherThanEmptyOfHooks() {
    // A zero-byte settings.json is what a truncating writer leaves behind. It
    // carries no evidence that the entries are gone, so it must not be reported
    // as missing entries.
    #expect(HookHealth.status(ofSettings: Data()) == .unreadable)
}

@Test func anEntryPointingSomewhereElseDoesNotCount() {
    // Named bug this catches: matching on the EVENT KEY rather than on the
    // command. Another tool's Stop hook would then satisfy our check, the panel
    // would report healthy, and no event would ever arrive.
    //
    // The other tool's command is itself a `curl --unix-socket` POST, aimed at
    // a DIFFERENT socket. That is deliberate: a marker loosened to "curl", or
    // to "--unix-socket", has to fail here rather than pass by accident.
    let raw = Data("""
        {"hooks": {"Stop": [{"hooks": [{"type":"command","command":\
        "curl -sS --unix-socket \\"$HOME/.other-tool/thing.sock\\" \
        -X POST --data-binary @- http://localhost/hook"}]}]}}
        """.utf8)
    let status = HookHealth.status(ofSettings: raw)

    #expect(status != .wired)
    if case .missing(let events) = status {
        #expect(events.contains("Stop"))
    } else {
        Issue.record("expected .missing, got \(status)")
    }
}

@Test func aHooksValueOfTheWrongShapeIsNotAMatch() {
    // Claude Code's settings file is hand-edited, so any key can hold any JSON.
    // Each of these must reach a verdict rather than trap on a failed cast.
    let shapes = [
        #"{"hooks": {"Stop": "curl coffee-bar/ingest.sock"}}"#,
        #"{"hooks": {"Stop": []}}"#,
        #"{"hooks": {"Stop": [{"hooks": []}]}}"#,
        #"{"hooks": {"Stop": [{"hooks": [{"type": "command"}]}]}}"#,
        #"{"hooks": {"Stop": [{"matcher": "*"}]}}"#,
        #"{"hooks": []}"#,
    ]

    for shape in shapes {
        let status = HookHealth.status(ofSettings: Data(shape.utf8))
        #expect(status != .wired, "\(shape) reported wired")
    }
}

@Test func aTopLevelJSONArrayIsUnreadableRatherThanEmptyOfHooks() {
    // Not a settings file at all. Reporting missing entries here would tell the
    // user to paste five hooks into a file that is not theirs to fix.
    #expect(HookHealth.status(ofSettings: Data(#"[1, 2, 3]"#.utf8)) == .unreadable)
}

/// Every event the hub knows is either required or a documented exclusion.
///
/// This is the guard the previous version of this test only claimed to be. That
/// version asserted a literal list plus `required ⊆ known`. Both stay GREEN when
/// `HookEventKind` gains a case, so the bug it named — "the hub gaining an event
/// while the check keeps asking for the old five" — walked straight through it.
///
/// The assertion below is the converse, and that is the direction that catches a
/// new event: an unclassified case is neither required nor excluded, so it goes
/// RED until somebody decides which it is.
@Test func everyHookEventIsEitherRequiredOrDeliberatelyExcluded() {
    // Each exclusion carries the reason it is not required.
    //   PreCompact — `SessionHub.state(for:)` maps it to nil. It drives nothing.
    //   SessionEnd — optional. It retires a session as soon as it ends; the
    //                staleness timeout is the fallback when it is absent.
    //                Design §10.4.
    let excluded: Set<String> = ["PreCompact", "SessionEnd"]

    for kind in HookEventKind.allCases {
        let isRequired = HookHealth.requiredEvents.contains(kind.rawValue)
        let isExcluded = excluded.contains(kind.rawValue)
        #expect(isRequired || isExcluded,
                "\(kind.rawValue) is neither required nor a documented exclusion; classify it")
        #expect(!(isRequired && isExcluded),
                "\(kind.rawValue) is both required and excluded")
    }

    // An exclusion naming an event that does not exist is a stale waiver, and it
    // would quietly widen the list above.
    for name in excluded {
        #expect(HookEventKind(rawValue: name) != nil,
                "\(name) is excluded but is not a HookEventKind")
    }
}

@Test func theRequiredEventsAreTheOnesTheHubActsOn() {
    // The deliberate five, pinned as a literal so a change here is a decision
    // rather than a drift. The guard against an UNCLASSIFIED event lives in
    // `everyHookEventIsEitherRequiredOrDeliberatelyExcluded`; this one only
    // records what was chosen.
    #expect(HookHealth.requiredEvents ==
            ["PermissionDenied", "PostToolUse", "PreToolUse", "SessionStart", "Stop"])

    for event in HookHealth.requiredEvents {
        #expect(HookEventKind(rawValue: event) != nil,
                "\(event) is required but SessionHub does not know it")
    }
}

@Test func theRequiredEventsAreAlreadySorted() {
    // `status(ofSettings:)` filters this array, and a filter preserves order.
    // The sorted panel line therefore rests on THIS constant being sorted, so
    // the invariant is pinned where it actually lives rather than inferred from
    // the one call site downstream.
    #expect(HookHealth.requiredEvents == HookHealth.requiredEvents.sorted())
}
