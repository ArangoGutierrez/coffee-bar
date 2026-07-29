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

// The helper's intent defaults to `.auto`, which is what "the user asked for
// nothing in particular" now means and what `PowerInputs` itself defaults to.
// It was `.stop` while `.stop` meant no more than that. `.stop` is a VETO from
// M2 on, so leaving the default there would make every session test below
// decide false for the veto's sake and see nothing of the wake predicate.
private func inputs(sessions: [AgentSession] = [],
                    source: PowerSource = .ac,
                    battery: Int? = 80,
                    intent: UserIntent = .auto,
                    blocked: Bool = false,
                    floor: Int = 20) -> PowerInputs {
    PowerInputs(sessions: sessions, powerSource: source, batteryPercent: battery,
                userIntent: intent, holdAwakeWhileBlocked: blocked,
                batteryFloorPercent: floor)
}

// MARK: - The invariant that justifies the product

@Test func displaySleepAssertionIsNeverRequested() {
    // Handoff §6.1. Every combination, not a sampled one: this is the single
    // behaviour that separates coffee-bar from `caffeinate -d`.
    //
    // `UserIntent.allCases`, not a literal `[.serve, .stop]`. That literal was
    // the whole enum until M2 added `.auto`, and a hand-written list silently
    // stops being every combination the moment a case is added — which is
    // exactly what just happened. Named bug this catches: a fourth intent that
    // reaches `decide` and asks for a display assertion, with this sweep never
    // once passing it.
    for state in SessionState.allCases {
        for source in [PowerSource.ac, .battery] {
            for intent in UserIntent.allCases {
                for blocked in [true, false] {
                    for battery in [nil, 0, 19, 20, 21, 100] as [Int?] {
                        let out = PowerBroker.decide(inputs(
                            sessions: [session(state)], source: source,
                            battery: battery, intent: intent, blocked: blocked))
                        #expect(out.displaySleepAssertion == false)
                    }
                }
            }
        }
    }
}

// MARK: - Wake predicate (§5.1)

@Test func wakePredicateHonoursOnlyStartingAndWorking() {
    // With the knob off, exactly two of the seven states hold the assertion.
    let holding: Set<SessionState> = [.starting, .working]
    for state in SessionState.allCases {
        let out = PowerBroker.decide(inputs(sessions: [session(state)]))
        #expect(out.idleSleepAssertion == holding.contains(state),
                "state \(state.rawValue) decided \(out.idleSleepAssertion)")
    }
}

@Test func blockedStatesHoldOnlyWhenTheKnobIsSet() {
    // Knob off: the two ATTENTION states do not hold.
    for state in [SessionState.awaitingPermission, .awaitingInput] {
        #expect(PowerBroker.decide(
            inputs(sessions: [session(state)], blocked: false)).idleSleepAssertion == false,
                "state \(state.rawValue) with the knob off decided true")
    }

    // Knob on: all FOUR active states hold. `.starting` and `.working` are
    // listed because the knob ADDS the attention states to the base set — it
    // must never replace it. Without them, a change that narrows the knob-on
    // set to `[.awaitingPermission, .awaitingInput]` stays green here and in
    // every other test, and a working session stops holding the machine awake
    // the moment the user enables the knob: the inverse of its purpose.
    for state in [SessionState.starting, .working, .awaitingPermission, .awaitingInput] {
        #expect(PowerBroker.decide(
            inputs(sessions: [session(state)], blocked: true)).idleSleepAssertion == true,
                "state \(state.rawValue) with the knob on decided false")
    }
}

@Test func doneAndFailedNeverHoldEvenWithTheKnobSet() {
    // The knob covers the two ATTENTION states only. A finished session must
    // not keep the machine awake forever.
    for state in [SessionState.done, .failed, .stale] {
        #expect(PowerBroker.decide(
            inputs(sessions: [session(state)], blocked: true)).idleSleepAssertion == false)
    }
}

