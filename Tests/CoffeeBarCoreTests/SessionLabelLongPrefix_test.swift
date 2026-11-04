// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import CoffeeBarCore

@Test func longSessionPrefixesRemainDistinct() {
    let prefix = String(repeating: "a", count: 20_000)
    let ids = [prefix, prefix + "b", prefix + "c"]
    let sessions = ids.map { id in
        AgentSession(tool: .claudeCode, sessionID: id,
                     cwd: URL(fileURLWithPath: "/tmp/repo"), repoName: "repo",
                     pid: nil, state: .awaitingInput, stateEnteredAt: .distantPast,
                     lastEventAt: .distantPast, lastMessage: nil,
                     attentionSince: .distantPast, turnCount: 1)
    }
    let names = SessionLabel.rowNames(for: sessions)
    #expect(names.count == 3)
    for session in sessions {
        #expect(names[session.id] == "claude · repo (\(session.sessionID))")
    }
}
