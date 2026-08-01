// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// Distinct, easily distinguished values, so a swapped pair is visible.
private let policy = StalePolicy(workingTimeout: 100, blockedTimeout: 1000)

private func session(_ state: SessionState,
                     id: String = "s1",
                     lastEventAt: Date,
                     stateEnteredAt: Date = t0) -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: id, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: stateEnteredAt,
                 lastEventAt: lastEventAt, lastMessage: nil,
                 attentionSince: nil, turnCount: 0)
}

private func stateAfterExpiry(_ state: SessionState,
                              silentFor seconds: TimeInterval) -> SessionState? {
    SessionHub.expiring([session(state, lastEventAt: t0)],
                        now: t0.addingTimeInterval(seconds),
                        policy: policy).first?.state
}

// MARK: - Both sides of the working boundary

@Test func aWorkingSessionGoesStaleAtExactlyTheTimeout() {
    // The boundary itself. Named bug this catches: `>` where `>=` belongs. At
    // exactly the timeout the session keeps holding, and nothing else in this
    // file notices — the M1 battery floor shipped this defect twice.
    #expect(stateAfterExpiry(.working, silentFor: 100) == .stale)
}

@Test func aWorkingSessionOneSecondInsideTheTimeoutSurvives() {
    // The mirror. Named bug this catches: `>= timeout - 1`, or a comparison
    // that rounds. A working agent would be retired a second early, releasing
    // the assertion under an agent that is still running.
    #expect(stateAfterExpiry(.working, silentFor: 99) == .working)
}

@Test func aWorkingSessionOneSecondPastTheTimeoutIsStale() {
    #expect(stateAfterExpiry(.working, silentFor: 101) == .stale)
}

@Test func aFreshWorkingSessionIsNotTouched() {
    #expect(stateAfterExpiry(.working, silentFor: 0) == .working)
}

// MARK: - Both sides of the blocked boundary

@Test func aBlockedSessionOutlivesTheWorkingTimeout() {
    // Design §10.2: an `.awaitingInput` session may legitimately idle for
    // hours. Named bug this catches: the two timeouts swapped, which retires
    // every waiting session after the working timeout and empties the
    // attention list the moment the user steps away.
    #expect(stateAfterExpiry(.awaitingInput, silentFor: 500) == .awaitingInput)
    #expect(stateAfterExpiry(.awaitingPermission, silentFor: 500) == .awaitingPermission)
}

@Test func aBlockedSessionGoesStaleAtExactlyItsOwnTimeout() {
    #expect(stateAfterExpiry(.awaitingInput, silentFor: 1000) == .stale)
}

@Test func aBlockedSessionOneSecondInsideItsTimeoutSurvives() {
    #expect(stateAfterExpiry(.awaitingInput, silentFor: 999) == .awaitingInput)
}

@Test func aStartingSessionUsesTheWorkingTimeout() {
    // `.starting` holds the assertion, so it needs a timeout. Named bug this
    // catches: a switch that handles `.working` and lets `.starting` fall
    // through to never expiring — an agent that dies during startup then holds
    // the machine awake forever.
    #expect(stateAfterExpiry(.starting, silentFor: 100) == .stale)
    #expect(stateAfterExpiry(.starting, silentFor: 99) == .starting)
}

// MARK: - States that must not be re-expired

@Test func alreadyFinishedSessionsAreLeftAlone() {
    // `.done`, `.failed` and `.stale` hold nothing already. Rewriting them
    // would churn `stateEnteredAt` on every tick for no reason.
    for state in [SessionState.done, .failed, .stale] {
        #expect(stateAfterExpiry(state, silentFor: 100_000) == state)
    }
}

// MARK: - The measurement is from lastEventAt, not stateEnteredAt

@Test func aLongRunningSessionWithRecentEventsIsNotStale() {
    // Named bug this catches: expiry measured from `stateEnteredAt`. An agent
    // that has been `.working` for an hour, emitting a PreToolUse every few
    // seconds, is the NORMAL case this product exists for. Measuring from
    // `stateEnteredAt` drops the assertion under a perfectly healthy agent, and
    // every other test in this file stays green because they set the two
    // timestamps to the same instant.
    let now = t0.addingTimeInterval(3600)
    let busy = session(.working,
                       lastEventAt: now.addingTimeInterval(-10),
                       stateEnteredAt: t0)
    #expect(SessionHub.expiring([busy], now: now, policy: policy).first?.state == .working)
}

@Test func aBackwardClockDoesNotRetireAWorkingSession() {
    // `expiring` measures with `Date`, a WALL clock. An NTP correction, a manual
    // change or a VM restore steps it backwards, which leaves `lastEventAt`
    // future-dated and the elapsed time negative. Named bug this catches: an
    // `abs()` around the elapsed time — the obvious wrong way to "handle" clock
    // skew. It reads a one-hour backward step as an hour of silence and retires
    // a session whose agent is still running, which is the exact failure this
    // product exists to prevent. Staying alive is the fail-safe direction: a
    // backward step suspends expiry until the clock catches up, and a suspended
    // backstop is survivable where a dropped assertion is not.
    let live = session(.working, lastEventAt: t0)
    let now = t0.addingTimeInterval(-3600)
    #expect(SessionHub.expiring([live], now: now, policy: policy).first?.state == .working)
}