@Test func theControlAloneDecidesWithNoSessionsAtAll() {
    // With no sessions the control is the only live input, which is the whole
    // of M1 and is still the state a fresh install starts in. All THREE
    // positions, because `.auto` with nothing to follow must decide false — a
    // `.auto` that fell through to `true` would hold the machine awake forever
    // on a laptop that has never seen an agent session.
    #expect(PowerBroker.decide(inputs(intent: .serve)).idleSleepAssertion == true)
    #expect(PowerBroker.decide(inputs(intent: .stop)).idleSleepAssertion == false)
    #expect(PowerBroker.decide(inputs(intent: .auto)).idleSleepAssertion == false)
}

// MARK: - More than one session (§5.1)

// Every case below passes `intent: .auto`, which is the only position that
// lets the sessions decide anything. `.serve` holds whatever the sessions say
// and `.stop` vetoes whatever the sessions say, so under either of them none
// of these tests would see the wake predicate at all.
//
// These cases read `.stop` until M2. That was correct while `decide` ORed the
// toggle with the predicate and `.stop` meant no more than "the user did not
// ask". `.stop` is now a veto, so every one of them would decide false for the
// veto's sake — `aListOfOnlyInactiveSessionsHoldsNothing` and the knob-off
// cases would still read GREEN while asserting nothing about the predicate.
//
// M1 never populates `sessions`, so no other test in this file passes more
// than one. Without this section `inputs.sessions.contains` can be narrowed to
// `.first`, `.last` or `prefix(1).contains` and the whole suite stays green —
// until M2 starts feeding real sessions.

@Test func anActiveSessionAnywhereInTheListHolds() {
    // `.working` sits LAST. A predicate that reads only the first element
    // decides false here.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.done), session(.working)],
               intent: .auto)).idleSleepAssertion == true)
}

@Test func anActiveSessionFirstInTheListAlsoHolds() {
    // `.working` sits FIRST. A predicate that reads only the last element
    // decides false here.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.working), session(.done)],
               intent: .auto)).idleSleepAssertion == true)
}

@Test func theOrderOfTheSessionsDoesNotChangeTheOutcome() {
    // The two orders carry the same one active session, so no access fixed to
    // a position can satisfy both. The second expectation pins the shared
    // outcome to `true`: a predicate stuck at false agrees with itself.
    let activeLast = PowerBroker.decide(
        inputs(sessions: [session(.done), session(.working)], intent: .auto))
    let activeFirst = PowerBroker.decide(
        inputs(sessions: [session(.working), session(.done)], intent: .auto))
    #expect(activeLast == activeFirst,
            "order changed the decision: \(activeLast) then \(activeFirst)")
    #expect(activeLast.idleSleepAssertion == true)
}

@Test func aListOfOnlyInactiveSessionsHoldsNothing() {
    // Three sessions and not one of them active. A predicate stuck at `true`,
    // or one that only answers "the list is not empty", decides true here.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.done), session(.failed), session(.stale)],
               intent: .auto)).idleSleepAssertion == false)
}

@Test func aWorkingSessionHoldsBesideABlockedOneWithTheKnobOff() {
    // The knob is off, so `.awaitingInput` contributes nothing and `.working`
    // alone carries the hold. A knob-off active set that drops `.working`
    // decides false here.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.awaitingInput), session(.working)],
               intent: .auto, blocked: false)).idleSleepAssertion == true)
}

@Test func twoBlockedSessionsHoldOnlyOnceTheKnobIsSet() {
    // The knob wiring, read across more than one session.
    let blocked = [session(.awaitingInput), session(.awaitingPermission)]
    #expect(PowerBroker.decide(
        inputs(sessions: blocked, intent: .auto, blocked: false)
    ).idleSleepAssertion == false, "two blocked sessions held with the knob off")
    #expect(PowerBroker.decide(
        inputs(sessions: blocked, intent: .auto, blocked: true)
    ).idleSleepAssertion == true, "two blocked sessions did not hold with the knob on")
}

// MARK: - The intent and the sessions on one call (§5.1, settled in M2)

