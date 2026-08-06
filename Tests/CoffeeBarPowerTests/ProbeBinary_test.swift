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

@Test func theShippedBinaryAdvertisesEveryVerbItHandles() throws {
    // The v0.1 defect, read out of the binary a user actually runs.
    //
    // `ProbeVerb_test` proves the generated usage text names every case, which
    // is the in-process half. It cannot prove the BINARY prints that text: a
    // `main.swift` carrying its own hand-written string would satisfy every
    // check there while shipping the same three-of-four list as v0.1.
    let path = probeBinaryPath()
    try #require(FileManager.default.isExecutableFile(atPath: path),
                 "no coffee-bar-probe at \(path); every assertion below would be vacuous")

    let run = try SystemCommandRunner().run(path, ["definitely-not-a-verb"])

    // EX_USAGE. The usage goes to stderr, so stdout stays clean for consumers.
    #expect(run.exitCode == 64)
    #expect(run.stdout == "")

    // ROWS, not a substring search over the whole text. `revert`'s summary
    // legitimately contains the word "watchdog", so a `contains` check stays
    // green with the watchdog row deleted — measured, by mutation.
    let advertised = advertisedVerbs(in: run.stderr)
    #expect(advertised.isEmpty == false, """
        no verb rows were parsed out of the binary's output, so this check \
        read nothing.
        stderr:
        \(run.stderr)
        """)

    for verb in ProbeVerb.allCases {
        #expect(advertised.contains(verb.rawValue), """
            the shipped binary's usage carries no row for "\(verb.rawValue)".
            rows found: \(advertised)
            stderr:
            \(run.stderr)
            """)
    }
    // The two lists are the same SET. Named explicitly because `watchdog` is
    // THE v0.1 defect: handled by the binary and advertised nowhere.
    #expect(Set(advertised) == Set(ProbeVerb.allCases.map(\.rawValue)))
}

@Test func theShippedBinaryRefusesAPrivilegedVerbInsteadOfElevating() throws {
    // The design M5 chose, proven against the binary: asked to `arm` without
    // root, it prints the command and stops. It does not re-exec under sudo, it
    // does not call `AuthorizationExecuteWithPrivileges`, and it does not reach
    // `pmset` at all.
    //
    // This test is also why it is SAFE to run: a refusal happens before any
    // system call, so nothing on this machine is armed by running the suite.
    try #require(getuid() != 0, """
        this suite is running as root, so `arm` would touch this machine's real \
        power settings. Refusing to run rather than doing that.
        """)

    let path = probeBinaryPath()
    try #require(FileManager.default.isExecutableFile(atPath: path),
                 "no coffee-bar-probe at \(path); every assertion below would be vacuous")

    let run = try SystemCommandRunner().run(path, ["arm"])

    // EX_NOPERM, which is distinguishable from EX_USAGE (64) — "you may not"
    // is a different answer from "no such verb".
    #expect(run.exitCode == 77)
    #expect(run.stderr.contains("sudo"), """
        the binary refused without telling the user what to run instead.
        stderr: \(run.stderr)
        """)
    // The whole point: it said what to do rather than doing it.
    #expect(run.stderr.contains("needs root"))
}
