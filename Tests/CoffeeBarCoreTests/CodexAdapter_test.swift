// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// Codex CLI shares Claude Code's envelope: the key is `hook_event_name` and the
// event names are the same PascalCase words. `HookEvent` therefore decodes a
// Codex payload unchanged, and the ONLY thing that makes a Codex session a Codex
// session is the origin its sender declared. See `AgentTool.declared(byEndpoint:)`.
//
// Every transition below is driven by a payload in `Tests/Fixtures/codex-hooks/`.
// Design §9: no transition may exist for an event with no recorded payload.

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private var codexFixtures: URL {
    URL(fileURLWithPath: #filePath)     // …/Tests/CoffeeBarCoreTests/CodexAdapter_test.swift
        .deletingLastPathComponent()    // …/Tests/CoffeeBarCoreTests
        .deletingLastPathComponent()    // …/Tests
        .appending(path: "Fixtures/codex-hooks")
}

private func codexNames() throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: codexFixtures.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
}

private func codex(_ name: String) throws -> HookEvent {
    try JSONDecoder().decode(
        HookEvent.self, from: Data(contentsOf: codexFixtures.appending(path: name)))
}

private func codexRaw(_ name: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(
        with: try Data(contentsOf: codexFixtures.appending(path: name)))
    return try #require(object as? [String: Any])
}

private func session(_ state: SessionState, id: String,
                     tool: AgentTool = .codex) -> AgentSession {
    AgentSession(tool: tool, sessionID: id, cwd: nil, repoName: nil, pid: nil,
                 state: state, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: nil, turnCount: 0)
}

private func codexSessionID() throws -> String {
    try codex("stop.json").sessionID
}

// MARK: - The corpus these transitions rest on

@Test func everyCodexTransitionRestsOnARecordedPayload() throws {
    // Named bug this catches: a Codex fixture renamed or deleted while the
    // transitions below keep passing against something else. The count is
    // asserted first, because a loop over an empty directory passes vacuously.
    let names = try codexNames()
    #expect(names.count == 6, "read \(names.count) Codex fixtures at \(codexFixtures.path); the capture recorded six")

    var recorded: [HookEventKind: String] = [:]
    for name in names {
        let event = try codex(name)
        let kind = try #require(event.kind,
                                "\(name) decodes to no HookEventKind; SessionHub would ignore it")
        recorded[kind] = name
    }

    let driven: [(HookEventKind, String)] = [
        (.sessionStart, "session-start.json"),
        (.userPromptSubmit, "user-prompt-submit.json"),
        (.preToolUse, "pre-tool-use.json"),
        (.postToolUse, "post-tool-use.json"),
        (.stop, "stop.json"),
        (.sessionEnd, "session-end.json"),
    ]
    for (kind, file) in driven {
        #expect(recorded[kind] == file,
                "no recorded Codex \(kind.rawValue) payload at \(file); its transition has no evidence")
    }
}

/// Codex sends no `PermissionDenied`, and that absence is load-bearing.
///
/// `HookHealth.requiredEvents(for: .codex)` leaves the event out. If a later
/// capture records one, this turns red and the advisory has to be revisited
/// rather than silently staying short.
@Test func noCodexPayloadCarriesAPermissionDenial() throws {
    for name in try codexNames() {
        #expect(try codex(name).kind != .permissionDenied,
                "\(name) is a Codex PermissionDenied; the advisory must now require it")
    }
}

// MARK: - The envelope really is shared

@Test func everyRecordedCodexPayloadDecodesAsAHookEvent() throws {
    // The claim the whole Codex adapter rests on: Codex needs no second
    // decoder. Named bug this catches: a Codex payload that silently fails to
    // decode, which the listener drops as a 400 while the panel looks healthy.
    let names = try codexNames()
    #expect(names.count == 6, "read \(names.count) fixtures; this loop would pass vacuously")

    for name in names {
        let event = try codex(name)
        #expect(!event.sessionID.isEmpty, "\(name) decoded an empty session id")
        #expect(!event.hookEventName.isEmpty, "\(name) decoded an empty event name")
    }
}

@Test func aBareStringToolResponseDoesNotBreakTheDecode() throws {
    // Codex sends `tool_response` as a STRING where Claude Code sends an object.
    // Named bug this catches: somebody adds a typed `tool_response` property to
    // `HookEvent` modelled on the Claude Code shape. Every Codex PostToolUse
    // would then fail to decode and the session would never leave `.working`,
    // holding the machine awake until the stale timeout.
    let raw = try codexRaw("post-tool-use.json")
    #expect(raw["tool_response"] is String,
            "the recorded Codex tool_response is no longer a bare string; this test no longer discriminates")

    let event = try codex("post-tool-use.json")
    #expect(event.kind == .postToolUse)
}

