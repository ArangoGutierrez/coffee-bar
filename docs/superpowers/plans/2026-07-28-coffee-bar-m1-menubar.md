# M1 Menu-Bar App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS menu-bar app that holds `PreventUserIdleSystemSleep` under manual control, built on the pure decision core that M2 plugs agent ingest into.

**Architecture:** All policy lives in Foundation-only `CoffeeBarCore` as pure value types and functions, so it tests without a Mac. `CoffeeBarPower` owns IOKit. `CoffeeBarApp` is a thin SwiftUI `MenuBarExtra` that reads power, calls the controller, and applies the result to the existing `AssertionHolder`.

**Tech Stack:** Swift 6 (`.swiftLanguageMode(.v6)`), SwiftPM, SwiftUI `MenuBarExtra`, IOKit, `swift-testing`.

## Global Constraints

- **Test files are named `<Subject>_test.swift`.** Not `…Tests.swift`. `tdd-guard.sh` requires it.
- **The test framework is `swift-testing`**, not XCTest: `import Testing`, `@Test func name()`, `#expect(...)`. Follow the helper style in `Tests/CoffeeBarCoreTests/WatchdogDecision_test.swift`.
- **`CoffeeBarCore` imports Foundation and nothing else.** No AppKit, SwiftUI, IOKit. Handoff §13.1.
- **Nothing may hold `PreventUserIdleDisplaySleep`.** Handoff §6.1. This is the product's reason to exist.
- Every target uses `.swiftLanguageMode(.v6)`. Match the existing `Package.swift`.
- Platform floor is `.macOS(.v14)`.
- Every file starts with the two-line header used across the repo:
  `// Copyright 2026 Carlos Eduardo Arango Gutierrez` and
  `// SPDX-License-Identifier: Apache-2.0`.
- Commits are signed: `git commit -s -S`. Commit with explicit pathspecs.
- **Run all `swift` commands with the sandbox DISABLED.**
- `swift test --filter` exits 0 when it matches nothing. Any claim that a filtered test ran must confirm a non-zero test count.

---

### Task 1: Core value types

**Files:**
- Create: `Sources/CoffeeBarCore/AgentSession.swift`
- Create: `Sources/CoffeeBarCore/PowerTypes.swift`
- Test: `Tests/CoffeeBarCoreTests/AgentSession_test.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AgentTool`, `SessionState`, `AgentSession`, `PowerSource`, `UserIntent`, `HoldSuppression`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/AgentSession_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func session(tool: AgentTool = .claudeCode,
                     sessionID: String = "abc123",
                     state: SessionState = .working) -> AgentSession {
    AgentSession(tool: tool, sessionID: sessionID, cwd: nil, repoName: nil,
                 pid: nil, state: state, stateEnteredAt: t0, lastEventAt: t0,
                 lastMessage: nil, attentionSince: nil, turnCount: 0)
}

@Test func idIsToolAndSessionJoinedByAColon() {
    // Handoff §5.1: sessions are keyed by (tool, sessionID). A collision
    // between two tools' identically-named sessions would merge two users'
    // sessions into one row.
    #expect(session(tool: .codex, sessionID: "xyz").id == "codex:xyz")
}

@Test func differentToolsWithTheSameSessionIDDoNotCollide() {
    #expect(session(tool: .claudeCode, sessionID: "same").id
            != session(tool: .cursor, sessionID: "same").id)
}

@Test func allSevenSessionStatesRoundTripThroughCoding() throws {
    // The wire format is the M2 ingest contract. A renamed case silently
    // breaks decoding of a session the app already stored.
    for state in [SessionState.starting, .working, .awaitingPermission,
                  .awaitingInput, .done, .failed, .stale] {
        let data = try JSONEncoder().encode(session(state: state))
        let back = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(back.state == state)
    }
}

