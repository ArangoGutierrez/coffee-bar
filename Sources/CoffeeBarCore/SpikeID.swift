// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Identifiers for the capability spikes M0 answers.
///
/// Raw values follow `coffee-bar-HANDOFF.md` §10 numbering, which is
/// authoritative. S4 (Cursor CLI runtime hooks) and S6 (battery drain
/// harness) are deliberately absent — they are not power-capability probes
/// and ship separately.
public enum SpikeID: String, Codable, CaseIterable, Sendable {
    case s1LidCloseSleep = "S1"
    case s2DisplayUnderClosedLid = "S2"
    case s3EnergyFields = "S3"
    case s5DemotionPrivilege = "S5"
    case s8TelemetryCollision = "S8"
    case baseline = "baseline"
}
