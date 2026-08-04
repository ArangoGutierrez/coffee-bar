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
    public static let `default` = 20

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
    public static let permitted = 5...100

    /// What the panel's control offers, coarsest question first.
    ///
    /// A fixed list rather than a free number, and a short one. This is a
    /// safety limit somebody sets once and forgets, so the difference between
    /// 32 and 33 is not a choice worth a stepper — while a control with eleven
    /// segments is one nobody reads.
    ///
    /// Here beside `permitted` rather than in the view, so the two cannot
    /// drift. A choice outside the permitted range is a control position the
    /// decision would silently change under the user: they pick it, the floor
    /// becomes something else, and the control then matches no value at all.
    /// `everyOfferedFloorSitsInsideThePermittedRange` goes red on that, and it
    /// also holds `default` inside the list — a default a user cannot get back
    /// to is a setting with no undo.
    public static let choices = [10, 20, 30, 40, 50]

    /// `percent` brought inside `permitted`.
    ///
    /// Idempotent, so a value that has already been through it is unchanged.
    /// That matters because it is what makes the "bounded exactly once" rule
    /// safe to state as a property rather than as a promise about call order.
    public static func bounded(_ percent: Int) -> Int {
        min(max(percent, permitted.lowerBound), permitted.upperBound)
    }
}
