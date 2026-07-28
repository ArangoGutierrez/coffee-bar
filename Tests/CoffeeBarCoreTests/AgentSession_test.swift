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

@Test func allSevenSessionStatesRoundTripThroughCoding() throws {
    // The wire format is the M2 ingest contract. A renamed case silently
    // breaks decoding of a session the app already stored.
    for state in [SessionState.starting, .working, .awaitingPermission,
                  .awaitingInput, .done, .failed, .stale] {
        let data = try JSONEncoder().encode(session(state: state))
        let back = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(back.state == state)
    }
}

@Test func sessionStateRawValuesArePinned() {
    // Pinned to literals, not to the enum, so renaming a case fails here
    // rather than silently changing the persisted format.
    #expect(SessionState.awaitingPermission.rawValue == "awaitingPermission")
    #expect(SessionState.awaitingInput.rawValue == "awaitingInput")
    #expect(SessionState.stale.rawValue == "stale")
}