// MARK: - Ordering and identity survive expiry

@Test func expiryKeepsTheListOrderAndTouchesOnlyTheStaleOnes() {
    let now = t0.addingTimeInterval(200)
    let sessions = [session(.working, id: "a", lastEventAt: now),
                    session(.working, id: "b", lastEventAt: t0),
                    session(.working, id: "c", lastEventAt: now)]
    let out = SessionHub.expiring(sessions, now: now, policy: policy)
    #expect(out.map(\.sessionID) == ["a", "b", "c"])
    #expect(out.map(\.state) == [.working, .stale, .working])
}

@Test func expiringStampsStateEnteredAt() {
    let now = t0.addingTimeInterval(200)
    let out = SessionHub.expiring([session(.working, lastEventAt: t0)],
                                  now: now, policy: policy)
    #expect(out.first?.stateEnteredAt == now)
}

@Test func retiringASessionKeepsEveryFieldExceptTheThreeItRewrites() throws {
    // Retirement rebuilds the value field by field, and every other test here
    // reads `.state` alone. Named bug this catches: a dropped `repoName`, a
    // `turnCount` reset to 0, or a `lastEventAt` moved to `now`. The panel then
    // shows a nameless entry, and a `lastEventAt` of `now` makes the elapsed
    // time restart on the tick that retired the session.
    //
    // `attentionSince` is seeded non-nil on a `.working` session — an input the
    // production path does not produce — because a fixture that already holds
    // `nil` cannot see the clearing happen.
    let before = AgentSession(
        tool: .claudeCode, sessionID: "s1",
        cwd: URL(fileURLWithPath: "/tmp/repo", isDirectory: true),
        repoName: "repo", pid: 4242, state: .working,
        stateEnteredAt: t0, lastEventAt: t0, lastMessage: "why it stopped",
        attentionSince: t0, turnCount: 7)
    let now = t0.addingTimeInterval(100)
    let after = try #require(SessionHub.expiring([before], now: now, policy: policy).first)

    // The three fields retirement is allowed to rewrite.
    #expect(after.state == .stale)
    #expect(after.stateEnteredAt == now)
    // Design §14 orders the attention list by `attentionSince`. A retired
    // session waits on nobody, so it must not keep a place in that order.
    #expect(after.attentionSince == nil)

    // Everything else is carried through untouched.
    #expect(after.tool == .claudeCode)
    #expect(after.sessionID == "s1")
    #expect(after.cwd?.path == "/tmp/repo")
    #expect(after.repoName == "repo")
    #expect(after.pid == 4242)
    #expect(after.lastEventAt == t0)
    #expect(after.lastMessage == "why it stopped")
    #expect(after.turnCount == 7)
}

// MARK: - The safety property itself

@Test func aStaleWorkingSessionStopsHoldingTheAssertion() {
    // Design §5, end to end and composed rather than asserted twice. A crashed
    // agent leaves `.working` behind; only this path releases the machine.
    //
    // `userIntent: .auto` — "no explicit user request", which is the situation
    // a crashed agent leaves behind. The plan wrote `.stop` here, from before
    // `.auto` existed. Under the shipped broker `.stop` is an absolute veto
    // that answers `false` on both sides, so it would prove nothing about
    // expiry at all.
    let crashed = [session(.working, lastEventAt: t0)]
    let now = t0.addingTimeInterval(100)

    // Precondition: before expiry it DOES hold, so a broker stuck at false
    // cannot satisfy the assertion below.
    #expect(PowerBroker.decide(PowerInputs(
        sessions: crashed, powerSource: .ac, batteryPercent: 80,
        userIntent: .auto)).idleSleepAssertion == true)

    let expired = SessionHub.expiring(crashed, now: now, policy: policy)
    #expect(PowerBroker.decide(PowerInputs(
        sessions: expired, powerSource: .ac, batteryPercent: 80,
        userIntent: .auto)).idleSleepAssertion == false)
}

// MARK: - The declared defaults (design §10.2)

@Test func stalePolicyAppliesItsDocumentedDefaults() {
    // Every other test injects its own policy, so all of them are blind to the
    // shipped numbers: changing them leaves the file green. Design §10.2 marks
    // these as provisional, which is exactly why they need a test that sees
    // them. Pinned to literals, not to the type's own properties.
    #expect(StalePolicy.standard.workingTimeout == 900)
    #expect(StalePolicy.standard.blockedTimeout == 14_400)
    #expect(StalePolicy.standard.timeout(for: .starting) == 900)
    #expect(StalePolicy.standard.timeout(for: .awaitingPermission) == 14_400)
    #expect(StalePolicy.standard.timeout(for: .stale) == nil)
}

@Test func theWorkingTimeoutOutlivesTheLongestLegalToolCall() {
    // Claude Code documents Bash timeout max = 600_000 ms. Nothing fires
    // between PreToolUse and PostToolUse, so a working session must survive a
    // tool call of that length or the assertion drops mid-build.
    let longestDocumentedToolCall: TimeInterval = 600
    #expect(StalePolicy.standard.workingTimeout > longestDocumentedToolCall)
}
