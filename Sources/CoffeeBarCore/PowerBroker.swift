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
                userIntent: UserIntent = .auto,
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

        // §5.1 deferred one question to M2: does an explicit `.stop` outrank an
        // active session? It does. The M1 OR is gone, and the three positions
        // rank differently:
        //
        //   `.stop`  — never hold. The off switch is ABSOLUTE. coffee-bar
        //              overrides the machine's own sleep policy, so a product
        //              that then ignores "off" because some background session
        //              disagrees is a trust failure, not a convenience.
        //   `.serve` — always hold. An explicit request outranks a quiet
        //              session list, so picking On mid-task does not stop
        //              working the moment the last session goes idle.
        //   `.auto`  — the sessions decide. The default, and what the product
        //              is for.
        //
        // Both remaining paths still answer to the battery floor below: it is a
        // safety limit on the machine, not a veto on one control position.
        //
        // A `switch` rather than a boolean expression, deliberately. The
        // expression this replaces silently absorbed a third case — `.auto`
        // is not `.serve`, so it fell into the session predicate and happened
        // to be right. A fourth case cannot be quietly right or quietly wrong
        // here: it stops compiling until somebody decides where it belongs.
        let wantsHold: Bool
        switch inputs.userIntent {
        case .stop:
            wantsHold = false
        case .serve:
            wantsHold = true
        case .auto:
            wantsHold = sessionsWantAwake
        }

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
