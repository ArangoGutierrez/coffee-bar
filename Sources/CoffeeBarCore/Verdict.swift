// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Outcome of a single spike.
///
/// `notYetRun` exists because S1 cannot be answered by any automated run —
/// it needs a physical lid close. Reporting it as `fail` would be a lie and
/// reporting it as `pass` would be worse.
public enum Verdict: String, Codable, Sendable {
    case pass
    case fail
    case notApplicable
    case notYetRun
    case error
}

public struct SpikeResult: Codable, Equatable, Sendable {
    public let id: SpikeID
    public let verdict: Verdict
    public let detail: String
    public let durationMS: Int
    public let evidence: [String: String]

    public init(id: SpikeID, verdict: Verdict, detail: String,
                durationMS: Int, evidence: [String: String]) {
        self.id = id
        self.verdict = verdict
        self.detail = detail
        self.durationMS = durationMS
        self.evidence = evidence
    }
}

/// Hardware and OS identity. Handoff §14: `SleepDisabled` behaviour is the
/// kind of thing Apple changes in a point release, so every verdict records
/// the build it was measured on.
public struct HostStamp: Codable, Equatable, Sendable {
    public let hardwareModel: String
    public let osVersion: String
    public let osBuild: String
    public let arch: String

    public init(hardwareModel: String, osVersion: String,
                osBuild: String, arch: String) {
        self.hardwareModel = hardwareModel
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.arch = arch
    }
}

public struct ProbeReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let host: HostStamp
    public let spikes: [SpikeResult]

    public init(schemaVersion: Int = ProbeReport.currentSchemaVersion,
                generatedAt: Date, host: HostStamp, spikes: [SpikeResult]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.host = host
        self.spikes = spikes
    }

    public func result(for id: SpikeID) -> SpikeResult? {
        spikes.first { $0.id == id }
    }
}
