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

    // The controller falls back to the STANDING position the user was on before
    // the one-off request, which is the `.auto` default here. It reads `.auto`
    // rather than `.stop` from this task on — see
    // `aRefusedServeFallsBackToTheStandingPositionNotToOff`. The assertion above
    // is the one that holds the line either way: with no sessions, `.auto`
    // holds nothing, so a `true` there could only come from a `.serve` that
    // re-armed itself.
    #expect(c.intent == .auto)
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
    // The refusal cancels the one-off request and leaves the standing position,
    // which is the `.auto` default here. What matters below is that the hold is
    // gone until the user asks again.
    #expect(c.intent == .auto)

    c.userToggled(to: .serve)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 90).idleSleepAssertion == true)
}

@Test func togglingOnBelowTheFloorIsRefusedAndReported() {
    var c = HoldController()
    c.userToggled(to: .serve)
    let out = c.evaluate(powerSource: .battery, batteryPercent: 5)
    #expect(out.idleSleepAssertion == false)
    #expect(out.suppression == .batteryFloor(percent: 5, floor: 20))
    // Refused, and the control returns to the standing position rather than to
    // the absolute veto. `.auto` is the default this controller started on.
    #expect(c.intent == .auto)
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

// MARK: - Where a refused `.serve` lands

@Test func aRefusedServeFallsBackToTheStandingPositionNotToOff() {
    // Audit finding I4, as the five steps it reports.
    //
    // The doc comment on `evaluate` justifies CANCELLING the one-off request. It
    // does not justify the position the cancel lands on. `.stop` is a third
    // position, an absolute veto, and the user never picked it — so a request
    // that FAILED leaves them holding strictly less than before they touched the
    // control.
    var c = HoldController()                       // 1. the shipping default.
    let working = [session(.working)]

    // 2-3. The battery is under the floor. The user clicks On, and the floor
    // refuses the hold.
    c.userToggled(to: .serve)
    let refused = c.evaluate(powerSource: .battery, batteryPercent: 15,
                             sessions: working)
    #expect(refused.idleSleepAssertion == false)
    #expect(refused.suppression == .batteryFloor(percent: 15, floor: 20))

    // The one-off request is gone, and the standing position is back.
    #expect(c.intent == .auto,
            "a refused .serve moved the user to a position they never picked")

    // 4-5. The battery recovers to 100% on AC and the agent is still working.
    let recovered = c.evaluate(powerSource: .ac, batteryPercent: 100,
                               sessions: working)
    #expect(recovered.idleSleepAssertion == true,
            "the Mac sleeps under a working agent because one refused click vetoed .auto")
}

@Test func askingForAHoldNeverLeavesLessHeldThanAskingForNothing() {
    // The comparison this finding turns on, and the one that rests on no
    // judgement about what a user expects to see. Two controllers meet the SAME
    // world. One user clicks On below the floor; the other never touches the
    // control. Clicking On asks for MORE holding, so the machine must never end
    // up holding LESS than it would have held for the user who did nothing.
    //
    // Named bug this catches: `intent = .stop` on a refused `.serve`. The
    // clicker ends on the absolute veto, so the Mac sleeps under a working agent
    // — the single failure this product exists to prevent — while the user who
    // left the control alone keeps serving.
    let working = [session(.working)]

    var clicked = HoldController()
    clicked.userToggled(to: .serve)
    #expect(clicked.evaluate(powerSource: .battery, batteryPercent: 15,
                             sessions: working).idleSleepAssertion == false)

    var untouched = HoldController()
    #expect(untouched.evaluate(powerSource: .battery, batteryPercent: 15,
                               sessions: working).idleSleepAssertion == false)

    // The same recovery reaches both.
    let afterClick = clicked.evaluate(powerSource: .ac, batteryPercent: 100,
                                      sessions: working)
    let afterNothing = untouched.evaluate(powerSource: .ac, batteryPercent: 100,
                                          sessions: working)

    // The control, against a literal. Without it both sides could be `false`
    // and the comparison below would hold for a controller that never holds.
    #expect(afterNothing.idleSleepAssertion == true)
    #expect(afterClick.idleSleepAssertion == afterNothing.idleSleepAssertion,
            "clicking On and being refused held less than never clicking at all")
}

