// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CoffeeBarCore

/// Assembles the report the `run` verb prints.
///
/// Lives in CoffeeBarPower rather than beside `RunCommand` in the executable
/// target for the same reason `OutputFormatter` does: an executable target
/// cannot be imported by a test target, and *which* spikes a run reports —
/// with which verdicts — is the part of this verb worth pinning.
public enum ProbeRun {

    /// Runs every unprivileged spike and returns the assembled report.
    ///
    /// `targetPID` is the process S3 and S5 measure; production passes the
    /// probe's own pid. `nil` makes both report `.notApplicable` without
    /// making a syscall, which is how the tests exercise this collector
    /// without moving the caller in and out of Darwin background state.
    ///
    /// S1 and S2 need a physical lid close, which no automated run can do, so
    /// they are reported `notYetRun` here rather than omitted: a missing row
    /// reads as "forgotten", a `notYetRun` row reads as "pending", and a
    /// `fail` row would be a lie about the hardware.
    public static func report(targetPID: pid_t?) -> ProbeReport {
        var results: [SpikeResult] = []

        results.append(AssertionProbe().run())
        results.append(EnergyProbe().run(targetPID: targetPID))
        results.append(DemotionProbe().run(targetPID: targetPID))
        results.append(TelemetryRecon().run())

        results.append(SpikeResult(
            id: .s1LidCloseSleep, verdict: .notYetRun,
            detail: "run `coffee-bar-probe arm`, close the lid, then `report`",
            durationMS: 0, evidence: [:]))
        results.append(SpikeResult(
            id: .s2DisplayUnderClosedLid, verdict: .notYetRun,
            detail: "measured during an armed run",
            durationMS: 0, evidence: [:]))

        // `HostInfo.now()`, never a bare `Date()`: `OutputFormatter` encodes
        // ISO-8601, which has second granularity, so a sub-second stamp does
        // not survive its own round trip.
        return ProbeReport(generatedAt: HostInfo.now(),
                           host: HostInfo.stamp(),
                           spikes: results)
    }
}
