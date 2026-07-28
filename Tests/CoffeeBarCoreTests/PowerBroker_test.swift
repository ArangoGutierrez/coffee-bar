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

private func inputs(sessions: [AgentSession] = [],
                    source: PowerSource = .ac,
                    battery: Int? = 80,
                    intent: UserIntent = .stop,
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
    for state in SessionState.allCases {
        for source in [PowerSource.ac, .battery] {
            for intent in [UserIntent.serve, .stop] {
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

@Test func theToggleHoldsWithNoSessionsAtAll() {
    // This is all of M1: no ingest, so the toggle is the only live input.
    #expect(PowerBroker.decide(inputs(intent: .serve)).idleSleepAssertion == true)
    #expect(PowerBroker.decide(inputs(intent: .stop)).idleSleepAssertion == false)
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
    #expect(PowerBroker.decide(
        PowerInputs(sessions: [session(.awaitingPermission)], powerSource: .ac,
                    batteryPercent: 80, userIntent: .stop)
    ).idleSleepAssertion == false,
            "the blocked knob must default to off")
}

@Test func noSuppressionIsReportedWhenNoHoldWasRequested() {
    // Low battery while idle is not a suppressed hold — nothing was asked for.
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: 5, intent: .stop)).suppression == nil)
}
