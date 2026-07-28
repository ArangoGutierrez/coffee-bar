// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func session(tool: AgentTool = .claudeCode,
                     sessionID: String = "abc123",
                     state: SessionState = .working) -> AgentSession {
    AgentSession(tool: tool, sessionID: sessionID, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: nil, turnCount: 0)
}

/// A session with every optional populated, expressed as bytes rather than as
/// a Swift value. Encoding and decoding with the same type pins no key name at
/// all, so the contract has to start from a literal.
private let wireFixture = """
{
  "tool": "codex",
  "sessionID": "01JQ8ZK9",
  "cwd": "file:///Users/carlos/src/coffee-bar",
  "repoName": "coffee-bar",
  "pid": 4242,
  "state": "awaitingPermission",
  "stateEnteredAt": 800000000,
  "lastEventAt": 800000060,
  "lastMessage": "May I run git push?",
  "attentionSince": 800000030,
  "turnCount": 7
}
"""

/// The same fixture with one state substituted, for the per-state wire check.
private func wireFixture(state: String) -> Data {
    Data("""
    {
      "tool": "codex",
      "sessionID": "01JQ8ZK9",
      "cwd": "file:///Users/carlos/src/coffee-bar",
      "repoName": "coffee-bar",
      "pid": 4242,
      "state": "\(state)",
      "stateEnteredAt": 800000000,
      "lastEventAt": 800000060,
      "lastMessage": "May I run git push?",
      "attentionSince": 800000030,
      "turnCount": 7
    }
    """.utf8)
}

@Test func idIsToolAndSessionJoinedByAColon() {
    // Handoff §5.1: sessions are keyed by (tool, sessionID). A collision
    // between two tools' identically-named sessions would merge two users'
    // sessions into one row.
    #expect(session(tool: .codex, sessionID: "xyz").id == "codex:xyz")
}

@Test func differentToolsWithTheSameSessionIDDoNotCollide() {
    #expect(session(tool: .claudeCode, sessionID: "same").id
            != session(tool: .cursor, sessionID: "same").id)
}

@Test func aFullyPopulatedSessionMatchesTheWireFixture() throws {
    // The wire format is the M2 ingest contract: M2 writes these bytes and the
    // app reads them back after a restart. Every JSON key, the URL spelling and
    // the Date representation are pinned by the literal above, so a CodingKeys
    // rename or a changed date strategy fails here. Every optional carries a
    // real value, so URL, pid_t and the two optional Dates are exercised.
    let expected = AgentSession(
        tool: .codex,
        sessionID: "01JQ8ZK9",
        cwd: URL(fileURLWithPath: "/Users/carlos/src/coffee-bar"),
        repoName: "coffee-bar",
        pid: 4242,
        state: .awaitingPermission,
        stateEnteredAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
        lastEventAt: Date(timeIntervalSinceReferenceDate: 800_000_060),
        lastMessage: "May I run git push?",
        attentionSince: Date(timeIntervalSinceReferenceDate: 800_000_030),
        turnCount: 7)

    let decoded = try JSONDecoder().decode(AgentSession.self,
                                           from: Data(wireFixture.utf8))
    #expect(decoded == expected)

    // The app also writes sessions, so a lossy encoder must fail here too.
    let reencoded = try JSONDecoder().decode(AgentSession.self,
                                             from: JSONEncoder().encode(expected))
    #expect(reencoded == expected)
}

@Test func everySessionStateDecodesFromItsPinnedWireString() throws {
    // A stored session written under any of the seven states must still load.
    // Comparing against `allCases` also fails when an eighth case is added
    // without a wire string, which the fixture list would otherwise miss.
    let wireStates = ["starting", "working", "awaitingPermission",
                      "awaitingInput", "done", "failed", "stale"]
    let decoded = try wireStates.map {
        try JSONDecoder().decode(AgentSession.self, from: wireFixture(state: $0)).state
    }
    #expect(decoded == SessionState.allCases)
}

@Test func sessionStateRawValuesArePinned() {
    // Pinned to literals, not to the enum, so renaming a case fails here
    // rather than silently changing the persisted format. Comparing the whole
    // of `allCases` also catches an added, removed or reordered case.
    #expect(SessionState.allCases.map(\.rawValue) == [
        "starting",
        "working",
        "awaitingPermission",
        "awaitingInput",
        "done",
        "failed",
        "stale",
    ])
}

@Test func agentToolRawValuesArePinned() {
    // `AgentTool.rawValue` is the first half of the persisted id, so renaming
    // a case orphans every session row the app already stored.
    #expect(AgentTool.allCases.map(\.rawValue) == [
        "claudeCode",
        "codex",
        "cursor",
    ])
}
