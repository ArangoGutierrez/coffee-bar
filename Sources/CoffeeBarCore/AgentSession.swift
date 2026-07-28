// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which agent tool a session belongs to. Handoff §5.1.
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
    case cursor
}

/// The seven session states from handoff §5.1.
///
/// `awaitingPermission` and `awaitingInput` are the ATTENTION states — the
/// agent is blocked on the human. They do not hold the wake assertion unless
/// `holdAwakeWhileBlocked` is set, because staying awake while waiting on a
/// person burns battery for nothing.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case starting
    case working
    case awaitingPermission
    case awaitingInput
    case done
    case failed
    case stale
}

/// One agent conversation. Handoff §5.1.
///
/// M1 never constructs one of these outside a test: there is no ingest until
/// M2. The type exists now so M2 adds a producer rather than reshaping every
/// consumer.
public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public let tool: AgentTool
    public let sessionID: String
    public let cwd: URL?
    public let repoName: String?
    public let pid: pid_t?
    public let state: SessionState
    public let stateEnteredAt: Date
    public let lastEventAt: Date
    public let lastMessage: String?
    public let attentionSince: Date?
    public let turnCount: Int

    /// Keyed by (tool, sessionID) per §5.1 — two tools may use the same
    /// session id and must not merge.
    public var id: String { "\(tool.rawValue):\(sessionID)" }

    public init(tool: AgentTool, sessionID: String, cwd: URL?, repoName: String?,
                pid: pid_t?, state: SessionState, stateEnteredAt: Date,
                lastEventAt: Date, lastMessage: String?, attentionSince: Date?,
                turnCount: Int) {
        self.tool = tool
        self.sessionID = sessionID
        self.cwd = cwd
        self.repoName = repoName
        self.pid = pid
        self.state = state
        self.stateEnteredAt = stateEnteredAt
        self.lastEventAt = lastEventAt
        self.lastMessage = lastMessage
        self.attentionSince = attentionSince
        self.turnCount = turnCount
    }
}
