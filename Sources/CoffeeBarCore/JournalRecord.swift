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
    public let ttlSeconds: Int
    public let armedBy: ArmProvenance

    public var expiry: Date { setAt.addingTimeInterval(TimeInterval(ttlSeconds)) }

    private static func clamp(_ ttl: Int) -> Int {
        min(max(ttl, 1), maxTTLSeconds)
    }

    public init(schemaVersion: Int = JournalRecord.currentSchemaVersion,
                intent: Intent, priorValue: Bool, setAt: Date,
                ttlSeconds: Int, armedBy: ArmProvenance) {
        self.schemaVersion = schemaVersion
        self.intent = intent
        self.priorValue = priorValue
        self.setAt = setAt
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
        self.ttlSeconds = Self.clamp(try c.decode(Int.self, forKey: .ttlSeconds))
        self.armedBy = try c.decode(ArmProvenance.self, forKey: .armedBy)
    }
}
