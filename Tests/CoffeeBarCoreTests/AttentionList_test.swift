// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

// Two lists, one array. `rows` answers "what is waiting on me" and `working`
// answers "what is keeping this Mac awake" — design §14, which exists because
// the panel as first planned showed the first question only, so the session
// actually holding the assertion appeared nowhere in a product whose whole
// pitch is that you can see it.
//
// Both read the SAME `[AgentSession]` the broker reads. A second source here
// could disagree with the decision, and a panel that disagrees with the
// machine is worse than a panel with nothing on it.
//
// Every expectation below is a literal. Asserting against
// `SessionState.attentionStates` or `PowerBroker.activeStates` would be
// asserting the implementation against itself: both calls are what the
// implementation filters on, so a change to either would move the test with
// it. `SessionHub_test.theTwoDefinitionsOfBlockedCannotDrift` pins those two
// sets against each other; this file pins THIS code against the states named
// in design §3.1.

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func session(_ state: SessionState,
                     id: String,
                     attentionSince: Date? = nil) -> AgentSession {
    AgentSession(tool: .claudeCode, sessionID: id, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: attentionSince, turnCount: 0)
}

/// One session per state, so a filter that lets an extra state through is
/// visible rather than merely unexercised.
private let oneOfEveryState = SessionState.allCases.map {
    session($0, id: $0.rawValue, attentionSince: t0)
}

// MARK: - What is waiting on the user

@Test func onlyTheAttentionStatesAppear() {
    // Named bug this catches: a list that shows every session it is handed.
    // `.done`, `.failed` and `.stale` are finished, and `.working` is not
    // blocked on anybody — putting any of them under "waiting on you" sends
    // the user to a terminal where nothing is waiting.
    let rows = AttentionList.rows(from: oneOfEveryState)

    #expect(rows.map(\.state).sorted { $0.rawValue < $1.rawValue }
            == [SessionState.awaitingInput, SessionState.awaitingPermission])
    #expect(rows.count == 2)
}

@Test func theLongestWaitComesFirst() {
    // The list exists to answer "what is waiting on me". The thing waiting
    // longest is the answer, so it goes at the top.
    let rows = AttentionList.rows(from: [
        session(.awaitingInput, id: "recent", attentionSince: t0.addingTimeInterval(500)),
        session(.awaitingPermission, id: "old", attentionSince: t0),
        session(.awaitingInput, id: "middle", attentionSince: t0.addingTimeInterval(100)),
    ])

    #expect(rows.map(\.sessionID) == ["old", "middle", "recent"])
}

@Test func theOrderIsTotalSoTiesDoNotShuffle() {
    // Named bug this catches: a sort with no tie-break. Two sessions blocked in
    // the same instant would then swap places between refreshes, under the
    // user's cursor, while every other check in this file stayed green.
    let rows = AttentionList.rows(from: [
        session(.awaitingInput, id: "zeta", attentionSince: t0),
        session(.awaitingInput, id: "alpha", attentionSince: t0),
    ])
    #expect(rows.map(\.sessionID) == ["alpha", "zeta"])

    let reversed = AttentionList.rows(from: [
        session(.awaitingInput, id: "alpha", attentionSince: t0),
        session(.awaitingInput, id: "zeta", attentionSince: t0),
    ])
    #expect(rows.map(\.sessionID) == reversed.map(\.sessionID),
            "input order changed the output order")
}

@Test func aSessionWithNoAttentionStampSortsLast() {
    // `attentionSince` is nil only for a session built before it entered an
    // attention state. It must not sort to the top as "waiting since forever".
    //
    // BOTH input orders, and that is not padding. The comparator has a separate
    // branch per side of the nil, and a two-element sort consults exactly one
    // of them — whichever the input order happens to ask about. Measured: with
    // the unstamped session first, breaking `case (nil, _?)` left this check
    // GREEN, because the sort never asked that question.
    let unstampedFirst = AttentionList.rows(from: [
        session(.awaitingInput, id: "unstamped", attentionSince: nil),
        session(.awaitingInput, id: "stamped", attentionSince: t0),
    ])
    #expect(unstampedFirst.map(\.sessionID) == ["stamped", "unstamped"])

    let stampedFirst = AttentionList.rows(from: [
        session(.awaitingInput, id: "stamped", attentionSince: t0),
        session(.awaitingInput, id: "unstamped", attentionSince: nil),
    ])
    #expect(stampedFirst.map(\.sessionID) == ["stamped", "unstamped"])
}

@Test func twoUnstampedSessionsStillHaveATotalOrder() {
    // The nil/nil pair is its own branch of the comparator, and the branch that
    // sorts nil last does not reach it. Named bug this catches: a `default`
    // that returns a constant, which leaves two unstamped sessions swapping
    // places on every refresh while `theOrderIsTotalSoTiesDoNotShuffle` — whose
    // sessions are both stamped — stays green.
    let rows = AttentionList.rows(from: [
        session(.awaitingInput, id: "zeta", attentionSince: nil),
        session(.awaitingInput, id: "alpha", attentionSince: nil),
    ])

    #expect(rows.map(\.sessionID) == ["alpha", "zeta"])
}

@Test func anEmptyInputGivesAnEmptyList() {
    #expect(AttentionList.rows(from: []).isEmpty)
}

// MARK: - What is keeping the Mac awake

@Test func onlyTheStatesThatHoldTheMachineAwakeCount() {
    // Design §14, and PE finding I4 that it resolves. A `.working` session is
    // the one holding the assertion, and the attention list above shows it
    // nowhere — so without this the user cannot see what is keeping their Mac
    // awake, from a product whose pitch is exactly that.
    //
    // `.starting` counts too. It holds the assertion just as `.working` does
    // (`PowerBroker.activeStates`), so a count that named `.working` alone
    // would report "0 sessions" while the machine was pinned awake.
    let working = AttentionList.working(from: oneOfEveryState)

    #expect(working.map(\.state).sorted { $0.rawValue < $1.rawValue }
            == [SessionState.starting, SessionState.working])
    #expect(working.count == 2)
}

@Test func aBlockedSessionIsNotCountedAsWorking() {
    // Named bug this catches: counting every live session. A session waiting on
    // a permission prompt does NOT hold the assertion with the shipped knob
    // off, so "1 session working" beside "Not holding any assertion" tells the
    // user the app is broken when it is doing exactly the right thing.
    let working = AttentionList.working(from: [
        session(.awaitingPermission, id: "blocked", attentionSince: t0),
        session(.awaitingInput, id: "idle", attentionSince: t0),
    ])

    #expect(working.isEmpty)
}

@Test func theBlockedKnobAddsTheAttentionStatesToTheCount() {
    // `holdAwakeWhileBlocked` is not reachable from the UI yet, and it defaults
    // here to the same `false` `HoldController.evaluate` defaults to, so the
    // two cannot disagree today. This pins the parameter so that the day it IS
    // wired up, the count follows the assertion instead of drifting from it.
    let sessions = [
        session(.working, id: "busy", attentionSince: nil),
        session(.awaitingPermission, id: "blocked", attentionSince: t0),
    ]

    #expect(AttentionList.working(from: sessions).map(\.sessionID) == ["busy"])
    #expect(AttentionList.working(from: sessions, holdAwakeWhileBlocked: true)
            .map(\.sessionID) == ["busy", "blocked"])
}

@Test func nothingWorkingGivesAnEmptyList() {
    #expect(AttentionList.working(from: []).isEmpty)
}
