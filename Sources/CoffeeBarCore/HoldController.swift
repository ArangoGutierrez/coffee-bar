// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns the user's intent and the rule that cancels a refused request.
///
/// `PowerBroker` is a pure function with no memory, so "release once and do
/// not re-arm" cannot live there. When the broker suppresses a `.serve` hold
/// this controller cancels that one-off request, so a recovering battery or a
/// return to AC power does not silently switch an unconditional hold back on.
/// The user asks again by moving the control.
///
/// The cancel applies to `.serve` ONLY, and it returns the user to the STANDING
/// position they were on rather than to `.stop` — see `evaluate` for both
/// halves, which are separate decisions.
public struct HoldController: Equatable, Sendable {
    public private(set) var intent: UserIntent
    public private(set) var lastSuppression: HoldSuppression?

    /// The position a cancelled `.serve` returned to, for the suppression now
    /// recorded in `lastSuppression`. `nil` when that suppression cancelled no
    /// click.
    ///
    /// `lastSuppression` alone cannot separate the two situations, and the
    /// comment on `evaluate` says why: it is recorded for a refused CLICK and
    /// for a hold nobody asked for. The panel needs the difference. In the first
    /// case coffee-bar moved the user's control for them; in the second it did
    /// not, and a sentence claiming it did would be false.
    ///
    /// Written in LOCKSTEP with `lastSuppression`, inside the same branch, so a
    /// NEW suppression that cancels nothing clears it. Without that a refused
    /// click replays onto every later suppression the user never caused —
    /// `aSuppressionThatCancelsNoClickClearsAStaleCancel` goes red on exactly
    /// that.
    ///
    /// It carries the POSITION rather than a `Bool`, so the panel names where
    /// the control landed without reading `intent` as a second source that the
    /// next toggle can put out of step. `standing` stays private: this is
    /// non-`nil` only after a real cancel, so a check still reaches the position
    /// through behaviour.
    public private(set) var cancelledServeReturnedTo: UserIntent?

    /// The position a refused `.serve` returns to.
    ///
    /// `.serve` is a ONE-OFF request; `.auto` and `.stop` are STANDING
    /// instructions that hold until the user changes them. This records the
    /// standing instruction that was in force when the one-off arrived, so
    /// cancelling the one-off puts the user back where they were.
    ///
    /// It never records `.serve`, and that is what keeps the latch honest. A
    /// naive "restore whatever the intent was" reads `.serve` after a second On
    /// click and restores the very request the floor refused —
    /// `aSecondOnClickCannotMakeServeItsOwnFallback` goes red on exactly that.
    ///
    /// Private, so a check can only reach it through behaviour.
    private var standing: UserIntent

    /// `.auto` by default: a fresh install follows the agent sessions until
    /// the user says otherwise.
    ///
    /// A controller built at `.serve` stands at `.stop`. Nothing constructs one,
    /// and `.stop` is the safe direction: a `.serve` fallback would re-arm the
    /// hold the floor has just refused.
    public init(intent: UserIntent = .auto) {
        self.intent = intent
        self.standing = intent == .serve ? .stop : intent
        self.lastSuppression = nil
        self.cancelledServeReturnedTo = nil
    }

    /// Records an explicit user action. Toggling to `.serve` clears any stale
    /// reason so the panel does not keep explaining a release the user has
    /// already answered.
    ///
    /// The two other positions are STANDING instructions, so each one also
    /// becomes the position a later refused `.serve` returns to.
    ///
    /// `cancelledServeReturnedTo` clears for EVERY position, unlike
    /// `lastSuppression`. Once the user moves the control by hand, "coffee-bar
    /// moved your control" is no longer the last thing that happened, and a
    /// record naming the position they have just left states a move that did not
    /// happen — `movingTheControlByHandClearsTheRefusalRecord` measures it from
    /// the Off click, which `togglingOffStopsTheHoldAndKeepsTheReason` requires
    /// `lastSuppression` to survive.
    public mutating func userToggled(to intent: UserIntent) {
        self.intent = intent
        cancelledServeReturnedTo = nil
        if self.intent == .serve {
            lastSuppression = nil
        } else {
            standing = intent
        }
    }

    /// Decides, then cancels a refused `.serve`. Returns what the caller should
    /// apply.
    ///
    /// The cancel is narrow on purpose, and the two cases are not symmetric:
    ///
    /// `.serve` is a ONE-OFF request that the battery floor overrode. Cancelling
    /// it stops a recovering battery from silently re-arming a hold the user
    /// asked for once and has since watched fail. Re-arming is a behaviour they
    /// did not ask for and cannot see coming, so they ask again by hand.
    ///
    /// `.auto` is a CONTINUOUS instruction, and `PowerBroker` re-reads the
    /// floor on every single call — so the floor is already enforced without
    /// any memory here. Cancelling it would buy nothing and cost the whole
    /// feature: one dip below the floor would pin the intent to `.stop` for
    /// the life of the process, every later session would be ignored, and
    /// `ServingModel.reason(_:stillTrueOf:)` hides the battery line as soon as
    /// the reading recovers — so the panel would show a dead app and no reason
    /// for it. Quitting and relaunching would be the only cure.
    ///
    /// **The cancel returns to `standing`, not to `.stop`.** That is audit
    /// finding I4, and it is a separate question from whether to cancel at all.
    /// `.stop` is a THIRD position: neither the one-off the user asked for nor
    /// the standing instruction they were on. Landing there from a FAILED
    /// request leaves them holding strictly less than before they touched the
    /// control — a user on `.auto` who clicks On once below the floor ends up
    /// with the same Mac asleep under the same working agent that `.auto` would
    /// have kept awake. `askingForAHoldNeverLeavesLessHeldThanAskingForNothing`
    /// measures exactly that, one click apart.
    ///
    /// Returning to `.auto` reintroduces nothing. What must not come back is
    /// `.serve`'s defining property — a hold that ignores the session list — and
    /// it does not: `aRefusedServeNeverComesBackAsAnUnconditionalHold` recovers
    /// the battery with an EMPTY list and stays released. What does come back is
    /// the session-gated `.auto` behaviour the user was already running, which
    /// the paragraph above already rules correct. A user who stood on `.stop`
    /// returns to `.stop`, so the absolute veto still survives a failed click.
    ///
    /// `lastSuppression` is recorded for BOTH, because the panel has to be able
    /// to explain a refusal whichever position asked for the hold. That is also
    /// why it cannot be the whole story: recorded for both, it cannot say WHICH
    /// happened. A refused click and a hold nobody asked for reach the panel as
    /// the same value, so the panel renders one sentence for a user whose
    /// control coffee-bar just moved and for a user who touched nothing.
    /// `cancelledServeReturnedTo` carries that difference, and is written here
    /// in lockstep — set on the cancel, cleared on any other suppression.
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
            if intent == .serve {
                intent = standing
                cancelledServeReturnedTo = standing
            } else {
                // Not an omission. This suppression cancelled no click, so any
                // earlier cancel is no longer what the panel is explaining.
                cancelledServeReturnedTo = nil
            }
        }
        return state
    }
}
