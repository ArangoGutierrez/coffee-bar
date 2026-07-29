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

@Test func aFreshControllerIsOnAutoAndHoldsNothingYet() {
    // `.auto` is the default from M2 on — the product follows the agent
    // sessions until the user says otherwise. It was `.stop`, which now means
    // an explicit veto and would ship a product that ignores every session
    // until the user finds the control.
    //
    // The second expectation is what keeps `.auto` honest: with no sessions it
    // still holds nothing. A `.auto` that fell through to a hold would pin a
    // laptop awake from first launch, before the user had touched anything.
    var c = HoldController()
    #expect(c.intent == .auto)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 80).idleSleepAssertion == false)

    // And it follows a session the moment there is one, which is what makes
    // the case `.auto` rather than a differently-spelled `.stop`.
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 80,
                       sessions: [session(.working)]).idleSleepAssertion == true)
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

@Test func theLatchDoesNotFireUnderAuto() {
    // The mirror of `recoveringBatteryDoesNotReArmTheHold`, and the reason the
    // latch had to be narrowed rather than left alone.
    //
    // The latch drops the intent to `.stop` so that a recovering battery cannot
    // silently re-arm a hold. Under `.serve` that is right: the user asked
    // once, the floor overrode it, and re-arming is a behaviour they did not
    // ask for and cannot see coming. Under `.auto` it is fatal. `.auto` is a
    // CONTINUOUS instruction, not a one-off request, and `PowerBroker` re-reads
    // the floor on every single call — so latching buys nothing and costs the
    // whole feature.
    //
    // Named bug this catches: the M1 `intent = .stop` on any suppression. One
    // dip below the floor pins the intent to `.stop` for the life of the
    // process. Every later session is ignored, the product is dead, and
    // `ServingModel.reason(_:stillTrueOf:)` hides the battery line as soon as
    // the reading recovers — so the panel shows a disabled app and no reason.
    // The user's only cure is to quit and relaunch.
    var c = HoldController()
    c.userToggled(to: .auto)
    let working = [session(.working)]

    // Precondition: `.auto` is genuinely holding, so the release below is a
    // release and not a hold that never started.
    #expect(c.evaluate(powerSource: .battery, batteryPercent: 21,
                       sessions: working).idleSleepAssertion == true)

    let atFloor = c.evaluate(powerSource: .battery, batteryPercent: 20, sessions: working)
    #expect(atFloor.idleSleepAssertion == false)
    #expect(atFloor.suppression == .batteryFloor(percent: 20, floor: 20))

    // The intent SURVIVES the suppression. This is the assertion the M1 latch
    // fails: it reads `.stop` there.
    #expect(c.intent == .auto, "a floor suppression latched the intent away from .auto")

    // And the hold comes back on its own once the reading recovers, with no
    // user action at all. Without this the expectation above could hold for a
    // controller that keeps the label `.auto` while some other piece of state
    // stays latched off.
    let recovered = c.evaluate(powerSource: .battery, batteryPercent: 21, sessions: working)
    #expect(recovered.idleSleepAssertion == true,
            "Auto never recovered after one dip below the floor")
    #expect(c.intent == .auto)
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

    // Intent is never toggled, so a hold here can only come from the session:
    // the default `.auto` contributes nothing of its own.
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
    // Prove the precondition: without a stale reason to clear, the assertion
    // below would hold for a controller that never sets `lastSuppression`.
    #expect(c.lastSuppression != nil)
    c.userToggled(to: .serve)
    #expect(c.lastSuppression == nil)
}

@Test func togglingOffStopsTheHoldAndKeepsTheReason() {
    // `.stop` is how the user switches serving off: `ServingModel.intent`
    // forwards the panel's Off position to `userToggled(to: .stop)`. It is a
    // deliberate veto, not the absence of a request — that is `.auto` — so it
    // is the one position this test must keep passing.
    //
    // Named bug 1: `userToggled` ignoring its argument and always arming
    // (`self.intent = .serve`). The off switch is then dead — the user can
    // start serving but can never stop.
    // Named bug 2: `userToggled` clearing `lastSuppression` unconditionally
    // rather than only on `.serve`. Flipping the switch off then wipes the
    // panel's explanation of a release the user has not yet read.
    var c = HoldController()
    c.userToggled(to: .serve)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 90).idleSleepAssertion == true)

    // The off switch, from a genuinely armed controller on healthy power.
    c.userToggled(to: .stop)
    #expect(c.intent == .stop)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 90).idleSleepAssertion == false)

    // A reason the user has not read yet must survive the same off switch.
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 12)
    #expect(c.lastSuppression == .batteryFloor(percent: 12, floor: 20))

    c.userToggled(to: .stop)
    #expect(c.lastSuppression == .batteryFloor(percent: 12, floor: 20))
}

@Test func evaluateForwardsAnExplicitBatteryFloor() {
    // `batteryFloorPercent` is the third pass-through, and the one the earlier
    // guard test left open. Named bug this catches: `evaluate` hard-coding
    // `batteryFloorPercent: 20` into the `PowerInputs` it builds. 40% sits
    // above the default floor and below the floor asked for here, so every
    // other test in this file stays green while a user-configured floor is
    // silently discarded and the machine keeps serving past it.
    var c = HoldController()
    c.userToggled(to: .serve)

    let out = c.evaluate(powerSource: .battery, batteryPercent: 40,
                         batteryFloorPercent: 50)
    #expect(out.idleSleepAssertion == false)
    #expect(out.suppression == .batteryFloor(percent: 40, floor: 50))
    #expect(c.lastSuppression == .batteryFloor(percent: 40, floor: 50))
}
