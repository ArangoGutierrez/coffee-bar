// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower

// The acceptance criterion for issue #14, exercised rather than argued.
//
// `DemotionCrashPath_test.swift` already measured the hazard: a demotion applied
// to a FOREIGN process is state on that process, so it outlives whatever applied
// it, and a SIGKILLed demoter runs no cleanup at all. Its comment names the two
// ways out — "a supervising process that outlives the app, or a journal a later
// run reads back" — and Carlos chose the journal on 2026-08-05.
//
// So this check runs the whole thing for real:
//
//   1. a real victim process, started by this suite and by nothing else;
//   2. a real SECOND process that runs the real `ProcGovernor` and demotes it;
//   3. `kill -9` on that demoter, so no cleanup of any kind can run;
//   4. `proc_pidinfo` proving the victim is STILL demoted and stranded;
//   5. a later run — a fresh `ProcGovernor` over the same journal — restoring it;
//   6. `proc_pidinfo` proving the bit is gone.
//
// Step 2 is a separate executable, `CoffeeBarGovernorHarness`, because the
// demoter has to be a process that can be killed. Running the governor inside
// the test process and skipping the kill would test everything except the thing
// this file exists for. The harness is a target and NOT a product, so
// `scripts/build-app.sh`, which builds `--product coffee-bar`, never ships it.

/// Anchors `Bundle(for:)` to the test bundle, whose containing directory is also
/// where the executable products land — so the harness under test is the one
/// built for THIS run rather than a stale one from the other configuration.
/// `DemotionCrashPath_test.swift` finds `coffee-bar-probe` the same way.
private final class CrashRecoveryAnchor: NSObject {}