// MARK: - The declared origin decides the tool

@Test func aCodexPayloadBecomesACodexSession() throws {
    // The defect this replaces: `SessionHub` hardcoded `tool: .claudeCode`, so
    // every session was a Claude Code session whatever sent it.
    let out = SessionHub.apply(from: .codex, try codex("session-start.json"), to: [], now: t0)
    #expect(out.count == 1)
    #expect(out.first?.tool == .codex)
    #expect(out.first?.sessionID == (try codexSessionID()))
}

@Test func theSameEventUnderTwoOriginsMakesTwoSessions() throws {
    // Codex and Claude Code both use plain UUIDs for `session_id`, and the
    // recorded fixtures happen to carry the same redacted one. Keying by
    // sessionID alone would merge two different agents into one row.
    let event = try codex("stop.json")
    let asCodex = SessionHub.apply(from: .codex, event, to: [], now: t0)
    let both = SessionHub.apply(from: .claudeCode, event, to: asCodex, now: t0)

    #expect(both.count == 2)
    #expect(both.map(\.tool) == [.codex, .claudeCode])
    #expect(Set(both.map(\.id)).count == 2)
}

// MARK: - The mapping, driven by recorded payloads

@Test func codexSessionStartStartsASession() throws {
    let out = SessionHub.apply(from: .codex, try codex("session-start.json"), to: [], now: t0)
    #expect(out.first?.state == .starting)
}

@Test func codexToolUseIsWorking() throws {
    let sid = try codexSessionID()
    for name in ["pre-tool-use.json", "post-tool-use.json"] {
        let out = SessionHub.apply(from: .codex, try codex(name),
                                   to: [session(.awaitingInput, id: sid)], now: t0)
        #expect(out.first?.state == .working, "\(name) did not reach .working")
    }
}

@Test func codexStopWaitsForTheHuman() throws {
    let out = SessionHub.apply(from: .codex, try codex("stop.json"),
                               to: [session(.working, id: try codexSessionID())], now: t0)
    #expect(out.first?.state == .awaitingInput)
    #expect(out.first?.attentionSince == t0)
}

@Test func codexSessionEndRetiresTheSession() throws {
    let out = SessionHub.apply(from: .codex, try codex("session-end.json"),
                               to: [session(.working, id: try codexSessionID())], now: t0)
    #expect(out.first?.state == .done)
    #expect(out.first?.attentionSince == nil)
}

/// `UserPromptSubmit` hands the turn back to the agent.
///
/// Codex sends this event and Claude Code's `HookEventKind` had no case for it.
/// It is added because a REAL payload was recorded — `user-prompt-submit.json` —
/// and it maps to `.working`.
///
/// Named bug this catches: leaving the event unmapped. A Codex session sits in
/// `.awaitingInput` from the moment the user presses return until the model's
/// FIRST tool call. `.awaitingInput` does not hold the wake assertion, so the
/// machine can idle-sleep while the model is generating — which is exactly the
/// failure this product exists to prevent. A turn that answers in prose and
/// calls no tool at all never leaves that state.
@Test func codexUserPromptSubmitHandsTheTurnBackToTheAgent() throws {
    let out = SessionHub.apply(from: .codex, try codex("user-prompt-submit.json"),
                               to: [session(.awaitingInput, id: try codexSessionID())], now: t0)
    #expect(out.first?.state == .working)
    #expect(out.first?.attentionSince == nil,
            "the human is no longer the bottleneck, so the session must leave the attention list")

    // The state it moves to must be one that holds the machine awake, or the
    // transition buys nothing.
    #expect(PowerBroker.activeStates(holdAwakeWhileBlocked: false).contains(.working))
}

@Test func everyCodexEventRefreshesLastEventAt() throws {
    // Staleness is measured from `lastEventAt`. A Codex event that does not
    // refresh it makes a busy Codex session go stale mid-work.
    let later = t0.addingTimeInterval(120)
    let names = try codexNames()
    #expect(names.count == 6, "read \(names.count) fixtures; this loop would pass vacuously")

    for name in names {
        let out = SessionHub.apply(from: .codex, try codex(name),
                                   to: [session(.working, id: try codexSessionID())], now: later)
        #expect(out.first?.lastEventAt == later, "\(name) did not refresh lastEventAt")
    }
}
