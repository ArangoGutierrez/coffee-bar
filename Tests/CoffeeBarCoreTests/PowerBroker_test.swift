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
    for state in [SessionState.awaitingPermission, .awaitingInput] {
        #expect(PowerBroker.decide(
            inputs(sessions: [session(state)], blocked: false)).idleSleepAssertion == false)
        #expect(PowerBroker.decide(
            inputs(sessions: [session(state)], blocked: true)).idleSleepAssertion == true)
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

@Test func noSuppressionIsReportedWhenNoHoldWasRequested() {
    // Low battery while idle is not a suppressed hold — nothing was asked for.
    #expect(PowerBroker.decide(
        inputs(source: .battery, battery: 5, intent: .stop)).suppression == nil)
}
