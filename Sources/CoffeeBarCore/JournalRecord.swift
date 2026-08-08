// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum Intent: String, Codable, Sendable {
    case sleepDisabled
}

public struct ArmProvenance: Codable, Equatable, Sendable {
    public let pid: Int32
    public let binaryPath: String
    public let uid: UInt32

    public init(pid: Int32, binaryPath: String, uid: UInt32) {
        self.pid = pid
        self.binaryPath = binaryPath
        self.uid = uid
    }
}

/// Crash-safe intent log. Written and `F_FULLFSYNC`'d *before* the system
/// mutation it describes, so a crash in between leaves evidence rather than
/// a silent change. Handoff §8.2(1).
public struct JournalRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Handoff §8.2(5): hard cap regardless of settings.
    public static let maxTTLSeconds = 8 * 60 * 60

    public let schemaVersion: Int
    public let intent: Intent
    /// The value to restore TO. Stored, never assumed false (spec D6).
    public let priorValue: Bool
    public let setAt: Date
    /// Seconds since boot, from `SystemMonotonicClock`, sampled at `setAt`.
    ///
    /// The cap is measured against THIS and not against `setAt`, because a wall
    /// clock can be stepped and this cannot. A backward step landing inside the
    /// live window used to be invisible to every rung of the ladder, and the
    /// hold outlived the 8-hour cap by the size of the step.
    ///
    /// Meaningless across a reboot, which costs nothing: a journal older than
    /// `kern.boottime` is reverted before any TTL arithmetic runs.
    public let setAtMonotonic: TimeInterval
    public let ttlSeconds: Int
    public let armedBy: ArmProvenance

    public var expiry: Date { setAt.addingTimeInterval(TimeInterval(ttlSeconds)) }

    private static func clamp(_ ttl: Int) -> Int {
        min(max(ttl, 1), maxTTLSeconds)
    }

    // `setAtMonotonic` has NO default, deliberately. A default reading would
    // let a caller arm without ever deciding which clock bounds the hold, and
    // an omitted stamp is not a compile error the next reader would notice —
    // it is a cap that silently goes back to trusting the wall clock. The
    // `environment` parameter on `WatchdogService` is required for the same
    // reason and records what the omission cost.
    public init(schemaVersion: Int = JournalRecord.currentSchemaVersion,
                intent: Intent, priorValue: Bool, setAt: Date,
                setAtMonotonic: TimeInterval,
                ttlSeconds: Int, armedBy: ArmProvenance) {
        self.schemaVersion = schemaVersion
        self.intent = intent
        self.priorValue = priorValue
        self.setAt = setAt
        self.setAtMonotonic = setAtMonotonic
        self.ttlSeconds = Self.clamp(ttlSeconds)
        self.armedBy = armedBy
    }

    // Hand-written so the clamp applies to data read from disk too. The
    // synthesised decoder would bypass `init` and honour any value present
    // in the file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.intent = try c.decode(Intent.self, forKey: .intent)
        self.priorValue = try c.decode(Bool.self, forKey: .priorValue)
        self.setAt = try c.decode(Date.self, forKey: .setAt)
        // ABSENT rather than required, and it is the schema bump that makes
        // that safe. A journal an older build wrote carries no stamp, and it
        // must still DECODE so `decide()` can read its `schemaVersion` and
        // revert it as `.unknownSchema`. A throw here would take the harsher
        // refusal path instead, which discards the recorded `priorValue`.
        //
        // Zero for a record that claims the CURRENT schema and still omits the
        // field — a hand-edited file. Boot-relative zero makes the elapsed time
        // look enormous, so the hold ends immediately, which is the safe
        // direction.
        self.setAtMonotonic =
            try c.decodeIfPresent(TimeInterval.self, forKey: .setAtMonotonic) ?? 0
        self.ttlSeconds = Self.clamp(try c.decode(Int.self, forKey: .ttlSeconds))
        self.armedBy = try c.decode(ArmProvenance.self, forKey: .armedBy)
    }
}