@Test func eachIntentRanksAgainstTheSessionsDifferently() {
    // §5.1 deferred to M2 the question this answers: does an explicit `.stop`
    // outrank an active session? It does. The OR is gone and the three
    // positions rank differently, so the full matrix is asserted here.
    //
    // This is the only test in the file that reads the intent AND a non-empty
    // session list on one call. Every case in the section above passes `.auto`
    // and every case below passes an empty list, so the two inputs are
    // otherwise only ever exercised apart.
    // `displaySleepAssertionIsNeverRequested` does combine them, but it reads
    // `displaySleepAssertion` and never the hold.

    // 1. `.stop` VETOES an active session. This is the M2 decision, and the
    //    reason it is a decision rather than a detail: coffee-bar overrides the
    //    machine's own sleep policy, so an off switch that an agent session can
    //    outrank is a product the user cannot trust. Named bug this catches:
    //    the M1 `userIntent == .serve || sessionsWantAwake` surviving into M2,
    //    where a background session pins a laptop awake in a bag after the user
    //    switched the product off.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.working)], intent: .stop)).idleSleepAssertion == false,
            "an explicit .stop did not outrank an active session")

    // 2. `.serve` holds THROUGH a quiet session list. Named bug this catches:
    //    `sessions.isEmpty ? (userIntent == .serve) : sessionsWantAwake` — the
    //    sessions silently outranking an explicit request. A user who picks On
    //    then gets nothing for as long as any session sits in a non-active
    //    state: the machine sleeps mid-task and the control looks broken.
    //    Verified as a live mutant against this expectation, not assumed.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.done)], intent: .serve)).idleSleepAssertion == true,
            "Serve stopped holding once an inactive session existed")

    // 3. `.auto` FOLLOWS the sessions, both ways. The pair is what makes it
    //    "follows" rather than a constant: a `.auto` stuck at true satisfies
    //    3a alone, and one stuck at false satisfies 3b alone.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.working)], intent: .auto)).idleSleepAssertion == true,
            "Auto did not follow an active session")
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.done)], intent: .auto)).idleSleepAssertion == false,
            "Auto held for an inactive session")

    // 4. `.stop` vetoes the quiet list too. Without it, a `.stop` branch that
    //    read `sessionsWantAwake` instead of `false` would still satisfy 1
    //    for the wrong reason if the predicate were also broken.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.done)], intent: .stop)).idleSleepAssertion == false,
            "an inactive session held with the control off")
}

// MARK: - Battery floor (§8.1)

@Test func batteryFloorSuppressesAtOrBelowTheFloor() {
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: 21, intent: .serve)).idleSleepAssertion == true)
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: 20, intent: .serve)).idleSleepAssertion == false)
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: 19, intent: .serve)).idleSleepAssertion == false)
}

@Test func batteryFloorAppliesOnlyOnBatteryPower() {
    // Plugged in at 19% is not an emergency.
    #expect(PowerBroker.decide(
        inputs(source: .ac, battery: 19, intent: .serve)).idleSleepAssertion == true)
}

@Test func absentBatteryReadingNeverSuppresses() {
    // A desktop has no battery. An unreadable percentage must not silently
    // stop the product from working.
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: nil, intent: .serve)).idleSleepAssertion == true)
}

@Test func suppressionReasonNamesTheMeasuredPercentAndFloor() {
    // Compared against literals the implementation does not compute, so a
    // hard-coded reason fails here.
    let out = PowerBroker.decide(
        inputs(source: .battery, battery: 7, intent: .serve, floor: 15))
    #expect(out.suppression == .batteryFloor(percent: 7, floor: 15))
}

@Test func noSuppressionIsReportedWhenTheHoldIsHonoured() {
    #expect(PowerBroker.decide(inputs(intent: .serve)).suppression == nil)
}

@Test func theBatteryFloorGovernsAutoAsWellAsServe() {
    // The floor is a safety limit on the machine, not a veto on one control
    // position. Every other floor case in this file passes `.serve`, so a floor
    // check written as `userIntent == .serve && percent <= floor` — or one
    // reached only from the `.serve` branch of the new switch — stays green
    // across the whole file while `.auto` drains the battery to zero.
    //
    // Named bug this catches exactly that: an `.auto` hold that ignores the
    // floor. Once M2 feeds real sessions, `.auto` is the DEFAULT and the
    // position almost every user sits in, so the floor mattering only under
    // `.serve` means the floor effectively does not exist.
    let suppressed = PowerBroker.decide(
        inputs(sessions: [session(.working)], source: .battery, battery: 19, intent: .auto))
    #expect(suppressed.idleSleepAssertion == false,
            "Auto held an active session below the battery floor")
    #expect(suppressed.suppression == .batteryFloor(percent: 19, floor: 20))

    // The control case, one point above the floor. Without it, an `.auto` that
    // never holds at all satisfies the expectation above.
    #expect(PowerBroker.decide(
        inputs(sessions: [session(.working)], source: .battery, battery: 21, intent: .auto)
    ).idleSleepAssertion == true, "Auto stopped holding above the floor")
}

