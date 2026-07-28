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
        if self.intent == .serve { lastSuppression = nil }
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
