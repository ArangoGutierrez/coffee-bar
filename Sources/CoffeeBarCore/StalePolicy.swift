// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How long a session may go silent before it is retired.
///
/// Design §5 makes this a SAFETY property, not a feature. The observed hook set
/// carries no reliable session-end signal, so a crashed or killed agent leaves
/// a `.working` session behind and would hold the machine awake forever. This
/// timeout is the only thing that retires it.
///
/// The two values differ because the two situations differ. An `.awaitingInput`
/// session may legitimately idle for hours while the human is at lunch. A
/// `.working` one going quiet for minutes is a dead process.
///
/// `workingTimeout` has a hard floor. Nothing fires between `PreToolUse` and
/// `PostToolUse`, so one tool call is a silent gap of its own full length.
/// Claude Code documents a maximum Bash timeout of 600_000 ms, which is 600 s.
/// Any value at or below 600 therefore retires a HEALTHY session in the middle
/// of a long build: the assertion drops and the Mac idle-sleeps during the
/// agent's longest operation, which is the exact failure this product prevents.
/// 900 clears that ceiling with margin.
///
/// Design §10.2 records both numbers as PROVISIONAL.
public struct StalePolicy: Equatable, Sendable {
    public let workingTimeout: TimeInterval
    public let blockedTimeout: TimeInterval

    public static let standard = StalePolicy(workingTimeout: 900,
                                             blockedTimeout: 14_400)

    public init(workingTimeout: TimeInterval, blockedTimeout: TimeInterval) {
        self.workingTimeout = workingTimeout
        self.blockedTimeout = blockedTimeout
    }

    /// `nil` for a state that holds nothing already, so expiry leaves it alone
    /// rather than churning `stateEnteredAt` on every tick.
    public func timeout(for state: SessionState) -> TimeInterval? {
        switch state {
        case .starting, .working:
            return workingTimeout
        case .awaitingPermission, .awaitingInput:
            return blockedTimeout
        case .done, .failed, .stale:
            return nil
        }
    }
}

extension SessionHub {

    /// Retires every session that has gone silent for longer than its timeout.
    ///
    /// Design §5 requires this to run on a TIMER, not only when the next event
    /// arrives: an agent that dies sends nothing, so nothing would ever notice.
    /// `ServingModel.refresh()` is that timer, and it is the existing one — the
    /// design forbids a second timer discipline.
    ///
    /// The elapsed time is measured from `lastEventAt`, never from
    /// `stateEnteredAt`. A healthy agent stays `.working` for hours while
    /// emitting an event every few seconds, and measuring from `stateEnteredAt`
    /// would drop the assertion underneath it.
    public static func expiring(_ sessions: [AgentSession],
                                now: Date,
                                policy: StalePolicy = .standard) -> [AgentSession] {
        sessions.map { session in
            guard let timeout = policy.timeout(for: session.state),
                  // `>=` so that exactly the timeout retires the session. Both
                  // sides of this boundary are guarded by tests: M1 shipped two
                  // defects where only one side of a comparison was covered.
                  //
                  // `now` is a WALL clock, so a backward step — NTP correction,
                  // manual change, VM restore — leaves this difference NEGATIVE.
                  // That deliberately compares false: expiry suspends until the
                  // clock catches up and the session stays alive. Keeping a dead
                  // session is survivable; dropping the assertion under a live
                  // agent is not. Do NOT "fix" the sign with `abs()`, which
                  // reads a backward step as silence and retires a running
                  // agent. Clamping to 0 is not a fix either: 0 is below every
                  // shipping timeout, so it changes no outcome. Expiry that
                  // survives a clock step needs a monotonic source, not
                  // arithmetic here.
                  now.timeIntervalSince(session.lastEventAt) >= timeout
            else { return session }

            return AgentSession(
                tool: session.tool,
                sessionID: session.sessionID,
                cwd: session.cwd,
                repoName: session.repoName,
                pid: session.pid,
                state: .stale,
                stateEnteredAt: now,
                lastEventAt: session.lastEventAt,
                lastMessage: session.lastMessage,
                attentionSince: nil,
                turnCount: session.turnCount)
        }
    }
}
