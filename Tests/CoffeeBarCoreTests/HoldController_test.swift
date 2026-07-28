// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func session(_ state: SessionState) -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: "s", cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: nil, turnCount: 0)
}

@Test func aFreshControllerIsNotServing() {
    var c = HoldController()
    #expect(c.intent == .stop)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 80).idleSleepAssertion == false)
}

@Test func togglingOnHolds() {
    var c = HoldController()
    c.userToggled(to: .serve)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 80).idleSleepAssertion == true)
}

@Test func recoveringBatteryDoesNotReArmTheHold() {
    // The whole point of the latch. 21 -> 20 -> 21 must release exactly once
    // and must NOT come back on by itself: re-arming is a behaviour the user
    // did not ask for and cannot see coming.
    var c = HoldController()
    c.userToggled(to: .serve)

    #expect(c.evaluate(powerSource: .battery, batteryPercent: 21).idleSleepAssertion == true)

    let atFloor = c.evaluate(powerSource: .battery, batteryPercent: 20)
    #expect(atFloor.idleSleepAssertion == false)
    #expect(atFloor.suppression == .batteryFloor(percent: 20, floor: 20))

    let recovered = c.evaluate(powerSource: .battery, batteryPercent: 21)
    #expect(recovered.idleSleepAssertion == false)
    #expect(c.intent == .stop)
}

@Test func returningToACDoesNotReArmTheHoldEither() {
    var c = HoldController()
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 10)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 10).idleSleepAssertion == false)
}

@Test func theUserCanReArmByTogglingAgain() {
    var c = HoldController()
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 10)
    #expect(c.intent == .stop)

    c.userToggled(to: .serve)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 90).idleSleepAssertion == true)
}

@Test func togglingOnBelowTheFloorIsRefusedAndReported() {
    var c = HoldController()
    c.userToggled(to: .serve)
    let out = c.evaluate(powerSource: .battery, batteryPercent: 5)
    #expect(out.idleSleepAssertion == false)
    #expect(out.suppression == .batteryFloor(percent: 5, floor: 20))
    #expect(c.intent == .stop)
}

@Test func theSuppressionReasonSurvivesForTheUIToRead() {
    // The UI renders `lastSuppression`. If it were cleared on the next
    // evaluate, the panel would flash the reason and lose it.
    var c = HoldController()
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 12)
    _ = c.evaluate(powerSource: .ac, batteryPercent: 90)
    #expect(c.lastSuppression == .batteryFloor(percent: 12, floor: 20))
}

@Test func evaluateForwardsTheSessionsAndTheKnobToTheBroker() {
    // `sessions` and `holdAwakeWhileBlocked` are pass-throughs, and a dropped
    // pass-through is invisible while M1 never supplies a session. Named bug
    // this catches: `evaluate` hard-coding `sessions: []` and
    // `holdAwakeWhileBlocked: false` into the `PowerInputs` it builds. Every
    // other test in this file stays green, and the defect surfaces in M2 as
    // "an active agent session never holds the machine awake".
    //
    // Design spec §6 permits this: it reads the wake predicate for a session
    // in a known state. It asserts no transition between states.
    var c = HoldController()

    // Intent is never toggled, so a hold here can only come from the session.
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 80,
                       sessions: [session(.working)]).idleSleepAssertion == true)

    // The knob is the only thing that flips a blocked state, so this proves
    // the knob arrives at the broker rather than being defaulted away.
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 80,
                       sessions: [session(.awaitingPermission)],
                       holdAwakeWhileBlocked: false).idleSleepAssertion == false)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 80,
                       sessions: [session(.awaitingPermission)],
                       holdAwakeWhileBlocked: true).idleSleepAssertion == true)
}

@Test func togglingOnClearsTheStaleSuppressionReason() {
    var c = HoldController()
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 12)
    c.userToggled(to: .serve)
    #expect(c.lastSuppression == nil)
}
