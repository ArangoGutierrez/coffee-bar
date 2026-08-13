// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RevertReason: String, Codable, Equatable, Sendable {
    case ttlExpired
    case heartbeatLost
    case dirtyJournalAtBoot
    case unknownSchema
    case thermalAbort
    case batteryFloor
    case clockAnomaly
    /// The journal failed a SECURITY.md precondition, so its `priorValue` was
    /// discarded and the setting was restored to `false` instead. Refusing to
    /// TRUST the file is not a reason to leave the machine awake.
    case journalRefused
    /// A human ran `revert`. Nothing went wrong; they asked.
    case operatorRequested
}

public enum WatchdogDecision: Equatable, Sendable {
    case hold
    case revert(RevertReason)
}

/// Mirror of `ProcessInfo.ThermalState`, redeclared so Core stays
/// Foundation-only and CI-testable without the real enum's platform
/// availability.
public enum ThermalLevel: Int, Codable, Sendable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
}

public struct WatchdogPolicy: Equatable, Sendable {
    public let heartbeatTimeout: TimeInterval
    public let batteryFloorPercent: Int
    public let knownSchemaVersion: Int
    /// How far the wall clock may disagree with elapsed real time before the
    /// disagreement is reported as a clock anomaly.
    ///
    /// Two ticks rather than one. `HostInfo.now` truncates `setAt` DOWN to the
    /// whole second while the monotonic stamp beside it is not truncated, so
    /// the two readings start out up to a second apart before anything has
    /// gone wrong, and ordinary NTP correction moves the wall clock by small
    /// amounts routinely. A tolerance that fired on those would revert healthy
    /// holds, and the cap does not depend on this value being tight.
    public let clockStepTolerance: TimeInterval

    public static let `default` = WatchdogPolicy(heartbeatTimeout: 45,
                                                 batteryFloorPercent: BatteryFloor.default)

    // `knownSchemaVersion` DEFAULTS to the record type's own constant rather
    // than making every caller repeat its literal: a bump to
    // `JournalRecord.currentSchemaVersion` that a hand-written policy did not
    // follow would make every armed journal revert as `.unknownSchema` — safe,
    // but the feature would silently stop working.
    public init(heartbeatTimeout: TimeInterval, batteryFloorPercent: Int,
                knownSchemaVersion: Int = JournalRecord.currentSchemaVersion,
                clockStepTolerance: TimeInterval = 10) {
        self.heartbeatTimeout = Self.clampSeconds(heartbeatTimeout)
        // `BatteryFloor.bounded`, not a clamp of this type's own. Issue #11 made
        // the floor a user setting, so `PowerInputs.init` had to start bounding
        // it too — and a second clamp with its own literals drifts the moment
        // one of the two is edited. One rule, two callers.
        // `bothFloorPathsBoundTheSameValueTheSameWay` goes red on a split.
        self.batteryFloorPercent = BatteryFloor.bounded(batteryFloorPercent)
        self.knownSchemaVersion = knownSchemaVersion
        // The same bounds and the same NaN reasoning, through the same helper.
        // `abs(skew) > .infinity` and `abs(skew) > .nan` are both permanently
        // false, so a degenerate tolerance silences the anomaly signal exactly
        // when the clock is behaving worst.
        self.clockStepTolerance = Self.clampSeconds(clockStepTolerance)
    }

    // Out-of-range policies are CLAMPED, not trapped, following the
    // `JournalRecord.clamp` precedent. `decide()` runs on the revert path
    // inside a root helper: a `precondition` trap there would abort with
    // `SleepDisabled` still set, which is strictly worse than acting on a
    // bounded value. Unlike `JournalRecord` there is no decode path to guard —
    // `WatchdogPolicy` is not `Codable` and is only ever built in-process — so
    // this bounds author error, not hostile input, and a throwing init would
    // buy nothing.
    //
    // The upper bound is the one that matters: `heartbeatTimeout: .infinity`
    // makes `gap <= timeout` always true, so the heartbeat guard never fires
    // and the machine never sleeps. That failure is OPEN.
    private static func clampSeconds(_ timeout: TimeInterval) -> TimeInterval {
        let bounded = min(max(timeout, 1), 300)
        // Finiteness is checked AFTER bounding, deliberately. `min`/`max`
        // propagate NaN — every comparison against NaN is false, so NaN
        // survives both clamps unchanged — while `.infinity` bounds cleanly to
        // 300. Testing `isFinite` first would collapse the two and throw the
        // legitimate infinite case away as well.
        return bounded.isFinite ? bounded : 45
    }
}

