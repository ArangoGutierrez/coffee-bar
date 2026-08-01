// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why a `.serve` was cancelled, and where the control went.
///
/// The two cases are NOT the same event, and the panel must never word them
/// alike. `PowerBroker` holds for `.serve` unconditionally, so a click above the
/// floor is honoured and the machine really is held. Both histories end at the
/// same suppression branch in `evaluate`, and a record that keeps only the
/// position cannot tell them apart — which is exactly the ambiguity
/// `lastSuppression` already has one level up.
///
/// Carrying the outcome and the position in ONE value keeps them from drifting.
/// Two fields — "was it refused?" beside "where did it land?" — can be updated
/// singly and then disagree.
public enum ServeCancellation: Equatable, Sendable {
    /// The floor refused the click. No hold ever existed.
    case refused(returnedTo: UserIntent)

    /// The click was honoured and the machine was held. The floor released it
    /// later, as the battery drained. This is the normal end of the On
    /// position, not an edge case.
    case released(returnedTo: UserIntent)
}

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

    /// How the `.serve` now cancelled ended, and where the control went, for the
    /// suppression recorded in `lastSuppression`. `nil` when that suppression
    /// cancelled no click.
    ///
    /// `lastSuppression` alone cannot separate the situations, and the comment
    /// on `evaluate` says why: it is recorded for a refused CLICK and for a hold
    /// nobody asked for. The panel needs the difference. In the first case
    /// coffee-bar moved the user's control for them; in the second it did not,
    /// and a sentence claiming it did would be false.
    ///
    /// It carries the OUTCOME as well as the position, and both are load
    /// bearing. A cancelled `.serve` is reached from two histories — a click the
    /// floor refused outright, and a click that was honoured for hours and then
    /// released on a draining battery. `ServeCancellation` says which.
    ///
    /// Its LIFETIME is the suppression EPISODE it explains. It is written when
    /// the cancel happens and cleared once the reading PROVES that suppression
    /// is over — see `hasEnded`, which reads the record's own suppression before
    /// `evaluate` records a new one over it.
    ///
    /// **That is not the same rule as `ServingModel.reason(_:stillTrueOf:)`, and
    /// the difference is deliberate rather than an oversight.** The filter one
    /// layer up HIDES a sentence and shows it again when the reading comes back;
    /// this DESTROYS a record, and nothing brings it back. So the two use the
    /// same comparison but not the same polarity: the filter may drop a line on
    /// a reading it cannot interpret, because it costs a blank line for one
    /// tick, while this must keep the record until something proves the episode
    /// ended. The state can therefore outlive the sentence by a tick. It can
    /// never be the other way round, which is the direction that would put a
    /// false claim on screen.
    ///
    /// It was written in lockstep with `lastSuppression` INSIDE the same branch
    /// until audit findings 1 and 2, which are one defect with two faces.
    /// Clearing it on any suppression that cancelled no click wiped a LIVE
    /// record on the next hook event, which lands sub-second under a working
    /// agent — so the disclosure died in exactly the case it targets, because
    /// the user clicks On precisely when an agent is running.
    /// `aLaterSuppressionUnderAutoKeepsALiveRefusalOnRecord` goes red on that.
    /// Clearing it ONLY there left it on record for ever the rest of the time:
    /// with no session `PowerBroker` returns early, the branch never runs, and
    /// the refusal replays days later onto a reading it does not name —
    /// `aRecoveryAboveTheFloorClearsTheCancelForGood` goes red on that half, and
    /// `aRefusalFromAnEarlierDrainNeverReturnsAtALaterOne` measures the sentence
    /// the user reads. The two halves need ONE rule, not two clearing sites.
    ///
    /// `standing` stays private: this is non-`nil` only after a real cancel, so
    /// a check still reaches the position through behaviour.
    public private(set) var cancelledServe: ServeCancellation?

    /// Whether the `.serve` now in force has ever produced a hold.
    ///
    /// This is the ONLY thing that separates a refusal from a release, and
    /// nothing else in reach can stand in for it. `lastSuppression` records no
    /// success. `intent` is moved off `.serve` by the cancel itself. The model's
    /// `isServing` is the CURRENT hold, so by the time the panel reads it the
    /// hold is gone on BOTH paths and it says `false` either way.
    ///
    /// Set from the ACTUAL hold reported by the caller, never from the desired
    /// state. A `PowerBroker` decision to hold is a request to IOKit, and IOKit
    /// can refuse it: `AssertionHolder.acquire()` returns `false` and nothing is
    /// ever held. Counting the desire as a hold makes the panel announce the
    /// release of an assertion that never existed, beside its own line saying
    /// nothing is held — `aHoldThatWasNeverTakenIsNotCalledAReleasedHold`
    /// measures exactly that.
    ///
    /// **`userToggled(to: .serve)` clearing it is the whole contract:** a new
    /// click is a new request and is judged on its own outcome, and
    /// `aFreshOnClickRefusedAfterAnEarlierHoldSaysRefusedNotReleased` goes red
    /// when that clear goes away.
    ///
    /// It is deliberately NOT cleared by the cancel. Between a cancel and the
    /// next click `intent` is never `.serve`, so nothing reads this — measured:
    /// clearing it there survives the whole suite, which makes it a line no
    /// check can justify. Any FUTURE path that puts `intent` back to `.serve`
    /// without going through `userToggled` has to clear this itself.
    ///
    /// Private: it is an intermediate, and `cancelledServe` above is the answer
    /// it exists to produce.
    private var serveHasHeld = false

    /// Whether the PREVIOUS evaluate under this same request asked for a hold.
    ///
    /// This is the attribution half, and without it the confirmation half lies
    /// in the other direction. `assertionIsHeld` describes the hold running when
    /// `evaluate` is called, which may belong to the position the user was on
    /// BEFORE they clicked: `.auto` holds for a working session, the battery
    /// crosses the floor between ticks, and the click that follows is refused at
    /// click time yet arrives while that older hold is still up. Crediting it to
    /// the click names the wrong cause —
    /// `aHoldInheritedFromAutoIsNotCreditedToALaterRefusedClick` goes red on it.
    ///
    /// The two signals arrive one tick apart, which is why both are needed: the
    /// desire is recorded on the evaluate that asks, and the confirmation can
    /// only arrive on the next one, after the caller has tried to acquire.
    private var serveDesiredHold = false

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
        self.cancelledServe = nil
    }

    /// Records an explicit user action. Toggling to `.serve` clears any stale
    /// reason so the panel does not keep explaining a release the user has
    /// already answered.
    ///
    /// The two other positions are STANDING instructions, so each one also
    /// becomes the position a later refused `.serve` returns to.
    ///
    /// `cancelledServe` clears for EVERY position, unlike `lastSuppression`.
    /// Once the user moves the control by hand, "coffee-bar moved your control"
    /// is no longer the last thing that happened, and a record naming the
    /// position they have just left states a move that did not happen —
    /// `movingTheControlByHandClearsTheRefusalRecord` measures it from the Off
    /// click, which `togglingOffStopsTheHoldAndKeepsTheReason` requires
    /// `lastSuppression` to survive.
    ///
    /// A new `.serve` also clears both hold flags: this click has served nothing
    /// yet, and inheriting the last one's success would report the next refusal
    /// as a release.
    ///
    /// **A `.serve` written while `.serve` is already in force is NOT a new
    /// click**, and the flags survive it — audit finding 3. A segmented SwiftUI
    /// picker writes its binding on a re-tap of the segment that is ALREADY
    /// selected, measured with a synthesised NSEvent, so the panel reaches this
    /// with one tap on a control that never moves. Treating that as a new
    /// request discards the memory of a hold this same request really won, and
    /// the release that follows is then announced as a refusal —
    /// `aRepeatedOnClickKeepsTheHoldItAlreadyWon` and
    /// `aRepeatedOnClickNeverTurnsAReleaseIntoARefusal` go red on it. The
    /// previous position has to be read BEFORE the assignment below, which is
    /// why the test cannot be written against `self.intent` in the branch.
    public mutating func userToggled(to intent: UserIntent) {
        let wasServing = self.intent == .serve
        self.intent = intent
        cancelledServe = nil
        if self.intent == .serve {
            lastSuppression = nil
            if !wasServing {
                serveHasHeld = false
                serveDesiredHold = false
            }
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
    /// `cancelledServe` carries that difference. It is set on the cancel and
    /// cleared once the reading proves the floor it names has stopped binding —
    /// see the rule ABOVE the suppression branch, which is the ONE place it
    /// dies and which has to run before that branch moves `lastSuppression`.
    ///
    /// `assertionIsHeld` is the caller's report of whether an assertion is
    /// actually held RIGHT NOW, which only the caller can know: this type
    /// decides what SHOULD happen, and IOKit decides what did. It defaults to
    /// `false`, the safe direction — a caller that says nothing gets a refusal
    /// rather than a claim about a hold that may never have existed.
    public mutating func evaluate(powerSource: PowerSource,
                                  batteryPercent: Int?,
                                  sessions: [AgentSession] = [],
                                  holdAwakeWhileBlocked: Bool = false,
                                  batteryFloorPercent: Int = 20,
                                  assertionIsHeld: Bool = false) -> DesiredPowerState {
        let state = PowerBroker.decide(PowerInputs(
            sessions: sessions,
            powerSource: powerSource,
            batteryPercent: batteryPercent,
            userIntent: intent,
            holdAwakeWhileBlocked: holdAwakeWhileBlocked,
            batteryFloorPercent: batteryFloorPercent))

        // Recorded BEFORE the cancel below, which moves `intent` off `.serve`.
        //
        // TWO signals, one tick apart, and neither is enough alone.
        // `serveDesiredHold` says the previous evaluate under THIS request asked
        // for a hold, which is what stops an older `.auto` hold from being
        // credited to a click that never held. `assertionIsHeld` says the caller
        // really took it, which is what stops a refused `acquire()` from being
        // announced as a release. The confirmation cannot arrive on the same
        // call as the desire, because the caller acquires only after this
        // returns.
        if intent == .serve {
            if serveDesiredHold, assertionIsHeld { serveHasHeld = true }
            serveDesiredHold = state.idleSleepAssertion
        }

        // The ONE place the record dies, and it runs BEFORE the branch below.
        // The order is load bearing: the branch overwrites `lastSuppression`,
        // and the record belongs to the suppression that PRODUCED it rather
        // than to the one this call is about to record. Reading it afterwards
        // judges a refusal from a 20% floor against a 30% floor, so a record
        // that ended survives into an episode it never met —
        // `aRefusalUnderOneFloorDiesWhenTheFloorMoves` goes red on that.
        //
        // Outside the branch, not inside it, which is audit finding 2.
        // `PowerBroker` returns early whenever nothing wants a hold, so with no
        // session no suppression ever fires under `.auto`. A clear that runs
        // only on a suppression therefore never runs, and the refusal replays
        // onto the next drain days later.
        if Self.hasEnded(lastSuppression, powerSource: powerSource,
                         batteryPercent: batteryPercent) {
            cancelledServe = nil
        }

        if let suppression = state.suppression {
            lastSuppression = suppression
            if intent == .serve {
                intent = standing
                // The SAME branch ends two different histories. A `.serve` that
                // has held is being RELEASED; one that never held is being
                // REFUSED. Calling both a refusal tells a user whose click
                // worked for hours that it did not.
                cancelledServe = serveHasHeld
                    ? .released(returnedTo: standing)
                    : .refused(returnedTo: standing)
            }
            // No `else` clear here, and its absence is the fix for audit
            // finding 1. A suppression that cancelled no click does not end the
            // episode a live record explains: under `.auto` a working session
            // asks for the same hold on every hook event, so that clear wiped
            // the user's own refusal sub-second after they read it.
        }
        return state
    }

    /// Whether the recorded suppression has STOPPED being true of the reading
    /// now being evaluated.
    ///
    /// POSITIVE evidence only, and the polarity is the whole point. This clear
    /// is TERMINAL where the filter it mirrors is reversible:
    /// `ServingModel.reason(_:stillTrueOf:)` HIDES the sentence and shows it
    /// again on the next reading, while this DESTROYS the record and no later
    /// reading brings it back. So a rule that ends the episode whenever it
    /// cannot see a reason to keep it throws the user's disclosure away for
    /// good on one bad sample.
    ///
    /// The three answers, and the evidence behind each:
    ///
    ///   - no record — nothing to end.
    ///   - not on battery — the battery floor cannot bind while the machine is
    ///     not on battery, so this IS evidence and the episode is over.
    ///     `aReturnToACEndsTheEpisodeForGood` holds that line, and dropping it
    ///     brings audit finding 2 back through a recharge.
    ///   - on battery with no percentage — evidence of NOTHING, so the record
    ///     stays. `SystemPowerReader.reading(from:providingType:)` returns
    ///     exactly this whenever no internal-battery source reports a usable
    ///     capacity, so it reaches the shipping app —
    ///     `aReadingWithNoPercentageDoesNotKillALiveRefusal` measures it.
    ///
    /// The comparison is `PowerBroker`'s own, negated: it suppresses at
    /// `percent <= floor`, so the episode ends at `percent > floor` and not one
    /// point earlier. The floor comes from the RECORDED suppression rather than
    /// from this call's parameter, which is only sound because the caller reads
    /// this BEFORE overwriting that record.
    private static func hasEnded(_ suppression: HoldSuppression?,
                                 powerSource: PowerSource,
                                 batteryPercent: Int?) -> Bool {
        guard case .batteryFloor(_, let floor) = suppression else { return false }
        guard powerSource == .battery else { return true }
        guard let percent = batteryPercent else { return false }

        return percent > floor
    }
}
