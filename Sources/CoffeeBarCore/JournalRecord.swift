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
    // 3 since the record gained `bootSessionID` (#83); 2 was `setAtMonotonic`
    // (#77). An older journal records no boot identity at all, so §8.2(4)'s
    // question — did the MACHINE reboot while this was live — has no answer in
    // it, exactly as a v1 journal has no answer for the TTL. `decide()`'s first
    // rung reverts an unknown schema, which is the safe answer and needs no
    // migration code to reach it.
    public static let currentSchemaVersion = 3
    /// Handoff §8.2(5): hard ceiling regardless of settings.
    ///
    /// **A CEILING, and since #74 it is no longer also the practical cap.** The
    /// hold a user actually gets is `ProbeVerb.defaultTTLSeconds` unless they
    /// ask for another, and this is the longest they may ask for. Two numbers,
    /// deliberately: one bounds the worst case, the other is what happens when
    /// nobody chooses.
    ///
    /// Raised from eight hours to twenty-four. Eight was chosen when the TTL
    /// was believed to be what protected a user who armed the machine and
    /// walked away — and it is not. `decide()` checks the battery floor at rung
    /// 5 and this at rung 6, so a hold that is genuinely dangerous ends at the
    /// floor whatever this says. On AC there is nothing to protect, and eight
    /// hours refused an overnight run for no benefit anybody could name.
    ///
    /// Twenty-four and not "no ceiling at all". The clamp is what makes a
    /// hand-edited journal claiming 31 years unenforceable, and a ceiling that
    /// cannot be reached by any honest user still bounds a dishonest file. A
    /// day is longer than any run this product is for and short enough that a
    /// forgotten hold ends by itself.
    public static let maxTTLSeconds = 24 * 60 * 60

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
    /// Meaningless across a reboot, and it does not need to survive one: a
    /// deadline measured on a clock that restarts at boot cannot outlive that
    /// boot, whatever else goes wrong.
    ///
    /// It does NOT make the reboot check itself honest, and an earlier draft of
    /// this comment implied that it did. That check compared `setAt` against
    /// `kern.boottime`, two WALL-clock values. This field bounds how long a
    /// hold lasts; the reboot question is answered by `bootSessionID` below,
    /// which is an identity rather than a reading and so has no clock in it at
    /// all.
    public let setAtMonotonic: TimeInterval

    /// The boot this record was written in, from `kern.bootsessionuuid`.
    ///
    /// §8.2(4) asks whether the MACHINE rebooted while this journal was live —
    /// an unclean exit. That is a question about IDENTITY, and it used to be
    /// answered by comparing `setAt` against `kern.boottime`: two wall-clock
    /// readings, one frozen on disk and the other not. A UUID cannot be
    /// stepped, so the comparison this feeds is immune to a clock moving in
    /// either direction (#83).
    ///
    /// EMPTY means the identity could not be read when the record was written.
    /// It is not a boot anybody is running, and the comparison treats an empty
    /// value on either side as a DIFFERENT boot, which reverts — the safe
    /// direction, and the same one an unreadable `kern.boottime` took.
    public let bootSessionID: String
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
    //
    // `bootSessionID` follows it, and the argument is stronger here because
    // the only value this module could default to is the empty string. Empty
    // matches no boot, so a caller who forgot would arm a hold the daemon
    // reverts on its next tick: the feature silently stops working, safely and
    // invisibly, which is the failure mode #77's stamp was given no default to
    // avoid. Reading the identity needs a `sysctl` this Foundation-only module
    // does not make, so the decision belongs to the caller in any case.
    public init(schemaVersion: Int = JournalRecord.currentSchemaVersion,
                intent: Intent, priorValue: Bool, setAt: Date,
                setAtMonotonic: TimeInterval,
                bootSessionID: String,
                ttlSeconds: Int, armedBy: ArmProvenance) {
        self.schemaVersion = schemaVersion
        self.intent = intent
        self.priorValue = priorValue
        self.setAt = setAt
        self.setAtMonotonic = setAtMonotonic
        self.bootSessionID = bootSessionID
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
        // ABSENT rather than required, for the reason above and no other: a v2
        // journal names no boot, and it must still DECODE so rung 1 can revert
        // it as `.unknownSchema` with its recorded `priorValue` intact.
        //
        // Empty for a record that claims the CURRENT schema and still omits the
        // field — a hand-edited file. Empty is not a boot anybody is running,
        // so the hold ends at the next tick, which is the safe direction.
        self.bootSessionID =
            try c.decodeIfPresent(String.self, forKey: .bootSessionID) ?? ""
        self.ttlSeconds = Self.clamp(try c.decode(Int.self, forKey: .ttlSeconds))
        self.armedBy = try c.decode(ArmProvenance.self, forKey: .armedBy)
    }
}
