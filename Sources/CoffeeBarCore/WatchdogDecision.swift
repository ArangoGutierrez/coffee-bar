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

    // `knownSchemaVersion` tracks the record type rather than repeating its
    // literal: a bump to `JournalRecord.currentSchemaVersion` that this policy
    // did not follow would make every armed journal revert as `.unknownSchema`
    // — safe, but the feature would silently stop working.
    public static let `default` = WatchdogPolicy(
        heartbeatTimeout: 45, batteryFloorPercent: 20,
        knownSchemaVersion: JournalRecord.currentSchemaVersion)

    public init(heartbeatTimeout: TimeInterval, batteryFloorPercent: Int,
                knownSchemaVersion: Int) {
        self.heartbeatTimeout = heartbeatTimeout
        self.batteryFloorPercent = batteryFloorPercent
        self.knownSchemaVersion = knownSchemaVersion
    }
}

public struct WatchdogInputs: Sendable {
    public let journal: JournalRecord?
    public let now: Date
    public let lastHeartbeat: Date?
    public let isBootEvaluation: Bool
    public let thermal: ThermalLevel
    public let batteryPercent: Int?
    public let onBattery: Bool

    public init(journal: JournalRecord?, now: Date, lastHeartbeat: Date?,
                isBootEvaluation: Bool, thermal: ThermalLevel,
                batteryPercent: Int?, onBattery: Bool) {
        self.journal = journal
        self.now = now
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
    if inputs.now < journal.setAt {
        return .revert(.clockAnomaly)
    }
    if inputs.thermal.rawValue >= ThermalLevel.serious.rawValue {
        return .revert(.thermalAbort)
    }
    if inputs.onBattery, let pct = inputs.batteryPercent,
       pct <= policy.batteryFloorPercent {
        return .revert(.batteryFloor)
    }
    if inputs.now > journal.expiry {
        return .revert(.ttlExpired)
    }
    guard let beat = inputs.lastHeartbeat,
          inputs.now.timeIntervalSince(beat) <= policy.heartbeatTimeout else {
        return .revert(.heartbeatLost)
    }
    return .hold
}
