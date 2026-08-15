// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How long lid-closed mode holds the machine awake, and the ONE rule that
/// bounds what a user may choose (issue #74).
///
/// The same shape as `BatteryFloor`, for the same reason: a number that arrives
/// from outside the program needs exactly one place that decides what is
/// acceptable, or two call sites disagree about it and the product enforces a
/// bound its own window does not describe.
///
/// **What this type is NOT.** It does not enforce the hold. `JournalRecord.clamp`
/// does that, on both the init and the decode path, and it is the only thing a
/// hand-edited journal on disk ever meets. This describes what the CONTROL may
/// offer — which is a different job, and separating them is what stops the
/// control from being able to express a hold the product refuses, or from being
/// unable to express one it accepts.
///
/// **Why the value never reaches the daemon.** The hold a user picks here is
/// written into the `--ttl` of the command the Preferences window PRINTS, and
/// the user runs that command themselves. It arrives at the root process as an
/// argument somebody typed, not as a preferences file that process went looking
/// for. SECURITY.md defers "a root process reading an unprivileged user's
/// preferences" as a new data flow needing its own review, and this design does
/// not create one — the same refusal `batteryFloorPercent` already makes, and it
/// costs nothing here because arming is already a thing you do by hand.
public enum LidClosedHold {

    /// The holds a user may choose from.
    ///
    /// **The top IS `JournalRecord.maxTTLSeconds`, derived and never retyped.**
    /// Issue #74's decision is a hold "user-configurable up to 24h", which makes
    /// this identity the requirement rather than a tidiness preference. A typed
    /// `24 * 60 * 60` here drifts the moment the ceiling moves, and it drifts
    /// toward the one failure nobody reports: a slider that stops short of a
    /// hold the journal would have honoured, so the product accepts a `--ttl`
    /// the window cannot express and the setting silently means less than it
    /// says. `theHoldControlReachesTheJournalCeiling` holds the identity AND a
    /// literal beside it, because the identity alone stays green if somebody
    /// lowers both together.
    ///
    /// **The bottom is half an hour, and it is the old default kept as a
    /// CHOICE.** #74's argument is that 30 minutes is wrong as a default, not
    /// that it is wrong as a hold — a user who wants a short leash on AC can
    /// still ask for one. Below this the control stops meaning anything: at the
    /// first position of a one-second range the slider arms a hold that has
    /// already expired, and `--ttl` remains the way to ask for something the
    /// slider does not offer.
    public static let permitted = 1_800 ... JournalRecord.maxTTLSeconds

    /// The gap between offered holds.
    ///
    /// Here beside `permitted` rather than in the view, following `BatteryFloor`:
    /// two numbers a view could restate are two numbers that can drift from the
    /// policy. The slider in `PreferencesView.swift` is constructed over this
    /// and `permitted`, so those two ARE the control's shape.
    ///
    /// Half-hourly, which divides the range exactly — 48 positions across a day.
    /// A step that does not divide it leaves the top position short of the
    /// ceiling, which is the identity above quietly broken by arithmetic rather
    /// than by an edit. `everyPositionTheSliderCanTakeIsAHoldTheProductHonours`
    /// recomputes the stride and goes red on it.
    public static let step = 1_800

    /// `seconds` brought inside `permitted`.
    ///
    /// Idempotent, so a value that has already been through it is unchanged —
    /// which is what makes "bounded exactly once" safe to state as a property of
    /// the value rather than as a promise about call order.
    ///
    /// BOUNDED, never trapped, following the `BatteryFloor` and `WatchdogPolicy`
    /// precedent: this runs while an assertion may be held, and a trap there
    /// would abort with `SleepDisabled` still set — strictly worse than acting
    /// on a bounded value.
    ///
    /// The preferences file is not this app's to trust. `defaults write … -int
    /// -3600` is one command away, and an unbounded read would reach the printed
    /// command as `--ttl -3600` — which the user then pastes into a root shell.
    public static func bounded(_ seconds: Int) -> Int {
        min(max(seconds, permitted.lowerBound), permitted.upperBound)
    }
}
