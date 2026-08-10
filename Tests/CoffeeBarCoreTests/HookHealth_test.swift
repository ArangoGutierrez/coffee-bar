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

/// Every event the hub knows is either required or a documented exclusion —
/// **per agent tool**.
///
/// This is the guard the earliest version of this test only claimed to be. That
/// version asserted a literal list plus `required ⊆ known`. Both stay GREEN when
/// `HookEventKind` gains a case, so the bug it named — "the hub gaining an event
/// while the check keeps asking for the old five" — walked straight through it.
///
/// The assertion below is the converse, and that is the direction that catches a
/// new event: an unclassified case is neither required nor excluded, so it goes
/// RED until somebody decides which it is. It caught `UserPromptSubmit` on the
/// commit that added it.
///
/// It now runs once per tool that has an advisory, because the two tools sharing
/// this vocabulary do NOT need the same entries wired.
private let toolExclusions: [AgentTool: Set<String>] = [
    // PreCompact — `SessionHub.state(for:)` maps it to nil. It drives nothing.
    // SessionEnd — optional. It retires a session as soon as it ends; the
    //              staleness timeout is the fallback when it is absent.
    //              Design §10.4.
    // UserPromptSubmit — Claude Code sends it, but NO Claude Code payload for it
    //              was ever captured. The transition rests on the Codex capture,
    //              so a Claude Code user is not asked to wire an event this
    //              project has never seen that tool send.
    .claudeCode: ["PreCompact", "SessionEnd", "UserPromptSubmit"],

    // PermissionDenied — no Codex payload carries one, and
    //              `noCodexPayloadCarriesAPermissionDenial` re-checks that every
    //              build. Requiring an entry the tool may never send would leave
    //              the advisory permanently red with nothing the user could do.
    .codex: ["PreCompact", "SessionEnd", "PermissionDenied"],

    // sessionEnd — the same optional terminator as the other two tools'.
    //              Cursor's four events with no recorded payload are not listed
    //              here at all: `CursorEventKind` has no case for them, so there
    //              is nothing to classify. That is the stronger position.
    .cursor: ["sessionEnd"],
]

/// The wire names the hub can act on for `tool`.
///
/// Read from the tool's own vocabulary, because Cursor does not share Claude
/// Code's. Comparing a Cursor advisory against `HookEventKind` would find every
/// entry unclassified and say nothing true.
private func vocabulary(of tool: AgentTool) -> [String] {
    switch tool {
    case .claudeCode, .codex: return HookEventKind.allCases.map(\.rawValue)
    case .cursor: return CursorEventKind.allCases.map(\.rawValue)
    }
}

@Test(arguments: toolExclusions.keys.sorted { $0.rawValue < $1.rawValue })
func everyHookEventIsEitherRequiredOrDeliberatelyExcluded(_ tool: AgentTool) throws {
    let required = try #require(HookHealth.requiredEvents(for: tool),
                                "\(tool.rawValue) has no advisory but is listed with exclusions")
    let excluded = try #require(toolExclusions[tool])
    let known = vocabulary(of: tool)
    #expect(known.count >= 6, "\(tool.rawValue) has \(known.count) known events; this loop would be thin")

    for name in known {
        let isRequired = required.contains(name)
        let isExcluded = excluded.contains(name)
        #expect(isRequired || isExcluded,
                "\(name) is neither required nor a documented exclusion for \(tool.rawValue); classify it")
        #expect(!(isRequired && isExcluded),
                "\(name) is both required and excluded for \(tool.rawValue)")
    }

    // An exclusion naming an event that does not exist is a stale waiver, and it
    // would quietly widen the list above.
    for name in excluded {
        #expect(known.contains(name),
                "\(name) is excluded for \(tool.rawValue) but is not one of its events")
    }

    // Every required entry must be one the hub can actually act on.
    for name in required {
        #expect(known.contains(name),
                "\(tool.rawValue) requires \(name), which is not in its vocabulary")
    }
}

/// The advisory may only ask for events this project has actually recorded.
///
/// The rule that governs the whole adapter effort, applied to the panel's own
/// advice: coffee-bar must not tell a user to wire an entry it has never seen
/// their tool send. Named bug this catches: an event copied from one tool's list
/// into another's because the vocabulary looks the same. `PermissionDenied` is
/// exactly that trap — it is real for Claude Code and unrecorded for Codex.
@Test(arguments: AgentTool.allCases)
func everyRequiredEventHasARecordedPayloadForThatTool(_ tool: AgentTool) throws {
    let corpus: String
    switch tool {
    case .claudeCode: corpus = "claude-hooks"
    case .codex: corpus = "codex-hooks"
    case .cursor: corpus = "cursor-hooks"
    }
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(corpus)")

    let names = try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasSuffix(".json") }
    #expect(names.count == 6,
            "read \(names.count) fixtures at \(directory.path); the checks below would be vacuous")

    var recorded: Set<String> = []
    for name in names {
        let object = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: directory.appending(path: name)))
        let payload = try #require(object as? [String: Any])
        let event = try #require(payload["hook_event_name"] as? String,
                                 "\(name) carries no hook_event_name")
        recorded.insert(event)
    }

    let required = try #require(HookHealth.requiredEvents(for: tool))
    for event in required {
        #expect(recorded.contains(event),
                "\(tool.rawValue) requires \(event), but no payload for it exists in \(directory.lastPathComponent). Recorded: \(recorded.sorted())")
    }
}

