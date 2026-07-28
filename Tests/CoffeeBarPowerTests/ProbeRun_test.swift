// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

// Every test here passes `targetPID: nil`. S3 and S5 then report
// `.notApplicable` without making a syscall, which keeps this file out of the
// Darwin-background state `DemotionProbeStateTests` is `.serialized` around:
// `.serialized` orders a suite's own tests, not other suites, so a live-pid
// run from here would interleave its restore into that suite's observation
// window and flake it. The live-pid path is covered end-to-end by the
// `coffee-bar-probe --json` acceptance run, in its own process.

@Test func runReportsEverySpikeTheProbeKnowsAbout() {
    let report = ProbeRun.report(targetPID: nil)
    // Derived from what the collector actually produced: every id compared
    // here is the one a probe stamped onto its own SpikeResult, not one this
    // test declared alongside it.
    #expect(Set(report.spikes.map(\.id)) == Set(SpikeID.allCases))
    // Set equality alone tolerates a duplicated row, which would make
    // `ProbeReport.result(for:)` return an arbitrary one of the two.
    #expect(report.spikes.count == SpikeID.allCases.count)
}

@Test func lidSpikesAreReportedNotYetRunNeverFailed() throws {
    // S1 and S2 need a physical lid close, which no automated run can do. A
    // missing row reads as "forgotten"; a `fail` row is a lie about the
    // hardware. `notYetRun` is the honest state.
    let report = ProbeRun.report(targetPID: nil)
    for id in [SpikeID.s1LidCloseSleep, .s2DisplayUnderClosedLid] {
        let result = try #require(report.result(for: id),
                                  "\(id.rawValue) missing from the report")
        #expect(result.verdict == .notYetRun)
    }
}

@Test func aLiveReportSurvivesTheJSONRoundTrip() throws {
    // The fixture round-trip in OutputFormatter_test proves the encoder; this
    // proves the emitter. A report stamped with a bare `Date()` instead of
    // `HostInfo.now()` carries sub-second precision that .iso8601 drops, and
    // only a report built by the real code path can catch that.
    let report = ProbeRun.report(targetPID: nil)
    let back = try OutputFormatter.makeDecoder()
        .decode(ProbeReport.self, from: Data(OutputFormatter.json(report).utf8))
    #expect(back == report)
}

@Test func reportCarriesThisMachinesHostStamp() {
    // Guards against a placeholder stamp: the comparison is against a stamp
    // read out of this machine, so it fails for any hardcoded value.
    #expect(ProbeRun.report(targetPID: nil).host == HostInfo.stamp())
}
