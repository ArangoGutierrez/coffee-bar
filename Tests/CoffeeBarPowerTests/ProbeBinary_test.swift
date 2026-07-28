// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

// Drives the shipped `coffee-bar-probe` binary as a child process.
//
// Two things live only in the executable target and are therefore unreachable
// from any in-process test: the pid `RunCommand` measures, and what `main.swift`
// does when the encode fails. Both were unguarded — mutating `RunCommand` to
// pass `nil` left every one of the 122 in-process tests green while the shipped
// probe reported S3 and S5 `notApplicable` forever.
//
// A child process is also the only race-free way to exercise the live-pid path.
// `ProbeRun.report(targetPID: getpid())` moves *this* process in and out of
// Darwin background state, which would interleave with the observation window
// in `DemotionProbeStateTests`; `.serialized` orders a suite's own tests, not
// other suites, so no placement in this target avoids that. The child demotes
// and restores itself, and this process is untouched.
//
// `swift test` builds the executable products before running, verified from a
// `rm -rf .build` tree, so nothing here needs a separate build step.

/// Anchors `Bundle(for:)` to the test bundle. Its containing directory is also
/// where the executable products land, so the binary under test is the one
/// built for *this* run — `.build/debug` or `.build/release`. Hardcoding either
/// would silently test a stale binary from the other configuration.
private final class TestBundleAnchor: NSObject {}

private func probeBinaryPath() -> String {
    Bundle(for: TestBundleAnchor.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("coffee-bar-probe")
        .path
}

@Test func theShippedBinaryMeasuresTheProcessItRunsIn() throws {
    let path = probeBinaryPath()
    try #require(FileManager.default.isExecutableFile(atPath: path),
                 "no coffee-bar-probe at \(path); every assertion below would be vacuous")

    let run = try SystemCommandRunner().run(path, ["run", "--json"])

    // The acceptance contract: a probe that ran exits 0 and says nothing on
    // stderr. A spike reporting `fail` is a finding about the machine, not a
    // probe malfunction, and must not move either of these.
    #expect(run.exitCode == 0)
    #expect(run.stderr == "")

    // Decoding is itself the guard against the old `(try? …) ?? "{}"` fallback:
    // `{}` is valid JSON and an empty report is not a decodable `ProbeReport`.
    let report = try OutputFormatter.makeDecoder()
        .decode(ProbeReport.self, from: Data(run.stdout.utf8))
    #expect(Set(report.spikes.map(\.id)) == Set(SpikeID.allCases))

    // The production configuration, read back out of a real run. Deliberately
    // NOT `== .pass`: whether these spikes pass is a property of this machine
    // and asserting it would presuppose the answer S3 and S5 exist to ask.
    // `notApplicable` is reachable on exactly one input — no target pid — so
    // it is the verdict that means the binary measured nothing at all.
    for id in [SpikeID.s3EnergyFields, .s5DemotionPrivilege] {
        let row = try #require(report.result(for: id))
        #expect(row.verdict != .notApplicable,
                "\(id.rawValue) inapplicable in a live run: the binary supplied no target pid")
    }

    // The host stamp comes from the machine that ran the binary, which is this
    // one. A report carrying a placeholder stamp fails here.
    #expect(report.host == HostInfo.stamp())
}
