// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let retentionLimit = 256
private let retentionBase = Date(timeIntervalSince1970: 2_000_000)

private func retentionSession(_ id: String,
                              state: SessionState,
                              enteredAt: Date,
                              lastEventAt: Date) -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: id, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: enteredAt,
                 lastEventAt: lastEventAt, lastMessage: nil,
                 attentionSince: nil, turnCount: 0)
}

@Test func applyKeepsTheNewest256TerminalSessionsAndPreservesActiveWork() {
    let active = retentionSession("older-active", state: .working,
                                  enteredAt: retentionBase,
                                  lastEventAt: retentionBase)
    var sessions = [active]

    for index in 0..<1_000 {
        let now = retentionBase.addingTimeInterval(Double(index + 1))
        sessions = SessionHub.apply(
            from: .claudeCode,
            HookEvent(hookEventName: "SessionEnd", sessionID: "done-\(index)"),
            to: sessions, now: now)
    }

    #expect(sessions.count == retentionLimit + 1)
    #expect(sessions.first == active)
    #expect(sessions.dropFirst().map(\.sessionID)
            == (744..<1_000).map { "done-\($0)" })
    #expect(sessions.dropFirst().map(\.stateEnteredAt)
            == (744..<1_000).map { retentionBase.addingTimeInterval(Double($0 + 1)) })
    #expect(sessions.dropFirst().allSatisfy { $0.lastMessage == nil })
}

@Test func expirationKeepsActiveSessionsAndTheNewestStaleEntries() {
    let active = retentionSession("older-active", state: .working,
                                  enteredAt: retentionBase,
                                  lastEventAt: retentionBase.addingTimeInterval(2_000))
    let stale = (0..<1_000).reversed().map { index in
        retentionSession("stale-\(index)", state: .working,
                         enteredAt: retentionBase,
                         lastEventAt: retentionBase.addingTimeInterval(Double(index)))
    }
    let now = retentionBase.addingTimeInterval(2_000)

    let sessions = SessionHub.expiring([active] + stale, now: now,
                                       policy: StalePolicy(workingTimeout: 900,
                                                           blockedTimeout: 900))

    #expect(sessions.count == retentionLimit + 1)
    #expect(sessions.first?.sessionID == "older-active")
    #expect(sessions.first?.state == .working)
    #expect(sessions.dropFirst().map(\.sessionID)
            == (744..<1_000).reversed().map { "stale-\($0)" })
    #expect(sessions.dropFirst().allSatisfy { $0.state == .stale })
    #expect(sessions.dropFirst().allSatisfy { $0.stateEnteredAt == now })
    #expect(sessions.dropFirst().map(\.lastEventAt)
            == (744..<1_000).reversed().map {
                retentionBase.addingTimeInterval(Double($0))
            })
}

@Test func anEvictedTerminalIDCanStartAWorkingSessionAgain() {
    var sessions: [AgentSession] = []
    for index in 0...retentionLimit {
        sessions = SessionHub.apply(
            from: .claudeCode,
            HookEvent(hookEventName: "SessionEnd", sessionID: "done-\(index)"),
            to: sessions,
            now: retentionBase.addingTimeInterval(Double(index)))
    }
    #expect(!sessions.contains { $0.sessionID == "done-0" })

    sessions = SessionHub.apply(
        from: .claudeCode,
        HookEvent(hookEventName: "PreToolUse", sessionID: "done-0"),
        to: sessions, now: retentionBase.addingTimeInterval(1_000))

    #expect(sessions.count == retentionLimit + 1)
    #expect(sessions.last?.sessionID == "done-0")
    #expect(sessions.last?.state == .working)
    #expect(sessions.last?.stateEnteredAt == retentionBase.addingTimeInterval(1_000))
    #expect(sessions.last?.lastEventAt == retentionBase.addingTimeInterval(1_000))
}

@Test func failedSessionsShareTheTerminalHistoryLimit() {
    let sessions = (0..<300).map { index in
        retentionSession("failed-\(index)", state: .failed,
                         enteredAt: retentionBase.addingTimeInterval(Double(index)),
                         lastEventAt: retentionBase.addingTimeInterval(Double(index)))
    }
    let compacted = SessionHub.compacted(sessions)
    #expect(compacted.count == retentionLimit)
    #expect(compacted.map(\.sessionID) == (44..<300).map { "failed-\($0)" })
}
