// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which agent tool a session belongs to. Handoff §5.1.
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
    case cursor
}

// MARK: - How a payload's origin is decided

/// Where a hook payload came from, and how coffee-bar knows.
///
/// **The invariant: the origin is a property of the SENDER, not of the payload.**
/// The user wires each agent tool separately, in that tool's own configuration
/// file, by pasting a command coffee-bar gives them. The sender therefore knows
/// the origin with certainty at the moment it posts. The bytes it posts do not
/// carry that certainty, and this project measured why.
///
/// **Three ways to decide the origin were weighed. Two were measured and
/// rejected.**
///
/// 1. **The event-name vocabulary.** Rejected: Codex CLI sends the SAME event
///    names as Claude Code — `SessionStart`, `PreToolUse`, `PostToolUse`,
///    `Stop`, `SessionEnd` — in the same `hook_event_name` envelope. The
///    vocabulary separates Cursor, whose names are camelCase, from the other
///    two. It cannot separate the pair that matters.
///
/// 2. **A discriminating key in the payload.** Rejected, by measurement against
///    the recorded corpus: the Codex `SessionEnd` payload's key set is a strict
///    SUBSET of the Claude Code `SessionEnd` payload's. `model` and `turn_id`,
///    the two keys that ARE Codex-only elsewhere, are both absent from exactly
///    that payload, and Claude Code's `prompt_id` is absent from its own
///    `SessionStart`. So no key is present on every payload of one tool and
///    absent from every payload of the other.
///    `noPayloadKeyCanTellCodexFromClaudeCode` re-runs that measurement on every
///    build.
///
///    One field in the recorded payloads DOES separate the two totally, on all
///    twelve. It is the path to the conversation transcript, and design §7
///    forbids reading it — `PrivacyBoundary_test.swift` turns red if any file
///    under `Sources/` so much as names that key. **The only total payload
///    discriminator that exists is one this product may not look at.** That is
///    what closes off sniffing for good, rather than merely making it awkward.
///
/// 3. **The sender declares it. CHOSEN.** The declaration rides on the ingest
///    endpoint the hook command posts to, because that command is authored by
///    coffee-bar and pasted per tool. It needs no shim binary, no rewriting of
///    the payload, and no second thing for the user to keep in step.
///
/// **Why the legacy path keeps meaning Claude Code.** `/event` is what every
/// hook already installed posts to, and `docs/QUICKSTART.md` still prints it.
/// Retagging those sessions on upgrade would be a silent regression for the only
/// users this product has, so the legacy path is Claude Code's endpoint rather
/// than a default applied to unknown paths.
///
/// **Unknown paths resolve to no tool at all.** A misidentified origin drives
/// the wrong state machine silently, which is the whole failure this mechanism
/// exists to prevent, so a path coffee-bar does not recognise is refused instead
/// of guessed at.
///
/// **What this does NOT defend against.** Design §4.1 already states that any
/// process running as this user can post to the socket. Such a process can also
/// choose the endpoint, so the declaration is trusted exactly as far as the
/// socket's own access control reaches — no further, and no less.
extension AgentTool {

    /// The ingest endpoint whose payloads belong to this tool.
    ///
    /// A `switch` with no `default`, so adding a case to `AgentTool` fails to
    /// compile here rather than silently inheriting another tool's endpoint.
    public var ingestEndpoint: String {
        switch self {
        case .claudeCode: return "/event"
        case .codex: return "/event/codex"
        case .cursor: return "/event/cursor"
        }
    }

    /// The tool that declared itself by posting to `endpoint`, or `nil`.
    ///
    /// Matched exactly. No trailing slash is tolerated and no query string is
    /// stripped, because the only client is a command this project authors and
    /// the user pastes verbatim. Leniency here would buy nothing and would widen
    /// what counts as a declaration.
    public static func declared(byEndpoint endpoint: String) -> AgentTool? {
        allCases.first { $0.ingestEndpoint == endpoint }
    }
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
