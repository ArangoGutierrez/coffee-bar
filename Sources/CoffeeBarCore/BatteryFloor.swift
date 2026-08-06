// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The battery percentage below which coffee-bar stops holding the machine
/// awake, and the ONE rule that bounds it.
///
/// Issue #11 made the floor a user setting. Before that it was an author's
/// literal in two places, and the two disagreed about whether to bound it:
/// `WatchdogPolicy.init` clamped, `PowerInputs.init` assigned. A literal an
/// author picks is wrong at most once, in review. A setting is whatever the
/// preferences hold, so the value now arrives from outside the program and the
/// disagreement became a defect.
///
/// **Where the bounding happens, and why here.** Three placements were weighed:
///
///   1. `PowerInputs.init` — CHOSEN. `PowerBroker.decide` takes a `PowerInputs`
///      and nothing else, and `PowerInputs` declares an explicit `init`, which
///      suppresses the memberwise one. So this initialiser is the single door
///      to a decision: `HoldController.evaluate` goes through it, `ServingModel`
///      goes through `HoldController`, and every check in the suite builds one.
///      A caller cannot reach the comparison with a floor this rule never saw.
///   2. The UI layer only — REJECTED. `ServingModel` is one caller of
///      `HoldController.evaluate`, not the only possible one, and the parameter
///      is public. Bounding there leaves `CoffeeBarCore` accepting a floor of
///      1000 from anybody else, so the guarantee would hold by convention
///      rather than by construction.
///   3. The settings read — REJECTED, and it is the weakest of the three. It
///      bounds the value on the way OUT of the store and therefore misses the
///      in-memory path entirely: a floor set through the property this session
///      would stay unbounded until the next launch, which is the shape of bug
///      that only shows up on somebody else's machine.
///
/// The rule is applied ONCE, in `PowerInputs.init`, and `WatchdogPolicy.init`
/// calls the same function rather than keeping its own copy. Two clamps with
/// their own literals drift the moment one is edited, and the product would
/// then refuse a hold at a charge the watchdog is content to keep.
/// `bothFloorPathsBoundTheSameValueTheSameWay` goes red on exactly that.
public enum BatteryFloor {

    /// What a fresh install uses, and what the README documents.
    ///
    /// Named rather than repeated. It is the declared default of
    /// `PowerInputs.init`, of `HoldController.evaluate`, and of the settings
    /// read in `ServingModel` — three places, and a fourth literal is one that
    /// can differ from the number the documents state.
    /// `theBatteryFloorStatedIsTheRealDefault` reads the docs against the FIRST
    /// of those, so a drifting third would leave the app enforcing a floor the
    /// README does not describe while that guard stayed green.
    public static let `default` = 15

    /// The floors a user may choose from.
    ///
    /// A closed range and not a free number. Out-of-range values are bounded
    /// rather than trapped, following the `WatchdogPolicy` precedent: this code
    /// runs while an assertion may be held, and a trap there would abort with
    /// `SleepDisabled` still set — strictly worse than acting on a bounded
    /// value.
    ///
    /// The bounds are not arbitrary. 0 would fire only at exactly 0%, once the
    /// machine is already dead, so the floor would exist and do nothing. Above
    /// 100 is not a percentage at all, and it refuses every hold at every
    /// charge — the product silently stops working.
    ///
    /// Narrowed from `5...100` when the floor became a slider. Those were the
    /// bounds of what is arithmetically a percentage; these are the bounds of
    /// what is a useful floor. At 5 the machine is close enough to dead that
    /// the floor arrives too late to be a safety limit, and above 50 the
    /// product refuses to hold across half of every discharge — which a user
    /// reads as "coffee-bar is broken" rather than as the floor they chose.
    /// A value stored under the old policy is bounded, not trapped;
    /// `aStoredFloorOutsideTheNewRangeIsClampedNotTrapped` pins that.
    public static let permitted = 10...50

    /// The gap between offered floors.
    ///
    /// Here beside `permitted` rather than in the view: two numbers a view
    /// could restate are two numbers that can drift from the policy. The
    /// slider in `PreferencesView.swift` is constructed over this and
    /// `permitted`, so those two ARE the control's shape — `choices` below
    /// only describes the result.
    public static let step = 5

    /// The STEP-ALIGNED POSITIONS the floor control can produce, derived from
    /// `permitted` and `step` so it cannot disagree with either.
    ///
    /// NO PRODUCTION CODE READS THIS, and that is correct rather than a gap.
    /// The control is a `Slider` in `PreferencesView.swift`, constructed
    /// `in: permitted, step: step`, so the values it yields are
    /// `lowerBound + n * step` — exactly what the `stride` below computes. This
    /// is a derived DESCRIPTION of that control, never a source of truth for
    /// it.
    ///
    /// So editing this changes nothing the user sees. If you want to change
    /// what the control offers, change `permitted` or `step`; the slider is
    /// built over those two and this follows. Editing the derivation here
    /// without touching them makes this DISAGREE with the control while the
    /// checks that read it stay green — which is the one way this symbol can
    /// do harm. `theOfferedFloorsAreDerivedFromTheRangeAndStep` goes red on it.
    ///
    /// It earns its place by being what the policy guards assert against.
    /// `everyOfferedFloorSitsInsideThePermittedRange` holds two properties of
    /// the constants that a `Slider` makes no less real:
    ///
    ///   1. `step` divides the range, so `permitted.upperBound` sits on a step
    ///      boundary and the user can reach the most conservative floor the app
    ///      accepts. Under `step = 7` the top position is 45 while
    ///      `defaults write` can still set 50 — a floor the product honours and
    ///      the control cannot express.
    ///   2. `default` sits on a boundary too, so a user who moves off it can
    ///      get back. A default with no undo is not a default.
    ///
    /// LIMIT, stated rather than implied: those are properties of these
    /// NUMBERS, not observations of SwiftUI. What a stepped `Slider` snaps to
    /// is not asserted anywhere in this package — M1 design §5.4 rules out
    /// asserting on the rendered control — so the rendering rides on the manual
    /// acceptance pass. A step that divides the range is reachable under any
    /// sane rounding rule, which is the strongest claim available from here.
    ///
    /// Was a literal list, and read "what the control offers" until the picker
    /// it described was deleted. A literal let `default` sit outside the
    /// offered set: `[10, 20, 30, 40, 50]` cannot reach 15. Deriving it removes
    /// the class of defect rather than the one instance.
    public static var choices: [Int] {
        Array(stride(from: permitted.lowerBound,
                     through: permitted.upperBound,
                     by: step))
    }

    /// `percent` brought inside `permitted`.
    ///
    /// Idempotent, so a value that has already been through it is unchanged.
    /// That matters because it is what makes the "bounded exactly once" rule
    /// safe to state as a property rather than as a promise about call order.
    public static func bounded(_ percent: Int) -> Int {
        min(max(percent, permitted.lowerBound), permitted.upperBound)
    }
}