@Test func aRefusedServeNeverComesBackAsAnUnconditionalHold() {
    // The invariant the doc comment defends, kept. `.serve` holds whatever the
    // sessions are doing, and THAT property must never return by itself: the
    // user asked once, watched it fail, and re-arming is a behaviour they cannot
    // see coming.
    //
    // The session list is EMPTY on purpose. `.auto` holds nothing with an empty
    // list, so a hold at the end can only come from a `.serve` that re-armed
    // itself. Named bug this catches: falling back to `.serve` — the fallback
    // that a naive "restore whatever the intent was" produces.
    var c = HoldController()
    c.userToggled(to: .serve)
    #expect(c.evaluate(powerSource: .battery, batteryPercent: 15).suppression != nil)

    let recovered = c.evaluate(powerSource: .ac, batteryPercent: 100)
    #expect(recovered.idleSleepAssertion == false,
            "a refused .serve re-armed itself once the battery recovered")
    #expect(c.intent != .serve)
}

@Test func aSecondOnClickCannotMakeServeItsOwnFallback() {
    // The hole a "remember the previous intent" fallback opens. The user clicks
    // On twice with no refusal between the clicks, so the remembered position is
    // `.serve` itself. The floor then refuses, the fallback restores `.serve`,
    // and the latch never fires at all.
    //
    // Named bug this catches: recording the outgoing intent on EVERY toggle
    // instead of recording the standing positions only. With no sessions, the
    // hold below can only come from a `.serve` that survived its own refusal.
    var c = HoldController()
    c.userToggled(to: .serve)
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 15)

    #expect(c.intent == .auto)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 100).idleSleepAssertion == false,
            "a repeated On click made .serve its own fallback and re-armed the hold")
}

@Test func aRefusedServeFromOffReturnsToOff() {
    // The standing position is not always `.auto`. A user who has vetoed serving
    // outright, then clicks On and is refused, must land back on the veto.
    //
    // Named bug this catches: falling back to `.auto` unconditionally. The off
    // switch then survives exactly one refused click, and the next working agent
    // pins the machine awake for a user who switched the product off.
    // coffee-bar overrides the machine's own sleep policy, so that is the trust
    // failure `UserIntent.stop` exists to prevent.
    var c = HoldController()
    c.userToggled(to: .stop)
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 15)

    #expect(c.intent == .stop)
    #expect(c.evaluate(powerSource: .ac, batteryPercent: 100,
                       sessions: [session(.working)]).idleSleepAssertion == false,
            "a click that failed undid the user's off switch")
}

// MARK: - A refused On click is distinguishable from a quiet suppression

@Test func aRefusedOnClickRecordsWhereTheControlLanded() {
    // The panel has to tell "the app moved my control" apart from "the floor is
    // refusing a hold I never asked for". `lastSuppression` is recorded for
    // BOTH, so by itself it cannot carry that difference.
    //
    // Named bug this catches: cancelling the `.serve` and recording nothing.
    // The control snaps back to Auto with no state saying it moved, so the panel
    // shows a refused click and an untouched control the same way.
    var c = HoldController()
    #expect(c.cancelledServe == nil, "a fresh controller has refused nothing")

    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 19)

    #expect(c.intent == .auto)
    #expect(c.cancelledServe == .refused(returnedTo: .auto))
}