// MARK: - The declared defaults (§4.2)

@Test func powerInputsAppliesItsDocumentedDefaults() {
    // Constructed WITHOUT holdAwakeWhileBlocked and batteryFloorPercent. The
    // `inputs` helper above always passes both, so every other test in this
    // file is blind to what the declared defaults actually are: changing the
    // floor to 90, or the knob to true, leaves them all green. Design spec
    // §4.2 fixes the floor at 20 and the knob at off, and Task 5 reads both,
    // so the defaults are a contract and need a test that can see them.

    // Floor defaults to 20, so 21% on battery is above it and still holds.
    #expect(PowerBroker.decide(
        PowerInputs(powerSource: .battery, batteryPercent: 21, userIntent: .serve)
    ).idleSleepAssertion == true, "21% on battery must clear the default floor")

    // 20% is AT the default floor, so §8.1 suppresses. The reason carries the
    // floor it used, which pins the default to the literal 20 rather than to
    // "whatever the implementation chose".
    let atFloor = PowerBroker.decide(
        PowerInputs(powerSource: .battery, batteryPercent: 20, userIntent: .serve))
    #expect(atFloor.idleSleepAssertion == false)
    #expect(atFloor.suppression == .batteryFloor(percent: 20, floor: 20))

    // The blocked knob defaults to off, so an attention state does not hold.
    // `.auto`, not `.stop`: under `.stop` the veto decides this on its own and
    // the knob is never consulted, so the check would read green for a knob
    // that defaulted to ON.
    #expect(PowerBroker.decide(
        PowerInputs(sessions: [session(.awaitingPermission)], powerSource: .ac,
                    batteryPercent: 80, userIntent: .auto)
    ).idleSleepAssertion == false,
            "the blocked knob must default to off")
}

@Test func theIntentDefaultsToAuto() {
    // `.auto` is the position a fresh install sits in — the product follows
    // the agent sessions until the user says otherwise. Design D1.
    //
    // Constructed WITHOUT `userIntent`, which no other test in this file does:
    // the `inputs` helper always passes one, and every explicit `PowerInputs`
    // above names it. So the declared default is invisible everywhere else and
    // could be `.stop` — shipping a product that does nothing until the user
    // finds the control — or `.serve` — shipping one that pins the machine
    // awake from first launch.
    let quiet = PowerInputs(powerSource: .ac, batteryPercent: 80)
    #expect(quiet.userIntent == .auto)

    // Asserted through `decide` as well as on the field, so the default has to
    // be the case that FOLLOWS the sessions rather than merely be spelled
    // `.auto`. An active session holds, a finished one does not.
    #expect(PowerBroker.decide(
        PowerInputs(sessions: [session(.working)], powerSource: .ac, batteryPercent: 80)
    ).idleSleepAssertion == true, "the default intent did not follow an active session")
    #expect(PowerBroker.decide(
        PowerInputs(sessions: [session(.done)], powerSource: .ac, batteryPercent: 80)
    ).idleSleepAssertion == false, "the default intent held for an inactive session")
}

@Test func noSuppressionIsReportedWhenNoHoldWasRequested() {
    // Low battery while nothing is held is not a suppressed hold — nothing was
    // asked for, so the panel must stay silent rather than explain a refusal
    // that never happened.
    //
    // Both quiet positions. `.auto` with no session is the state a laptop sits
    // in all day, and it is the one that would otherwise start reporting a
    // battery reason at 5% on a machine coffee-bar is not touching.
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: 5, intent: .auto)).suppression == nil)
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: 5, intent: .stop)).suppression == nil)
}
