// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower
@testable import CoffeeBarCore

// The crash path, which is a different question from the clean exit.
//
// `DemotionProbeStateTests` proves the probe restores a process it demoted when
// it is allowed to finish. That says nothing about a crash: a `SIGKILL` cannot
// be caught, blocked or handled, so no `defer`, no `atexit` handler and no
// signal handler runs. The requirement is that a crashed app leaves no process
// demoted, and only a killed process can answer it.
//
// There are TWO independent demotion channels, and telling them apart is the
// whole point of this file. Measured on macOS 26.5.2 (25F84):
//
//   untouched                flags=0x1404010
//   after a SELF demote      flags=0x140c010   PROC_FLAG_DARWINBG     (0x8000)
//   after an EXTERNAL demote flags=0x1014010   PROC_FLAG_EXT_DARWINBG (0x10000)
//   after both               flags=0x101c010   both bits
//
// `getpriority` reports only the SELF channel. It reads 0 for an externally
// demoted process even when that process asks about ITSELF. `DemotionProbe.swift:66`
// already records this as an instrument limit — "the reading is only conclusive
// when the target is us" — and it is a limit, never a statement about the
// machine. An earlier version of this file read four consistent zeroes out of
// that blind instrument and concluded that cross-process demotion does nothing.
// It does. `getpriorityCannotReportAnotherProcessDarwinBackgroundState` pins the
// limit so nobody promotes it into a property again.
//
// These tests move no process except their own children, so they need no
// serialization against `DemotionProbeStateTests`.

/// Reports its own Darwin background state to `argv[1]` every 50 ms, forever.
///
/// `argv[2]` selects the mode:
///   - absent — only report.
///   - `self` — demote itself first and never restore.
///   - `demote <pid>` — demote `argv[3]`, record the return, then block forever
///     without ever restoring it. Stands in for an app that crashes while
///     holding a foreign process down.
private let helperSource = #"""
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/resource.h>