@Test func anHonouredServeReleasedByTheFloorIsNotRecordedAsRefused() {
    // `PowerBroker` holds for `.serve` unconditionally, so a click well above the
    // floor is HONOURED. The battery then drains under it and the same floor
    // releases the hold — the normal way the On position ends, not an edge case.
    //
    // Named bug this catches: recording every cancelled `.serve` as a refusal.
    // The panel then tells a user whose click worked for hours that it was
    // refused, which is simply false. It is the ambiguity `lastSuppression`
    // already had, one level down: "refused" and "served then released" arrive
    // at the same branch and must not leave it as the same value.
    var c = HoldController()
    c.userToggled(to: .serve)

    // Honoured. This is the half that separates the two paths.
    #expect(c.evaluate(powerSource: .battery, batteryPercent: 50).idleSleepAssertion == true,
            "precondition: the click was served, so a later cancel is a RELEASE")
    #expect(c.cancelledServe == nil, "nothing is cancelled while the hold runs")

    // `assertionIsHeld` reports that the caller really took the assertion the
    // evaluate above asked for. The controller decides what should happen and
    // IOKit decides what did, so this fact can only come from the caller —
    // `aHoldThatWasNeverTakenIsNotCalledAReleasedHold` covers the other answer.
    _ = c.evaluate(powerSource: .battery, batteryPercent: 19, assertionIsHeld: true)

    #expect(c.intent == .auto)
    #expect(c.cancelledServe == .released(returnedTo: .auto))
}

@Test func aFreshOnClickRefusedAfterAnEarlierHoldSaysRefusedNotReleased() {
    // A new click is a NEW request, judged on its own outcome. The success of an
    // earlier one must not carry into it.
    //
    // Named bug this catches: `userToggled(to: .serve)` not clearing the "this
    // request has held" memory. The user serves happily at 50%, goes back to
    // Auto, and later clicks On at 19% — a click that is refused outright and
    // never holds for a second. The panel reports it as a released hold, so it
    // describes a hold that never existed.
    var c = HoldController()
    c.userToggled(to: .serve)
    #expect(c.evaluate(powerSource: .battery, batteryPercent: 50).idleSleepAssertion == true,
            "precondition: the FIRST click was served")

    // The hold is really taken, so the FIRST request genuinely held. Without
    // this the check runs against a request that never held and proves nothing
    // about a success leaking forward.
    _ = c.evaluate(powerSource: .battery, batteryPercent: 50, assertionIsHeld: true)

    // Back to Auto by hand, with no cancel in between — so nothing else clears
    // the memory of that success.
    c.userToggled(to: .auto)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 50, assertionIsHeld: true)

    // A fresh click, below the floor this time. It is refused, never served.
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 19)

    #expect(c.intent == .auto)
    #expect(c.cancelledServe == .refused(returnedTo: .auto))
}

@Test func aSuppressionThatCancelsNoClickClearsAStaleCancel() {
    // The record is written in lockstep with `lastSuppression`, so a NEW
    // suppression that cancels nothing has to wipe the old cancel.
    //
    // Named bug this catches: writing the record on the `.serve` branch only and
    // never clearing it. One refused click then replays onto every later
    // suppression under `.auto`, so a user who touched nothing is told their
    // click was refused.
    var c = HoldController()
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 19)
    #expect(c.cancelledServe == .refused(returnedTo: .auto), "precondition: a cancel is on record")

    // No click. A working session asks for the hold under `.auto`, and the same
    // floor refuses it.
    _ = c.evaluate(powerSource: .battery, batteryPercent: 19,
                   sessions: [session(.working)])

    #expect(c.lastSuppression == .batteryFloor(percent: 19, floor: 20),
            "precondition: that evaluate really did suppress")
    #expect(c.cancelledServe == nil)
}

@Test func movingTheControlByHandClearsTheRefusalRecord() {
    // `lastSuppression` survives an Off click on purpose, and
    // `togglingOffStopsTheHoldAndKeepsTheReason` pins that. The cancel record
    // must NOT survive it, because it names a position the user has just left.
    //
    // Named bug this catches: clearing the record only on `.serve`, copying what
    // `lastSuppression` does. The user is refused from Auto, clicks Off, and the
    // panel says the control is back on Auto while the control reads Off.
    var c = HoldController()
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 12)
    #expect(c.cancelledServe == .refused(returnedTo: .auto), "precondition: a cancel is on record")

    c.userToggled(to: .stop)

    #expect(c.cancelledServe == nil)
    #expect(c.lastSuppression == .batteryFloor(percent: 12, floor: 20),
            "the reason the user has not read yet must still survive an Off click")
}