/// The binary carries the TARGET's name, not a product's: `coffee-bar-probe` is
/// renamed by its `.executable` product entry and this harness has none, on
/// purpose.
private func harnessPath() -> String {
    Bundle(for: CrashRecoveryAnchor.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("CoffeeBarGovernorHarness")
        .path
}

@Suite struct ProcGovernorCrashRecoveryTests {

    @Test func aDemotionOutlivesTheSIGKILLedDemoterAndALaterRunUndoesIt() throws {
        let harness = harnessPath()
        try #require(FileManager.default.isExecutableFile(atPath: harness),
                     "no governor harness at \(harness); every assertion below would be vacuous")

        // A process this suite created, and never one it found. The rule this
        // whole task is bound by.
        let victim = try spawnIdleChild(named: "cb-crash-victim")
        defer { victim.stop() }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let journalURL = scratch.appendingPathComponent("demotion-journal.json")
        let marker = scratch.appendingPathComponent("harness-report")

        let inspector = SystemProcessInspector()
        let before = try #require(inspector.snapshot(of: victim.pid))
        try #require(!before.isExternallyBackgrounded,
                     "the victim was already demoted; the transition below would be invisible")

        // 2. A real second process, running the real governor.
        let demoter = Process()
        demoter.executableURL = URL(fileURLWithPath: harness)
        demoter.arguments = ["\(victim.pid)", journalURL.path, "cb-crash-victim", marker.path]
        try demoter.run()
        defer { if demoter.isRunning { kill(demoter.processIdentifier, SIGKILL) } }

        let report = try #require(waitForFile(marker, within: 30),
                                  "the harness never reported; nothing below would be about a demotion")
        try #require(report == "demoted", "the harness refused the demotion: \(report)")

        // The journal exists and names the victim, written by the harness before
        // it touched the process.
        let onDisk = try #require(try FileDemotionJournalStore(url: journalURL).load())
        try #require(onDisk.entries.map(\.identity.pid) == [victim.pid])
        #expect(onDisk.entries.first?.appliedByThisApp == true)

        let demoted = try #require(waitForFlags(of: victim.pid, within: 20) {
            $0 & ProcSnapshot.externalDarwinBackground != 0
        }, "the harness reported a demotion the instrument cannot see")
        #expect(demoted & ProcSnapshot.externalDarwinBackground != 0)

        // 3. Crash the demoter. A SIGKILL cannot be caught, blocked or handled,
        // so no `defer`, no `atexit` and no signal handler runs.
        kill(demoter.processIdentifier, SIGKILL)
        demoter.waitUntilExit()
        #expect(demoter.terminationReason == .uncaughtSignal)
        #expect(demoter.terminationStatus == SIGKILL)
        errno = 0
        #expect(kill(demoter.processIdentifier, 0) == -1)
        #expect(errno == ESRCH)

        // 4. The victim is STILL demoted. This is the exposure the journal
        // exists for, and it is measured rather than assumed.
        let stranded = try #require(inspector.snapshot(of: victim.pid))
        #expect(stranded.isExternallyBackgrounded,
                "the demotion did not outlive the demoter; the hazard this design answers has changed")

        // 5. A later run. A fresh governor, over the same journal, with nothing
        // carried over from the process that died.
        let laterRun = ProcGovernor(
            policy: DemotionPolicy(demotableNames: [], selfPID: getpid(),
                                   selfUID: getuid(), selfPGID: pid_t(getpgrp())),
            journal: FileDemotionJournalStore(url: journalURL),
            inspector: inspector,
            setter: SystemDarwinBackground())

        let recovery = try laterRun.recover()
        #expect(recovery.restored == [victim.pid])

        // 6. The bit is gone.
        let cleared = try #require(waitForFlags(of: victim.pid, within: 20) {
            $0 & ProcSnapshot.externalDarwinBackground == 0
        }, "the recovery reported a restore the instrument cannot see")
        #expect(cleared & ProcSnapshot.externalDarwinBackground == 0)

        // And the journal is spent, so a third run does not clear the bit again
        // on whatever holds that pid by then.
        #expect(try FileDemotionJournalStore(url: journalURL).load() == nil)
    }

    @Test func theHarnessRefusesAProtectedPidAndLeavesNoJournal() throws {
        // Invariant 1, through a real process, against the real machine. The
        // in-process checks drive the policy directly; this one proves the
        // refusal survives the wiring — a governor built at a composition root
        // with the deny rules left off would pass every one of those and fail
        // here.
        //
        // `pid` 1 is `launchd`. Nothing is demoted, so nothing has to be undone.
        let harness = harnessPath()
        try #require(FileManager.default.isExecutableFile(atPath: harness))

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let journalURL = scratch.appendingPathComponent("demotion-journal.json")
        let marker = scratch.appendingPathComponent("harness-report")

        let launchdName = try #require(SystemProcessInspector().snapshot(of: 1)).name
        let demoter = Process()
        demoter.executableURL = URL(fileURLWithPath: harness)
        // Named in the demotable set, so only the deny rules can stop it.
        demoter.arguments = ["1", journalURL.path, launchdName, marker.path]
        try demoter.run()
        demoter.waitUntilExit()

        let report = try #require(waitForFile(marker, within: 30))
        #expect(report == "refused(systemProcess)", "the harness said: \(report)")
        #expect(try FileDemotionJournalStore(url: journalURL).load() == nil,
                "a refused pid reached the journal")
    }

    @Test func theHarnessRefusesTheFrontmostAndAgentPidsItIsToldAbout() throws {
        // The two deny rules a composition root supplies from live state rather
        // than from a constant. The bug this catches is a wiring that builds the
        // policy without them — the agent tools and the frontmost application
        // are then demotable, and demoting the agent whose work keeps the
        // machine awake is the self-defeating case the brief names.
        let harness = harnessPath()
        try #require(FileManager.default.isExecutableFile(atPath: harness))

        for rule in ["agent", "frontmost"] {
            let victim = try spawnIdleChild(named: "cb-protected-\(rule)")
            defer { victim.stop() }

            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("cb-crash-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let journalURL = scratch.appendingPathComponent("demotion-journal.json")
            let marker = scratch.appendingPathComponent("harness-report")

            let demoter = Process()
            demoter.executableURL = URL(fileURLWithPath: harness)
            demoter.arguments = ["\(victim.pid)", journalURL.path,
                                 "cb-protected-\(rule)", marker.path, rule]
            try demoter.run()
            demoter.waitUntilExit()

            let report = try #require(waitForFile(marker, within: 30))
            let expected = rule == "agent" ? "refused(trackedAgent)" : "refused(frontmostApplication)"
            #expect(report == expected, "\(rule): the harness said \(report)")

            let after = try #require(SystemProcessInspector().snapshot(of: victim.pid))
            #expect(!after.isExternallyBackgrounded, "\(rule): the victim was demoted anyway")
        }
    }
}

/// Polls until `url` has content, so nothing here waits on wall-clock time.
///
/// The machine these run on carries variable load from other work. A fixed sleep
/// read a self-demoted child as untouched while this task was being written,
/// and that reading is indistinguishable from a real negative result.
func waitForFile(_ url: URL, within seconds: TimeInterval) -> String? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        usleep(20_000)
    } while Date() < deadline
    return nil
}