public struct WatchdogInputs: Sendable {
    public let journal: JournalRecord?
    public let now: Date
    /// `SystemMonotonicClock.now()` for this tick, in the same frame as the
    /// journal's `setAtMonotonic`.
    ///
    /// NOT derivable from `now`. That is the whole point: it is the one reading
    /// on this ladder that a `date -u 010203042026` cannot move.
    public let monotonicNow: TimeInterval
    public let lastHeartbeat: Date?
    /// Whether the MACHINE rebooted while this journal was live — §8.2(4)'s
    /// unclean exit, and never "this process just started".
    ///
    /// A Bool rather than the evidence, because the evidence is a `sysctl` and
    /// this module stays Foundation-only. What changed underneath it (#83) is
    /// how `WatchdogService` answers: it used to compare `journal.setAt`
    /// against `kern.boottime` — two wall-clock values, one of them frozen on
    /// disk — and it now compares boot identities, which no clock step moves.
    public let isBootEvaluation: Bool
    public let thermal: ThermalLevel
    public let batteryPercent: Int?
    public let onBattery: Bool

    public init(journal: JournalRecord?, now: Date, monotonicNow: TimeInterval,
                lastHeartbeat: Date?,
                isBootEvaluation: Bool, thermal: ThermalLevel,
                batteryPercent: Int?, onBattery: Bool) {
        self.journal = journal
        self.now = now
        self.monotonicNow = monotonicNow
        self.lastHeartbeat = lastHeartbeat
        self.isBootEvaluation = isBootEvaluation
        self.thermal = thermal
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
    }
}

/// Decides whether `SleepDisabled` may stay set.
///
/// Every branch except the first resolves toward reverting: when in doubt,
/// let the machine sleep. Precedence is deliberate and covered by tests —
/// boot recovery outranks thermal, which outranks TTL.
public func decide(_ inputs: WatchdogInputs,
                   policy: WatchdogPolicy = .default) -> WatchdogDecision {
    guard let journal = inputs.journal else { return .hold }

    if journal.schemaVersion != policy.knownSchemaVersion {
        return .revert(.unknownSchema)
    }
    if inputs.isBootEvaluation {
        return .revert(.dirtyJournalAtBoot)
    }

    // Elapsed REAL time since the arm. The one quantity on this ladder that a
    // `date` command, an NTP correction or a timezone edit cannot move, which
    // is why the cap below is measured on it and not on `inputs.now`.
    let elapsed = inputs.monotonicNow - journal.setAtMonotonic
    // What the WALL clock believes has elapsed over the same interval. The two
    // agree on a healthy machine; the gap between them is the clock's error.
    let wallElapsed = inputs.now.timeIntervalSince(journal.setAt)

    if inputs.now < journal.setAt {
        return .revert(.clockAnomaly)
    }
    // A step that never went back past `setAt`, which the guard above cannot
    // see. Bidirectional, because a machine whose clock jumped is worth
    // reporting whichever way it jumped.
    //
    // Honestly: this is a SIGNAL and not the thing keeping the cap honest. The
    // cap is honest because rung 6 below ignores the wall clock entirely, and
    // this rung would be defeated by a slew slow enough to stay under the
    // tolerance — which is precisely the case rung 6 does not care about.
    // What it adds is that the machine stops holding sleep and says why,
    // rather than running to its TTL against a clock nobody can trust.
    if abs(wallElapsed - elapsed) > policy.clockStepTolerance {
        return .revert(.clockAnomaly)
    }
    if inputs.thermal.rawValue >= ThermalLevel.serious.rawValue {
        return .revert(.thermalAbort)
    }
    if inputs.onBattery, let pct = inputs.batteryPercent,
       pct <= policy.batteryFloorPercent {
        return .revert(.batteryFloor)
    }
    // THE CAP (§8.2(5)), on elapsed real time and NOT on `journal.expiry`.
    //
    // `expiry` is still what `report` prints, because a human needs a date. It
    // is the wrong thing to DECIDE on: it is `setAt` plus the TTL, both in the
    // wall frame, so a clock put back seven hours re-opens a window that had
    // already closed and the hold simply continues. This is the only rung that
    // ends a healthy hold on the CLI path, so that was the whole cap.
    if elapsed > TimeInterval(journal.ttlSeconds) {
        return .revert(.ttlExpired)
    }
    guard let beat = inputs.lastHeartbeat,
          inputs.now.timeIntervalSince(beat) <= policy.heartbeatTimeout else {
        return .revert(.heartbeatLost)
    }
    return .hold
}
