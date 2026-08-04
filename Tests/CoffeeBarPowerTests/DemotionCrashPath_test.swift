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
// Reading the state from outside is useless here. Measured on macOS 26.5.2
// (25F84) and already recorded at `DemotionProbe.swift:68`:
// `getpriority(PRIO_DARWIN_PROCESS, <other pid>)` reads 0 for a third party
// whatever its real state. So each helper below reports its OWN state and the
// test reads that report. The helper takes `PRIO_DARWIN_PROCESS` and
// `PRIO_DARWIN_BG` straight from `<sys/resource.h>`, never through anything
// `DemotionProbe` exports, so its reading cannot agree with a wrong
// implementation by sharing its constants — the same discipline as
// `SpikeProbe_test.swift:16`.
//
// These tests move no process except their own children, so they need no
// serialization against `DemotionProbeStateTests`.

/// Reports its own Darwin background state to `argv[1]` every 50 ms, forever.
/// With `argv[2] == "self"` it demotes itself first and never restores: it
/// stands in for a process that dies inside the demotion window.
private let helperSource = #"""
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (argc > 2 && strcmp(argv[2], "self") == 0) {
        if (setpriority(PRIO_DARWIN_PROCESS, (id_t)getpid(), PRIO_DARWIN_BG) != 0) {
            return 3;
        }
    }
    for (;;) {
        errno = 0;
        int v = getpriority(PRIO_DARWIN_PROCESS, (id_t)getpid());
        FILE *f = fopen(argv[1], "w");
        if (f) {
            if (v == -1 && errno != 0) fprintf(f, "unreadable");
            else fprintf(f, "%d", v);
            fclose(f);
        }
        usleep(50000);
    }
}
"""#

/// Compiles `helperSource` and returns the binary's path.
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

@Test func aSelfDemotedProcessLosesItsDemotionWhenItIsSIGKILLed() throws {
    // The requirement, from the handoff: "a crashed app must not leave a
    // process demoted". The probe demotes only itself (pinned by the test
    // below), so the crash case is a self-demoted process that dies without
    // running its restore.
    let helper = try buildStateReporter()

    let child = Process()
    child.executableURL = URL(fileURLWithPath: helper.binary)
    child.arguments = [helper.stateFile, "self"]
    try child.run()
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

    // Pins the premise. Without this the kill below would prove nothing: a
    // helper that never reached background state cannot demonstrate that the
    // state goes away. `1` is what `getpriority` reports for a backgrounded
    // process, matching `SpikeProbe_test.swift:124`.
    try #require(reportReaches("1", at: helper.stateFile, within: 10),
                 "the child never entered Darwin background state; every assertion below would be vacuous")

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

    // And the demotion is gone with the task that carried it. Nothing else can
    // hold it: the test below measures that a demotion cannot be applied to,
    // or read from, any other process on this system.
    errno = 0
    #expect(kill(child.processIdentifier, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func setpriorityOnAnotherProcessReportsSuccessAndChangesNothing() throws {
    // Why the crash above cannot strand anything, and a finding the M5
    // `ProcGovernor` design depends on. Handoff §5.6 plans to demote arbitrary
    // same-uid pids with exactly this call. Measured on macOS 26.5.2 (25F84):
    // the call returns 0 and the target's own reading never changes — for a
    // sibling, for a direct child, and for `/usr/sbin/taskpolicy -b -p`, which
    // is Apple's own tool.
    //
    // If this test ever goes red, third-party demotion has started working and
    // the crash path is no longer safe by construction. Do not delete it then:
    // `ProcGovernor` needs a real restore-on-exit before it may demote anything
    // it does not own, because nothing in this app restores a foreign pid after
    // a crash and no supervisor exists that could.
    let helper = try buildStateReporter()

    let child = Process()
    child.executableURL = URL(fileURLWithPath: helper.binary)
    child.arguments = [helper.stateFile]          // no "self": it only reports
    try child.run()
    defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

    // Pins the premise: the target starts un-demoted and is really reporting.
    try #require(reportReaches("0", at: helper.stateFile, within: 10),
                 "the child never reported its state; the reading below would be stale")

    errno = 0
    let rc = setpriority(PRIO_DARWIN_PROCESS,
                         id_t(bitPattern: child.processIdentifier), PRIO_DARWIN_BG)
    let failure = errno

    // The call claims to have worked. That claim is the trap.
    #expect(rc == 0)
    #expect(failure == 0)

    // Ten reporting cycles later the target still reads itself as 0. This is
    // the load-bearing assertion: a return code is a claim about a call, not
    // about the machine — `DemotionProbe.swift:61`.
    usleep(500_000)
    #expect(readReport(at: helper.stateFile) == "0")
}

@Test func theShippedProbeDemotesOnlyItsOwnProcess() throws {
    // The crash path above is safe for one reason: the only process the probe
    // ever demotes is itself, so a SIGKILL takes the demotion with it. A probe
    // that demoted a third party would depend on its own survival to undo the
    // change.
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