@Test func theClaudeCodeAdvisoryIsTheConstantTheDocumentsAreCheckedAgainst() {
    // `DocsClaims_test` and `SiteClaims_test` both read `HookHealth`
    // `.requiredEvents`. Named bug this catches: the per-tool function and the
    // constant drifting apart, which would let the documented block and the
    // advisory the panel prints disagree while both guards stayed green.
    #expect(HookHealth.requiredEvents(for: .claudeCode) == HookHealth.requiredEvents)
}

@Test func everyAdvisoryAsksForSomethingAndIsAlreadySorted() {
    // All three tools have an advisory today. The optional return stays the way
    // to say "no advice": `nil` and `[]` are different claims, and an empty list
    // would make a filter match everything and report `.wired` for a check that
    // never ran.
    //
    // Sorted matters because `status(ofSettings:)` filters the array and a
    // filter preserves order, so the panel's line rests on the source list.
    for tool in AgentTool.allCases {
        if let events = HookHealth.requiredEvents(for: tool) {
            #expect(!events.isEmpty, "\(tool.rawValue) has an advisory that asks for nothing")
            #expect(events == events.sorted(), "\(tool.rawValue)'s advisory is not sorted")
        }
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

/// A tool event with no `matcher` cannot fire, so it is not wired.
///
/// Issue #55, and it is not hypothetical: `~/.codex/hooks.json` was merged
/// without matchers on 2026-08-06 and the panel reported Codex healthy for a
/// day while no Codex tool event reached the ingest socket. The check was the
/// reason nobody noticed — it actively said the thing was working.
@Test func aToolEventWithoutAMatcherIsNotWired() throws {
    let json = """
    {"hooks":{
      "PreToolUse":[{"hooks":[{"command":"coffeebar-hook ingest"}]}],
      "PostToolUse":[{"matcher":"*","hooks":[{"command":"coffeebar-hook ingest"}]}],
      "SessionStart":[{"hooks":[{"command":"coffeebar-hook ingest"}]}],
      "Stop":[{"hooks":[{"command":"coffeebar-hook ingest"}]}],
      "UserPromptSubmit":[{"hooks":[{"command":"coffeebar-hook ingest"}]}]
    }}
    """
    let status = HookHealth.status(of: Data(json.utf8), for: .codex)
    #expect(status == .missing(["PreToolUse"]),
            "PreToolUse has no matcher and cannot fire, but the verdict is \(String(describing: status))")
}

/// The mirror: a lifecycle event must NOT carry one.
@Test func aLifecycleEventWithAMatcherIsNotWired() throws {
    // Named bug: enforcing "matcher present" everywhere instead of "present on
    // exactly the two tool events". That would accept a file the tool does not
    // run and is the same false-healthy failure in the other direction.
    let json = """
    {"hooks":{
      "PreToolUse":[{"matcher":"*","hooks":[{"command":"coffeebar-hook ingest"}]}],
      "PostToolUse":[{"matcher":"*","hooks":[{"command":"coffeebar-hook ingest"}]}],
      "SessionStart":[{"matcher":"*","hooks":[{"command":"coffeebar-hook ingest"}]}],
      "Stop":[{"hooks":[{"command":"coffeebar-hook ingest"}]}],
      "UserPromptSubmit":[{"hooks":[{"command":"coffeebar-hook ingest"}]}]
    }}
    """
    let status = HookHealth.status(of: Data(json.utf8), for: .codex)
    #expect(status == .missing(["SessionStart"]),
            "SessionStart carries a matcher it must not have, but the verdict is \(String(describing: status))")
}

/// The correct file still passes, or the rule is unusable.
@Test func theShapeQuickstartTeachesIsWired() throws {
    let json = """
    {"hooks":{
      "PreToolUse":[{"matcher":"*","hooks":[{"command":"coffeebar-hook ingest"}]}],
      "PostToolUse":[{"matcher":"*","hooks":[{"command":"coffeebar-hook ingest"}]}],
      "SessionStart":[{"hooks":[{"command":"coffeebar-hook ingest"}]}],
      "Stop":[{"hooks":[{"command":"coffeebar-hook ingest"}]}],
      "UserPromptSubmit":[{"hooks":[{"command":"coffeebar-hook ingest"}]}]
    }}
    """
    #expect(HookHealth.status(of: Data(json.utf8), for: .codex) == .wired)
}