@Test func sessionStateRawValuesArePinned() {
    // Pinned to literals, not to the enum, so renaming a case fails here
    // rather than silently changing the persisted format.
    #expect(SessionState.awaitingPermission.rawValue == "awaitingPermission")
    #expect(SessionState.awaitingInput.rawValue == "awaitingInput")
    #expect(SessionState.stale.rawValue == "stale")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentSession`
Expected: FAIL — compilation error, `cannot find 'AgentSession' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CoffeeBarCore/AgentSession.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which agent tool a session belongs to. Handoff §5.1.
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
    case cursor
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
```

Create `Sources/CoffeeBarCore/PowerTypes.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the machine is drawing power from.
public enum PowerSource: String, Codable, Sendable {
    case ac
    case battery
}

/// What the user last asked for through the menu-bar toggle.
public enum UserIntent: String, Codable, Sendable {
    case serve
    case stop
}

/// Why a requested hold is not being honoured.
///
/// Carries the measured value, not just the case, so the UI can say "battery
/// 18%, floor 20%" rather than something vague the user cannot check.
public enum HoldSuppression: Equatable, Sendable {
    case batteryFloor(percent: Int, floor: Int)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentSession`
Expected: PASS, 4 tests. Confirm the count is non-zero — a filter matching nothing also exits 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoffeeBarCore/AgentSession.swift Sources/CoffeeBarCore/PowerTypes.swift Tests/CoffeeBarCoreTests/AgentSession_test.swift
git commit -s -S -m "feat(core): add the session model and power value types"
```

---

### Task 2: PowerBroker — the pure decision function

**Files:**
- Create: `Sources/CoffeeBarCore/PowerBroker.swift`
- Test: `Tests/CoffeeBarCoreTests/PowerBroker_test.swift`

**Interfaces:**
- Consumes: `AgentSession`, `SessionState`, `PowerSource`, `UserIntent`, `HoldSuppression` (Task 1).
- Produces: `PowerInputs`, `DesiredPowerState`, `PowerBroker.decide(_:) -> DesiredPowerState`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/PowerBroker_test.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PowerBroker`
Expected: FAIL — `cannot find 'PowerBroker' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CoffeeBarCore/PowerBroker.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything the policy decision reads. Handoff §5.2.
///
/// Fields with no data source before M3/M5 (`thermalState`, `lidClosed`) are
/// deliberately absent rather than stubbed — see the M1 design spec §4.2.
public struct PowerInputs: Equatable, Sendable {
    public let sessions: [AgentSession]
    public let powerSource: PowerSource
    public let batteryPercent: Int?
    public let userIntent: UserIntent
    public let holdAwakeWhileBlocked: Bool
    public let batteryFloorPercent: Int

    public init(sessions: [AgentSession] = [],
                powerSource: PowerSource,
                batteryPercent: Int?,
                userIntent: UserIntent,
                holdAwakeWhileBlocked: Bool = false,
                batteryFloorPercent: Int = 20) {
        self.sessions = sessions
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.userIntent = userIntent
        self.holdAwakeWhileBlocked = holdAwakeWhileBlocked
        self.batteryFloorPercent = batteryFloorPercent
    }
}

/// The system state the app should bring about.
///
/// `displaySleepAssertion` exists and is always `false`. It is not removed,
/// because its presence is what the guard test asserts against: a future
/// change that starts holding the display assertion has to set this field,
/// and that goes red immediately.
public struct DesiredPowerState: Equatable, Sendable {
    public let idleSleepAssertion: Bool
    public let displaySleepAssertion: Bool
    public let suppression: HoldSuppression?

    public init(idleSleepAssertion: Bool,
                displaySleepAssertion: Bool = false,
                suppression: HoldSuppression? = nil) {
        self.idleSleepAssertion = idleSleepAssertion
        self.displaySleepAssertion = displaySleepAssertion
        self.suppression = suppression
    }
}

/// Pure policy. No I/O, no clock, no globals — handoff §5.2.
public enum PowerBroker {

    /// States that keep the machine awake, given the blocked-states knob.
    static func activeStates(holdAwakeWhileBlocked: Bool) -> Set<SessionState> {
        holdAwakeWhileBlocked
            ? [.starting, .working, .awaitingPermission, .awaitingInput]
            : [.starting, .working]
    }

    public static func decide(_ inputs: PowerInputs) -> DesiredPowerState {
        let active = activeStates(holdAwakeWhileBlocked: inputs.holdAwakeWhileBlocked)
        let sessionsWantAwake = inputs.sessions.contains { active.contains($0.state) }

        // M1 note: `sessions` is always empty, so this reduces to the toggle.
        // The OR is provisional — M2 must decide whether an explicit `.stop`
        // outranks an active session. See the design spec §5.1.
        let wantsHold = inputs.userIntent == .serve || sessionsWantAwake

        guard wantsHold else {
            return DesiredPowerState(idleSleepAssertion: false)
        }

        // §8.1: the battery bullet carries no lid-closed qualifier, unlike
        // three of its four siblings, so it governs the plain assertion too.
        // A nil reading never suppresses: a desktop has no battery.
        if inputs.powerSource == .battery,
           let percent = inputs.batteryPercent,
           percent <= inputs.batteryFloorPercent {
            return DesiredPowerState(
                idleSleepAssertion: false,
                suppression: .batteryFloor(percent: percent,
                                           floor: inputs.batteryFloorPercent))
        }

        return DesiredPowerState(idleSleepAssertion: true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PowerBroker`
Expected: PASS, 11 tests.

- [ ] **Step 5: Mutation-check the two load-bearing guards**

Do these one at a time, reverting between them.

1. In `decide`, change `percent <= inputs.batteryFloorPercent` to `percent < inputs.batteryFloorPercent`. Run `swift test --filter batteryFloorSuppressesAtOrBelowTheFloor` alone. Expected: RED. Revert.
2. Change `DesiredPowerState`'s `displaySleepAssertion` default to `true`. Run `swift test --filter displaySleepAssertionIsNeverRequested` alone. Expected: RED. Revert.

Confirm each run reports a non-zero test count before trusting its result.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarCore/PowerBroker.swift Tests/CoffeeBarCoreTests/PowerBroker_test.swift
git commit -s -S -m "feat(core): add PowerBroker, the pure power-policy decision"
```

---

### Task 3: HoldController — the latching release rule

**Files:**
- Create: `Sources/CoffeeBarCore/HoldController.swift`
- Test: `Tests/CoffeeBarCoreTests/HoldController_test.swift`

**Interfaces:**
- Consumes: `PowerBroker.decide`, `PowerInputs`, `DesiredPowerState`, `UserIntent`, `HoldSuppression`, `PowerSource`, `AgentSession` (Tasks 1–2).
- Produces: `HoldController` with `intent`, `lastSuppression`, `mutating func userToggled(to:)`, `mutating func evaluate(powerSource:batteryPercent:sessions:holdAwakeWhileBlocked:batteryFloorPercent:) -> DesiredPowerState`.

`PowerBroker` is pure and has no memory, so the no-auto-re-arm rule cannot live there. It lives here.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarCoreTests/HoldController_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarCore

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

@Test func togglingOnClearsTheStaleSuppressionReason() {
    var c = HoldController()
    c.userToggled(to: .serve)
    _ = c.evaluate(powerSource: .battery, batteryPercent: 12)
    c.userToggled(to: .serve)
    #expect(c.lastSuppression == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HoldController`
Expected: FAIL — `cannot find 'HoldController' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CoffeeBarCore/HoldController.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns the user's intent and the latching release rule.
///
/// `PowerBroker` is a pure function with no memory, so "release once and do
/// not re-arm" cannot live there. When the broker reports a suppression this
/// controller drops the intent back to `.stop`, which means a recovering
/// battery or a return to AC power does not silently switch the hold back on.
/// The user re-arms by toggling.
public struct HoldController: Equatable, Sendable {
    public private(set) var intent: UserIntent
    public private(set) var lastSuppression: HoldSuppression?

    public init(intent: UserIntent = .stop) {
        self.intent = intent
        self.lastSuppression = nil
    }

    /// Records an explicit user action. Toggling to `.serve` clears any stale
    /// reason so the panel does not keep explaining a release the user has
    /// already answered.
    public mutating func userToggled(to intent: UserIntent) {
        self.intent = intent
        if intent == .serve { lastSuppression = nil }
    }

    /// Decides, then latches. Returns what the caller should apply.
    public mutating func evaluate(powerSource: PowerSource,
                                  batteryPercent: Int?,
                                  sessions: [AgentSession] = [],
                                  holdAwakeWhileBlocked: Bool = false,
                                  batteryFloorPercent: Int = 20) -> DesiredPowerState {
        let state = PowerBroker.decide(PowerInputs(
            sessions: sessions,
            powerSource: powerSource,
            batteryPercent: batteryPercent,
            userIntent: intent,
            holdAwakeWhileBlocked: holdAwakeWhileBlocked,
            batteryFloorPercent: batteryFloorPercent))

        if let suppression = state.suppression {
            lastSuppression = suppression
            intent = .stop
        }
        return state
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HoldController`
Expected: PASS, 8 tests.

- [ ] **Step 5: Mutation-check the latch**

Delete the `intent = .stop` line inside `evaluate`. Run
`swift test --filter recoveringBatteryDoesNotReArmTheHold` alone.
Expected: RED. Revert.

- [ ] **Step 6: Commit**

```bash
git add Sources/CoffeeBarCore/HoldController.swift Tests/CoffeeBarCoreTests/HoldController_test.swift
git commit -s -S -m "feat(core): add HoldController with the latching release rule"
```

---

### Task 4: SystemPowerReader — the IOKit power source

**Files:**
- Create: `Sources/CoffeeBarPower/SystemPowerReader.swift`
- Test: `Tests/CoffeeBarPowerTests/SystemPowerReader_test.swift`

**Interfaces:**
- Consumes: `PowerSource` (Task 1).
- Produces: `PowerReading` (`source`, `percent`), protocol `PowerReading Providing` named `PowerReadingProviding` with `func read() -> PowerReading`, and `SystemPowerReader` conforming to it.

Runs in parallel with Tasks 2 and 3 — it needs only Task 1.

- [ ] **Step 1: Write the failing test**

Create `Tests/CoffeeBarPowerTests/SystemPowerReader_test.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import CoffeeBarCore
@testable import CoffeeBarPower

@Test func aRealReadingIsInternallyConsistent() {
    // Reads the live machine, so it asserts invariants rather than a fixed
    // value. A percent outside 0...100, or a battery percent on a machine
    // reporting no battery at all, is a real defect.
    let reading = SystemPowerReader().read()
    if let percent = reading.percent {
        #expect(percent >= 0 && percent <= 100,
                "percent out of range: \(percent)")
    }
}

@Test func repeatedReadsAgreeOnWhetherABatteryExists() {
    // A battery does not appear and vanish between two calls. Disagreement
    // means the parse is reading a different power source each time — the
    // ordering bug that index-based access into an IOKit list produces.
    let first = SystemPowerReader().read()
    let second = SystemPowerReader().read()
    #expect((first.percent == nil) == (second.percent == nil))
}

@Test func readingIsCheapEnoughToPoll() {
    // The app polls this on a timer. A read that blocks would freeze the UI.
    let start = Date()
    _ = SystemPowerReader().read()
    #expect(Date().timeIntervalSince(start) < 0.5)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SystemPowerReader`
Expected: FAIL — `cannot find 'SystemPowerReader' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CoffeeBarPower/SystemPowerReader.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit.ps
import CoffeeBarCore

/// A single power-source sample.
public struct PowerReading: Equatable, Sendable {
    public let source: PowerSource
    /// `nil` where the machine reports no battery, such as a desktop.
    public let percent: Int?

    public init(source: PowerSource, percent: Int?) {
        self.source = source
        self.percent = percent
    }
}

/// Injection seam: the app depends on this, tests supply a fake.
public protocol PowerReadingProviding: Sendable {
    func read() -> PowerReading
}

/// Reads battery percentage and AC state from IOKit.
public struct SystemPowerReader: PowerReadingProviding {

    public init() {}

    public func read() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef]
        else {
            // Unreadable is reported as AC with no battery: the safe default,
            // because it never suppresses a hold the user asked for.
            return PowerReading(source: .ac, percent: nil)
        }

        for source in sources {
            // `IOPSGetPowerSourceDescription` is an unaudited Get — the result
            // must be taken unretained. See docs/ENGINEERING-NOTES.md.
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }

            let onAC = (description[kIOPSPowerSourceStateKey] as? String)
                == kIOPSACPowerValue

            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }

            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            return PowerReading(source: onAC ? .ac : .battery, percent: percent)
        }

        return PowerReading(source: .ac, percent: nil)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SystemPowerReader`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CoffeeBarPower/SystemPowerReader.swift Tests/CoffeeBarPowerTests/SystemPowerReader_test.swift
git commit -s -S -m "feat(power): add SystemPowerReader over IOKit power sources"
```

---

### Task 5: CoffeeBarApp target, and remove the POC

**Files:**
- Create: `Sources/CoffeeBarApp/main.swift`
- Create: `Sources/CoffeeBarApp/ServingModel.swift`
- Create: `Sources/CoffeeBarApp/PanelView.swift`
- Create: `Sources/CoffeeBarApp/MenuBarGlyphs.swift`
- Modify: `Package.swift`
- Delete: `Sources/CoffeeBarMenuBarPOC/main.swift`

**Interfaces:**
- Consumes: `HoldController`, `HoldSuppression`, `DesiredPowerState` (Core); `SystemPowerReader`, `PowerReadingProviding`, `AssertionHolder` (Power).
- Produces: the `coffee-bar` executable product.

The POC is deleted, not adapted. Its own header forbids building on it.

- [ ] **Step 1: Update `Package.swift`**

Replace the `products:` and `targets:` arrays so that `CoffeeBarMenuBarPOC` is gone and `CoffeeBarApp` exists:

```swift
    products: [
        .executable(name: "coffee-bar-probe", targets: ["CoffeeBarProbe"]),
        .executable(name: "coffee-bar", targets: ["CoffeeBarApp"]),
        .library(name: "CoffeeBarCore", targets: ["CoffeeBarCore"]),
    ],
    targets: [
        .target(name: "CoffeeBarCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "CoffeeBarPower", dependencies: ["CoffeeBarCore"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarProbe", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "CoffeeBarApp", dependencies: ["CoffeeBarPower"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarCoreTests", dependencies: ["CoffeeBarCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CoffeeBarPowerTests", dependencies: ["CoffeeBarPower"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
```

- [ ] **Step 2: Delete the POC target**

```bash
git rm -r Sources/CoffeeBarMenuBarPOC
```

- [ ] **Step 3: Create the glyph loader**

Create `Sources/CoffeeBarApp/MenuBarGlyphs.swift` — same approach the POC proved, because the bundle is assembled by `cp` rather than by an asset catalogue:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Loads the vendored template glyphs from the assembled bundle by path.
///
/// `NSImage(named:)` needs an asset catalogue or a registered bundle resource;
/// `scripts/build-app.sh` copies the art in with `cp`, so lookup is by path.
@MainActor
enum MenuBarGlyphs {
    private static var cache: [String: NSImage] = [:]
    private static let glyphSize = NSSize(width: 16, height: 16)

    static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let resources = Bundle.main.resourcePath else { return nil }

        for ext in ["pdf", "png"] {
            let path = (resources as NSString).appendingPathComponent("\(name).\(ext)")
            guard let image = NSImage(contentsOfFile: path) else { continue }
            // Load-bearing: AppKit tints and inverts template images for light
            // and dark menu bars. Never tint them by hand.
            image.isTemplate = true
            image.size = glyphSize
            cache[name] = image
            return image
        }
        return nil
    }
}
```

- [ ] **Step 4: Create the model**

Create `Sources/CoffeeBarApp/ServingModel.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import CoffeeBarCore
import CoffeeBarPower

// `import Observation` is required: the `@Observable` macro lives there. The
// POC got it transitively from `import SwiftUI` in the same file. This file
// has no SwiftUI import, so it must ask for Observation directly.

/// Wires the reader and the controller to the assertion.
///
/// This type holds no policy. It samples power, asks `HoldController` what the
/// state should be, and makes IOKit match. Every decision lives in
/// `CoffeeBarCore`.
@MainActor
@Observable
final class ServingModel {
    private let holder = AssertionHolder()
    private let reader: any PowerReadingProviding
    private var controller = HoldController()

    private(set) var isServing = false
    private(set) var reading: PowerReading
    private(set) var suppression: HoldSuppression?

    init(reader: any PowerReadingProviding = SystemPowerReader()) {
        self.reader = reader
        self.reading = reader.read()
    }

    /// Bound to the toggle. `isServing` reflects what actually happened, not
    /// what was asked for: a refused hold leaves the switch off.
    var serving: Bool {
        get { isServing }
        set {
            controller.userToggled(to: newValue ? .serve : .stop)
            refresh()
        }
    }

    /// Re-samples power and reconciles the assertion. Safe to call on a timer.
    func refresh() {
        reading = reader.read()
        let desired = controller.evaluate(powerSource: reading.source,
                                          batteryPercent: reading.percent)
        suppression = controller.lastSuppression

        if desired.idleSleepAssertion {
            isServing = holder.acquire()
        } else {
            holder.release()
            isServing = false
        }
    }
}
```

- [ ] **Step 5: Create the panel**

Create `Sources/CoffeeBarApp/PanelView.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import CoffeeBarCore

// `import AppKit` is explicit for `NSApplication.shared.terminate`. Do not
// rely on SwiftUI re-exporting it.

struct MenuBarLabel: View {
    let isServing: Bool

    var body: some View {
        if let glyph = MenuBarGlyphs.image(
            named: isServing ? "coffee-bar-servingTemplate" : "coffee-bar-idleTemplate") {
            Image(nsImage: glyph)
        } else {
            Image(systemName: isServing ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
    }
}

struct PanelView: View {
    @Bindable var model: ServingModel

    private var batteryLine: String {
        let charge = model.reading.percent.map { "\($0)%" } ?? "no battery"
        return "\(charge) · \(model.reading.source == .ac ? "AC power" : "battery")"
    }

    /// Rendered from the enum, never from free text, so the reason the panel
    /// shows is the reason the controller decided.
    private var suppressionLine: String? {
        switch model.suppression {
        case .batteryFloor(let percent, let floor):
            return "Released at \(percent)% — coffee-bar stops holding below \(floor)%."
        case nil:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Serving", isOn: $model.serving)
                .toggleStyle(.switch)
                .font(.headline)

            Text(model.isServing
                 ? "Holding the system awake. The display may still sleep."
                 : "Not holding any assertion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let line = suppressionLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Label(batteryLine, systemImage: "bolt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit coffee-bar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { model.refresh() }
    }
}
```

- [ ] **Step 6: Create the app entry point**

Create `Sources/CoffeeBarApp/main.swift`:

```swift
// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Combine
import Foundation

// `import Combine` is required for `Timer.publish`, which returns a Combine
// `TimerPublisher`. SwiftUI's `.onReceive` accepts it but does not supply it.

/// Re-samples power so a battery crossing the floor is noticed without the
/// user opening the panel. 30s is frequent enough to matter and cheap enough
/// to ignore — `SystemPowerReader.read()` is a non-blocking IOKit call.
private let refreshInterval: TimeInterval = 30

struct CoffeeBarApp: App {
    @State private var model = ServingModel()

    private let ticker = Timer.publish(every: refreshInterval, on: .main, in: .common)
        .autoconnect()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
                .onReceive(ticker) { _ in model.refresh() }
        } label: {
            MenuBarLabel(isServing: model.isServing)
        }
        .menuBarExtraStyle(.window)
    }
}

// SwiftPM treats `main.swift` as top-level code, which rules out `@main`.
// `App.main()` is the documented equivalent.
CoffeeBarApp.main()
```

- [ ] **Step 7: Build and run the full suite**

Run: `swift build && swift build -c release && swift test`
Expected: all three succeed, zero warnings, and the suite total has grown by the new tests.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/CoffeeBarApp
git rm -r --cached Sources/CoffeeBarMenuBarPOC 2>/dev/null || true
git commit -s -S -m "feat(app): add the CoffeeBarApp menu-bar target, remove the POC"
```

---

### Task 6: Bundle assembly and manual acceptance

**Files:**
- Create: `scripts/build-app.sh`
- Delete: `scripts/build-poc-app.sh`

**Interfaces:**
- Consumes: the `coffee-bar` product (Task 5).
- Produces: `build/CoffeeBar.app`.

- [ ] **Step 1: Create the build script**

Copy `scripts/build-poc-app.sh` to `scripts/build-app.sh` and change exactly these values, keeping every verification step:

- `PRODUCT="coffee-bar"`
- `APP_NAME="CoffeeBar"`
- `BUNDLE_ID="com.coffeebar.app"`
- `CFBundleDisplayName` becomes `coffee-bar`
- `CFBundleShortVersionString` becomes `0.1.0`
- Drop the `spikes-note` header; replace it with a note that signing and
  notarisation are M4.

Keep unchanged, because each one guards a real failure: `set -euo pipefail`,
`command cp -f` (an interactive `cp -i` alias declines the copy and still exits
0), the `[ -x ... ]` binary check, the glyph count check, the two required-glyph
checks, `plutil -lint`, and the `LSUIElement` extract check.

- [ ] **Step 2: Delete the POC script**

```bash
git rm scripts/build-poc-app.sh
```

- [ ] **Step 3: Build the bundle**

Run: `scripts/build-app.sh`
Expected: it prints the glyph count, `LSUIElement=true (no Dock icon)`, and the built path.

- [ ] **Step 4: Manual acceptance on real hardware**

Record the actual output of each step in the report.

1. `open build/CoffeeBar.app` — a cup glyph appears in the menu bar and no Dock icon appears.
2. Toggle Serving on. Then run:
   `pmset -g assertions | grep -i coffee-bar`
   Expected: a line naming `coffee-bar is serving`.
3. Confirm the display assertion is absent:
   `pmset -g assertions | grep -i PreventUserIdleDisplaySleep`
   Expected: no line attributable to coffee-bar.
4. Toggle Serving off, re-run the command from step 2. Expected: no output.
5. Quit from the panel. Expected: no coffee-bar assertion remains.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-app.sh
git commit -s -S -m "build(app): assemble CoffeeBar.app, retire the POC script"
```

---

## Plan self-review

**Spec coverage.** Design §3 architecture → Tasks 1–5. §4.1 session types → Task 1. §4.2 decision types → Task 2. §5.1 wake predicate → Task 2. §5.2 battery floor → Task 2. §5.3 latching release → Task 3. §5.4 what the user sees → Task 5 (`suppressionLine`, rendered from the enum). §6 required guards → Tasks 1–3 tests. §7 packaging → Task 6. Deletions from design §1 → Tasks 5 and 6.

**One gap found and closed:** design §6 lists eight required guards; the plan's Task 2 and Task 3 tests cover all eight, but `wakePredicateHonoursOnlyStartingAndWorking` needed the `done`/`failed`/`stale` case split out so the knob cannot mask it. Added as `doneAndFailedNeverHoldEvenWithTheKnobSet`.

**Placeholder scan.** No TBD, no "handle edge cases", no "similar to Task N". Every code step carries the code.

**Type consistency.** `PowerSource`, `UserIntent`, `HoldSuppression` are defined once in Task 1 and used with the same spelling in Tasks 2–5. `PowerReading` is defined in Task 4 and consumed in Task 5's `ServingModel`. `HoldController.evaluate` is declared in Task 3 with the same argument labels Task 5 calls it with.

**Known deviation from the design spec.** Design §4.2 says `DesiredPowerState` omits fields M1 cannot honour. The plan keeps `displaySleepAssertion` — omitting it would leave the §6.1 guard with nothing to assert against. `sleepDisabled`, `demoteSet`, `suspendSet` and `spotlightSuppressed` are omitted as the spec requires.
