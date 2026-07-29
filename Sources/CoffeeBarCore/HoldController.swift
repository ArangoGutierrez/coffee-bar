// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns the user's intent and the latching release rule.
///
/// `PowerBroker` is a pure function with no memory, so "release once and do
/// not re-arm" cannot live there. When the broker suppresses a `.serve` hold
/// this controller drops the intent back to `.stop`, so a recovering battery
/// or a return to AC power does not silently switch the hold back on. The user
/// re-arms by moving the control.
///
/// The latch applies to `.serve` ONLY — see `evaluate`.
public struct HoldController: Equatable, Sendable {
    public private(set) var intent: UserIntent
    public private(set) var lastSuppression: HoldSuppression?

    /// `.auto` by default: a fresh install follows the agent sessions until
    /// the user says otherwise.
    public init(intent: UserIntent = .auto) {
        self.intent = intent
        self.lastSuppression = nil
    }

    /// Records an explicit user action. Toggling to `.serve` clears any stale
    /// reason so the panel does not keep explaining a release the user has
    /// already answered.
    public mutating func userToggled(to intent: UserIntent) {
        self.intent = intent
        if self.intent == .serve { lastSuppression = nil }
    }

    /// Decides, then latches `.serve`. Returns what the caller should apply.
    ///
    /// The latch is narrow on purpose, and the two cases are not symmetric:
    ///
    /// `.serve` is a ONE-OFF request that the battery floor overrode. Latching
    /// it to `.stop` stops a recovering battery from silently re-arming a hold
    /// the user asked for once and has since watched fail. Re-arming is a
    /// behaviour they did not ask for and cannot see coming, so they re-arm by
    /// hand.
    ///
    /// `.auto` is a CONTINUOUS instruction, and `PowerBroker` re-reads the
    /// floor on every single call — so the floor is already enforced without
    /// any memory here. Latching it would buy nothing and cost the whole
    /// feature: one dip below the floor would pin the intent to `.stop` for
    /// the life of the process, every later session would be ignored, and
    /// `ServingModel.reason(_:stillTrueOf:)` hides the battery line as soon as
    /// the reading recovers — so the panel would show a dead app and no reason
    /// for it. Quitting and relaunching would be the only cure.
    ///
    /// `lastSuppression` is recorded for BOTH, because the panel has to be able
    /// to explain a refusal whichever position asked for the hold.
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
            if intent == .serve { intent = .stop }
        }
        return state
    }
}
