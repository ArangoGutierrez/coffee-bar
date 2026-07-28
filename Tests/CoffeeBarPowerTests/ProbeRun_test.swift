// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import IOKit.pwr_mgt
@testable import CoffeeBarPower
@testable import CoffeeBarCore

// Every test here passes `targetPID: nil`. S3 and S5 then report
// `.notApplicable` without making a syscall, which keeps this file out of the
// Darwin-background state `DemotionProbeStateTests` is `.serialized` around:
// `.serialized` orders a suite's own tests, not other suites, so a live-pid
// run from here would interleave its restore into that suite's observation
// window and flake it. The live-pid path — the one the shipped binary takes —
// is pinned by `ProbeBinary_test.swift`, which reads it back out of a real
// `coffee-bar-probe` run in a child process.

/// Serialized, and that is load-bearing beyond ordering this file's own tests.
///
/// Every test here calls `ProbeRun.report`, which acquires an assertion under
/// `AssertionProbe.assertionName`; `assertionProbeAcquiresAndReleasesCleanly`
/// in `BaselineProbe_test.swift` reads the live assertions of that name during
/// its own seam and requires exactly one. Run in parallel these four collide
/// with it — measured with three and with four of this file's assertions live
/// at the moment of its check, against 0 failures in 60 runs before they
/// existed. `.serialized` caps this file at one concurrent holder.
///
/// It does NOT eliminate the collision. `.serialized` orders a suite's own
/// tests, not other suites, so the complete fix puts both parties in ONE
/// suite — which spans `BaselineProbe_test.swift`, a file this task does not
/// own. Recorded in the task report rather than done unilaterally.
@Suite(.serialized)
struct ProbeRunTests {

    @Test func runReportsEverySpikeWithTheVerdictItsProbeProduced() throws {
        // Deliberately ONE `ProbeRun.report` call carrying every row assertion,
        // rather than a test function per row. Each call acquires an assertion
        // under `AssertionProbe.assertionName`, and
        // `assertionProbeAcquiresAndReleasesCleanly` in `BaselineProbe_test.swift`
        // asserts that no assertion of that name is live — so every concurrent
        // caller here is a chance to fail it. Splitting these into two more test
        // functions took that suite from 0 failures in 30 runs to 1 in 30, with
        // three of this file's assertions live at the moment of its check.
        let report = ProbeRun.report(targetPID: nil)

        // Derived from what the collector actually produced: every id compared
        // here is the one a probe stamped onto its own SpikeResult, not one this
        // test declared alongside it.
        #expect(Set(report.spikes.map(\.id)) == Set(SpikeID.allCases))
        // Set equality alone tolerates a duplicated row, which would make
        // `ProbeReport.result(for:)` return an arbitrary one of the two.
        #expect(report.spikes.count == SpikeID.allCases.count)

        // The ids and the row count were ALL this pinned. Every measured verdict
        // was free: forcing all four to `.pass` left the suite green, and so did
        // forcing the baseline row to `.fail` on a machine where it passes — a lie
        // about the user's hardware that nothing could see. Each verdict below is
        // therefore compared against an expectation derived OUTSIDE the code path
        // that produced the report.

        // Baseline, against an assertion this test acquires from IOKit itself. If
        // the API works here the row must say `.pass`; if it does not, the row
        // must say `.fail`. Both directions fail this test, and neither is a
        // hardcoded answer about this machine. The distinct assertion name keeps
        // this acquisition attributable, and keeps it out of the live-count reads
        // in `BaselineProbe_test.swift`.
        var assertionID: IOPMAssertionID = 0
        let created = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "coffee-bar ProbeRun_test expectation" as CFString,
            &assertionID)
        // Short-circuits: nothing to release when the create failed. Releasing is
        // part of the capability being measured, and leaking one here would hold
        // this machine awake for the rest of the test process's life.
        let roundTripped = created == kIOReturnSuccess
            && IOPMAssertionRelease(assertionID) == kIOReturnSuccess
        let baseline = try #require(report.result(for: .baseline))
        #expect(baseline.verdict == (roundTripped ? .pass : .fail))

        // S3, S5 and S8, each against its own probe invoked directly. With no
        // target pid S3 and S5 are `.notApplicable`, and that is what
        // discriminates here: a `ProbeRun` that fabricates a uniform `.pass`
        // disagrees with both. Nothing below hardcodes a verdict — that would
        // presuppose the answer these spikes exist to ask.
        let expected = [EnergyProbe().run(targetPID: nil),
                        DemotionProbe().run(targetPID: nil),
                        TelemetryRecon().run()]
        for want in expected {
            let row = try #require(report.result(for: want.id),
                                   "\(want.id.rawValue) missing from the report")
            #expect(row.verdict == want.verdict,
                    "\(want.id.rawValue): report says \(row.verdict), the probe said \(want.verdict)")
            // The detail carries the measurement itself for S8 — the live
            // telemetry mode — so a report that agreed on the verdict while
            // inventing the finding still fails here.
            #expect(row.detail == want.detail)
        }
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

        // S2's verdict is honest but its detail was not: "measured during an armed
        // run" implies a closed lid is the only thing standing in the way. It is
        // not. `docs/probe-results.md` records a MEASURED result — on Apple
        // Silicon `IODisplayWrangler` matches but publishes an empty
        // `IOPowerManagement`, so the planned instrument cannot produce a signal
        // here at all. A report that omits that sends its reader to close a lid
        // for nothing. This pins the pointer, not the prose: it goes red if the
        // detail reverts to describing only the armed run.
        let s2 = try #require(report.result(for: .s2DisplayUnderClosedLid))
        #expect(s2.detail.contains("docs/probe-results.md"),
                "S2 detail must point at the measured finding, not just the armed run")
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
}