static void report(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "%s", text); fclose(f); }
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    const char *mode = (argc > 2) ? argv[2] : "";

    if (strcmp(mode, "demote") == 0) {
        if (argc < 4) return 2;
        errno = 0;
        int rc = setpriority(PRIO_DARWIN_PROCESS, (id_t)atoi(argv[3]), PRIO_DARWIN_BG);
        char line[64];
        snprintf(line, sizeof(line), "demote rc=%d errno=%d", rc, errno);
        report(argv[1], line);
        for (;;) pause();
    }

    if (strcmp(mode, "self") == 0) {
        if (setpriority(PRIO_DARWIN_PROCESS, (id_t)getpid(), PRIO_DARWIN_BG) != 0) {
            return 3;
        }
    }
    for (;;) {
        errno = 0;
        int v = getpriority(PRIO_DARWIN_PROCESS, (id_t)getpid());
        char line[32];
        if (v == -1 && errno != 0) snprintf(line, sizeof(line), "unreadable");
        else snprintf(line, sizeof(line), "%d", v);
        report(argv[1], line);
        usleep(50000);
    }
}
"""#

/// `PROC_FLAG_EXT_DARWINBG` and `PROC_FLAG_DARWINBG`, from XNU
/// `bsd/sys/proc_info.h`.
///
/// The public SDK header stops at `PROC_FLAG_EXEC` (0x4000), so these are
/// spelled out. Nothing below rests on the names being right: every test reads
/// the bit BEFORE and AFTER the call it makes, so what is asserted is the
/// TRANSITION, which is observed rather than assumed.
private let extDarwinBG: UInt32 = 0x1_0000
private let selfDarwinBG: UInt32 = 0x8000

/// The `pbsi_flags` word `proc_pidinfo` reports for `pid`, or `nil` when the
/// call fails.
///
/// This is the instrument `getpriority` is not: it reports another process's
/// darwin background state across process boundaries, for any process of the
/// same uid, and it needs no entitlement.
private func bsdFlags(of pid: pid_t) -> UInt32? {
    var info = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else {
        return nil
    }
    return info.pbsi_flags
}

/// Compiles `helperSource` and returns the binary's path with a state file path
/// beside it.
///
/// `cc` ships with the same command line tools that provide `swift`, so it is
/// present wherever this suite runs at all. The caller `#require`s the result
/// rather than skipping, because a helper that failed to build would make every
/// assertion below vacuous.
private func buildStateReporter() throws -> (binary: String, stateFile: String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-demote-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appendingPathComponent("reporter.c")
    let binary = dir.appendingPathComponent("reporter")
    try Data(helperSource.utf8).write(to: source)

    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-O0", "-o", binary.path, source.path]
    let errors = Pipe()
    cc.standardError = errors
    try cc.run()
    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    cc.waitUntilExit()
    try #require(cc.terminationStatus == 0, "cc failed to build the state reporter: \(text)")

    return (binary.path, dir.appendingPathComponent("state").path)
}

/// Polls `path` until the helper has written `want`, and reports whether it did.
private func reportReaches(_ want: String, at path: String, within seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if readReport(at: path) == want { return true }
        usleep(20_000)
    }
    return false
}

private func readReport(at path: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func theStateReporterPublishesEveryStateAtomically() throws {
    // The instrument's own correctness, which every reading below depends on.
    //
    // A writer that opens the target with `fopen(path, "w")` truncates it to
    // zero bytes and only THEN writes, so each of the helper's 50 ms cycles
    // opens a window in which a concurrent reader observes an EMPTY file. The
    // two assertions that read the state file without polling —
    // `aSelfDemotedProcessLosesItsDemotionWhenItIsSIGKILLed` and
    // `getpriorityCannotReportAnotherProcessDarwinBackgroundState` — sample that
    // window directly, and the first is worse than a sampling race: it reads
    // after a `SIGKILL`, so a kill that lands inside the window leaves the file
    // empty PERMANENTLY and the assertion fails from then on. That is issue #84.
    //
    // `reportReaches` is immune because it polls and retries, which is why the
    // premise-pinning `#require`s never flaked while the bare reads did.
    //
    // The fix belongs in the writer rather than in either assertion: a reader
    // must see the old contents or the new contents, never neither.
    let helper = try buildStateReporter()

    let child = Process()
    child.executableURL = URL(fileURLWithPath: helper.binary)
    child.arguments = [helper.stateFile]          // report only, demotes nothing
    try child.run()
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

    // Pins the premise. Sampling before the helper has written anything would
    // count "not started yet" as a torn read and fail for the wrong reason.
    try #require(reportReaches("0", at: helper.stateFile, within: 10),
                 "the child never reported its state; the sampling below would measure nothing")

    var samples = 0
    var torn = 0
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        samples += 1
        // `nil` is the file gone, `""` is the truncate window. The helper never
        // means to publish either one; both are states only a non-atomic write
        // can produce.
        let seen = readReport(at: helper.stateFile)
        if seen == nil || seen == "" { torn += 1 }
    }

    // Pins the second premise: a loop that barely ran could not have observed a
    // window this narrow, and `torn == 0` would then hold vacuously. At idle
    // this samples on the order of 70,000 times in the two seconds.
    try #require(samples > 5_000,
                 "only \(samples) samples in 2 s; too few to have crossed the write window")

    #expect(torn == 0,
            "\(torn) of \(samples) reads saw an empty or missing state file")
}

@Test func aSelfDemotedProcessLosesItsDemotionWhenItIsSIGKILLed() throws {
    // The requirement, from the handoff: "a crashed app must not leave a
    // process demoted". The probe demotes only itself — pinned by
    // `theShippedProbeDemotesOnlyItsOwnProcess` — so the crash case that
    // matters is a self-demoted process that dies without running its restore.
    let helper = try buildStateReporter()

    let child = Process()
    child.executableURL = URL(fileURLWithPath: helper.binary)
    child.arguments = [helper.stateFile, "self"]
    try child.run()
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

    // Pins the premise. Without this the kill below would prove nothing: a
    // helper that never reached background state cannot demonstrate that the
    // state goes away. `1` is what `getpriority` reports for a process that
    // demoted ITSELF, matching `SpikeProbe_test.swift:124`.
    try #require(reportReaches("1", at: helper.stateFile, within: 10),
                 "the child never entered Darwin background state; every assertion below would be vacuous")

    // Read through the cross-process instrument too, so this test names which
    // of the two channels it is exercising.
    let demoted = try #require(bsdFlags(of: child.processIdentifier))
    #expect(demoted & selfDarwinBG != 0)

    kill(child.processIdentifier, SIGKILL)
    child.waitUntilExit()

    // Proof that no cleanup ran, rather than an assumption about it. A child
    // that exited normally reports `.exit`; only a signalled one reports
    // `.uncaughtSignal`. Without these two the test would look identical for a
    // helper that caught a SIGTERM and restored itself politely on the way
    // out — which is the clean exit this test exists to NOT be.
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(child.terminationStatus == SIGKILL)

    // The last thing it managed to say was still "demoted", so it died inside
    // the window rather than after leaving it.
    #expect(readReport(at: helper.stateFile) == "1")

    // The demotion is gone with the task that carried it. This holds for the
    // SELF channel, which is state on the process itself, so killing the
    // process ends it. It is NOT a general claim about demotion: an externally
    // applied demotion outlives the process that applied it, which is what
    // `anExternallyDemotedProcessStaysDemotedWhenTheDemoterIsSIGKILLed` shows.
    errno = 0
    #expect(kill(child.processIdentifier, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func getpriorityCannotReportAnotherProcessDarwinBackgroundState() throws {
    // An INSTRUMENT LIMIT, not a property of the system.
    //
    // This is a trap worth pinning because the blind reading is so convincing:
    // the externally demoted process reads 0 through `getpriority` even when it
    // asks about ITSELF. An earlier version of this file collected four such
    // zeroes — sibling, direct child, and `taskpolicy -b -p` — and concluded
    // that cross-process demotion is a no-op. `proc_pidinfo` shows the bit set
    // on the very same process at the very same moment.
    let helper = try buildStateReporter()

    let child = Process()
    child.executableURL = URL(fileURLWithPath: helper.binary)
    child.arguments = [helper.stateFile]          // report only
    try child.run()
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

    // Pins the premise: the target starts un-demoted and is really reporting.
    try #require(reportReaches("0", at: helper.stateFile, within: 10),
                 "the child never reported its state; the reading below would be stale")
    let before = try #require(bsdFlags(of: child.processIdentifier))
    try #require(before & extDarwinBG == 0,
                 "the target is already externally demoted; the transition below would be invisible")

    errno = 0
    let rc = setpriority(PRIO_DARWIN_PROCESS,
                         id_t(bitPattern: child.processIdentifier), PRIO_DARWIN_BG)
    #expect(rc == 0)
    #expect(errno == 0)

    usleep(500_000)                               // ten reporting cycles

    // The blind instrument, kept deliberately. This is the reading that misled
    // an earlier version of this file.
    #expect(readReport(at: helper.stateFile) == "0")

    // The instrument that is not blind — same process, same moment. This is the
    // assertion that makes the test discriminate: without it the test passes
    // whether or not the demotion happened.
    let after = try #require(bsdFlags(of: child.processIdentifier))
    #expect(after & extDarwinBG != 0,
            "the external demotion did not take effect")

    // And the bit tracks the call rather than drifting on its own: clearing it
    // puts the process back. Also leaves nothing throttled behind.
    _ = setpriority(PRIO_DARWIN_PROCESS,
                    id_t(bitPattern: child.processIdentifier), 0)
    usleep(200_000)
    let cleared = try #require(bsdFlags(of: child.processIdentifier))
    #expect(cleared & extDarwinBG == 0)
}

@Test func anExternallyDemotedProcessStaysDemotedWhenTheDemoterIsSIGKILLed() throws {
    // The hazard the shipped probe avoids by only ever targeting itself.
    //
    // A demotion applied to a FOREIGN process is state on that process, so it
    // outlives whatever applied it. No restore-on-exit can help: a SIGKILLed
    // demoter runs no cleanup at all, by definition.
    //
    // Handoff §5.6 plans a `ProcGovernor` that demotes arbitrary same-uid pids.
    // This measures what that costs when the app crashes. `ProcGovernor` needs a
    // real restore-on-exit — a supervising process that outlives the app, or a
    // journal a later run reads back — BEFORE it demotes any pid it does not
    // own. Nothing in this app restores a foreign pid after a crash today.
    let victimHelper = try buildStateReporter()
    let demoterHelper = try buildStateReporter()

    let victim = Process()
    victim.executableURL = URL(fileURLWithPath: victimHelper.binary)
    victim.arguments = [victimHelper.stateFile]
    try victim.run()
    defer { if victim.isRunning { kill(victim.processIdentifier, SIGKILL) } }
    try #require(reportReaches("0", at: victimHelper.stateFile, within: 10),
                 "the victim never started; the readings below would be stale")

    let demoter = Process()
    demoter.executableURL = URL(fileURLWithPath: demoterHelper.binary)
    demoter.arguments = [demoterHelper.stateFile, "demote", "\(victim.processIdentifier)"]
    try demoter.run()
    defer { if demoter.isRunning { kill(demoter.processIdentifier, SIGKILL) } }

    try #require(reportReaches("demote rc=0 errno=0", at: demoterHelper.stateFile, within: 10),
                 "the demoter never reported a successful call; nothing below would be about a demotion")
    let held = try #require(bsdFlags(of: victim.processIdentifier))
    try #require(held & extDarwinBG != 0,
                 "the victim was never demoted; its survival below would prove nothing")

    // Crash the demoter. It never restores the victim, and it gets no chance to.
    kill(demoter.processIdentifier, SIGKILL)
    demoter.waitUntilExit()
    #expect(demoter.terminationReason == .uncaughtSignal)
    #expect(demoter.terminationStatus == SIGKILL)
    errno = 0
    #expect(kill(demoter.processIdentifier, 0) == -1)
    #expect(errno == ESRCH)

    usleep(500_000)

    // The victim is STILL demoted. The demoter is gone and nothing restored it.
    let stranded = try #require(bsdFlags(of: victim.processIdentifier))
    #expect(stranded & extDarwinBG != 0,
            "the demotion did not outlive the demoter; the crash hazard this test records has changed")

    // Undo it, so the suite leaves no process throttled. The test asserts the
    // hazard; it must not inflict it.
    _ = setpriority(PRIO_DARWIN_PROCESS,
                    id_t(bitPattern: victim.processIdentifier), 0)
}

@Test func theShippedProbeDemotesOnlyItsOwnProcess() throws {
    // THE load-bearing test for crash safety. The shipped binary is safe under
    // a crash for exactly one reason: the only process it ever demotes is
    // itself, so the demotion lives on the task that dies. The test above shows
    // what a foreign target would cost, and nothing here restores one.
    //
    // `RunCommand` passes `getpid()`, and it lives in an executable target that
    // no test can import, so a real run of the shipped binary is the only place
    // the production target pid can be observed. Mutating that call to any
    // other pid turns `targetIsSelf` to "false" and this test red.
    let path = Bundle(for: DemotionCrashPathAnchor.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("coffee-bar-probe")
        .path
    try #require(FileManager.default.isExecutableFile(atPath: path),
                 "no coffee-bar-probe at \(path); the assertion below would be vacuous")

    let run = try SystemCommandRunner().run(path, ["run", "--json"])
    let report = try OutputFormatter.makeDecoder()
        .decode(ProbeReport.self, from: Data(run.stdout.utf8))
    let s5 = try #require(report.result(for: .s5DemotionPrivilege))

    #expect(s5.evidence["targetIsSelf"] == "true")
}

/// Anchors `Bundle(for:)` to the test bundle, whose containing directory is
/// also where the executable products land — so the binary under test is the
/// one built for THIS run rather than a stale one from the other configuration.
private final class DemotionCrashPathAnchor: NSObject {}
