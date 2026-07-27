// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower

private struct FakeRunner: CommandRunning {
    let result: CommandResult
    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) throws -> CommandResult {
        result
    }
}

private struct RecordingRunner: CommandRunning, @unchecked Sendable {
    final class Box: @unchecked Sendable { var calls: [[String]] = [] }
    let box = Box()
    let result: CommandResult
    func run(_ executable: String, _ arguments: [String],
             timeout: TimeInterval) throws -> CommandResult {
        box.calls.append([executable] + arguments)
        return result
    }
}

@Test func readsSleepDisabledTrueFromPmsetOutput() throws {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0, stdout: "System-wide power settings:\n SleepDisabled\t1\n",
        stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(try c.isEnabled() == true)
}

@Test func readsSleepDisabledFalseWhenKeyAbsent() throws {
    // Verified on macOS 26.5.2: when unset, pmset -g omits the key entirely.
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0, stdout: "System-wide power settings:\n DestroyFVKeyOnStandby\t0\n",
        stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(try c.isEnabled() == false)
}

@Test func readsSleepDisabledFalseWhenExplicitlyZero() throws {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0, stdout: " SleepDisabled\t0\n", stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(try c.isEnabled() == false)
}

@Test func isEnabledIssuesTheExactReadInvocation() throws {
    // `FakeRunner` DISCARDS its arguments and every other isEnabled() test uses
    // it, so the read's argv was pinned by nothing at all: `isEnabled()` could
    // have issued ANY invocation — including a WRITE one — and the suite would
    // have stayed green. For a flag that survives reboot, pinning this is the
    // one guarantee the seam exists to provide.
    let runner = RecordingRunner(result: CommandResult(
        exitCode: 0, stdout: " SleepDisabled\t1\n", stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(try c.isEnabled() == true)
    #expect(runner.box.calls == [["/usr/bin/pmset", "-g"]])
}

@Test func malformedSleepDisabledValueThrowsRatherThanReadingAsOff() {
    // Reading an uninterpretable value as "off" is the dangerous direction: the
    // caller concludes there is nothing to revert and leaves a genuinely-held
    // flag set across reboot. `==` and `!=` on the parsed field agree on every
    // value pmset actually prints, so only a malformed one tells them apart.
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0,
        stdout: "System-wide power settings:\n SleepDisabled\tyes\n", stderr: ""))
    #expect(throws: PowerControlError.unreadableState("SleepDisabled=yes")) {
        try PmsetSleepDisabledController(runner: runner).isEnabled()
    }
}

@Test func anAbsentKeyStaysFalseAlongsideValuesWeDoNotParse() throws {
    // The throw is scoped to the SleepDisabled key. An absent key stays false —
    // verified real behaviour, pmset -g omits it when unset — and a neighbouring
    // key carrying a value this parser does not understand is none of its
    // business. Without this, widening the throw to every line would pass.
    let runner = FakeRunner(result: CommandResult(
        exitCode: 0,
        stdout: """
        System-wide power settings:
         SleepDisabledButNotReally\tyes
         DestroyFVKeyOnStandby\t0

        """,
        stderr: ""))
    #expect(try PmsetSleepDisabledController(runner: runner).isEnabled() == false)
}

@Test func nonZeroExitOnReadThrows() {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 1, stdout: "", stderr: "pmset: boom"))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(throws: PowerControlError.self) { try c.isEnabled() }
}

@Test func setIssuesTheExactDisablesleepInvocation() throws {
    let runner = RecordingRunner(result: CommandResult(
        exitCode: 0, stdout: "", stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    try c.set(true)
    #expect(runner.box.calls == [["/usr/bin/pmset", "-a", "disablesleep", "1"]])
}

@Test func setFalseIssuesZero() throws {
    let runner = RecordingRunner(result: CommandResult(
        exitCode: 0, stdout: "", stderr: ""))
    let c = PmsetSleepDisabledController(runner: runner)
    try c.set(false)
    #expect(runner.box.calls == [["/usr/bin/pmset", "-a", "disablesleep", "0"]])
}

@Test func setSurfacesFailureWithExitCodeAndStderr() {
    let runner = FakeRunner(result: CommandResult(
        exitCode: 1, stdout: "", stderr: "must be run as root"))
    let c = PmsetSleepDisabledController(runner: runner)
    #expect(throws: PowerControlError.commandFailed(
        exitCode: 1, stderr: "must be run as root")) { try c.set(true) }
}

@Test func realRunnerSurfacesExitCodeFromAFailingBinary() throws {
    // Failure is injected with a real failing executable on disk, NOT by
    // corrupting the environment. Environment tricks such as
    // TMPDIR=/nonexistent only fail inside the agent sandbox and are
    // theatre in CI and user shells.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-shim-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let shim = dir.appendingPathComponent("pmset")
    try Data("#!/bin/sh\necho 'must be run as root' >&2\nexit 3\n".utf8)
        .write(to: shim)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shim.path)

    let runner = SystemCommandRunner()
    let result = try runner.run(shim.path, ["-a", "disablesleep", "1"])
    #expect(result.exitCode == 3)                       // exact rc, not != 0
    #expect(result.stderr.contains("must be run as root"))
}

@Test func realRunnerDrainsBothPipesConcurrently() throws {
    // Draining stdout to EOF and only then reading stderr deadlocks both
    // processes as soon as a child fills the 64 KB stderr pipe buffer: the
    // child blocks writing stderr, so it never closes stdout, so the parent
    // never returns from the stdout read. Measured on macOS 26.5.2 against
    // the sequential-read version: 32 KB of stderr passed in 0.38 s, 1 MB
    // hung indefinitely (killed at 90 s).
    //
    // The shim bounds itself with a background SIGTERM so a regression fails
    // in ~20 s with a wrong exit code rather than hanging the suite forever.
    // The watchdog subshell's own stderr goes to /dev/null so it does not
    // hold the pipe open on the success path.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-drain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let shim = dir.appendingPathComponent("noisy")
    let script = #"""
    #!/bin/sh
    ( sleep 20; kill -TERM $$ ) >/dev/null 2>&1 &
    awk 'BEGIN{for(i=0;i<20000;i++) print "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' >&2
    exit 3

    """#
    try Data(script.utf8).write(to: shim)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shim.path)

    let result = try SystemCommandRunner().run(shim.path, [])
    // The exit code is the discriminating assertion: a deadlocked run only
    // unblocks once the watchdog SIGTERMs the shim, so it reports 15, not 3.
    // Measured against the sequential-read version: exitCode 15 after 20.5 s.
    #expect(result.exitCode == 3)
    // stderr does arrive in full either way -- awk drains into the pipe once
    // the parent unblocks -- so this pins the payload, not the deadlock.
    #expect(result.stderr.count > 1_000_000)
}

@Test func realRunnerTimesOutRatherThanWaitingOnALeakedGrandchild() throws {
    // Waiting for EOF on the pipes waits on whoever HOLDS them, which is not
    // necessarily the child: a child that exits immediately can leave a
    // backgrounded grandchild with the inherited write ends still open.
    // Measured against the unbounded runner: run() blocked for 12.35 s on a
    // child that had already exited, and folded the grandchild's late bytes
    // into stdout as if the child had written them. Tasks 8-12 and M5 all
    // shell out through this seam.
    //
    // Bounded by the elapsed-time assertion below rather than by
    // swift-testing's `.timeLimit`, which reports the test red but still lets
    // the process hang.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-leak-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let shim = dir.appendingPathComponent("leaky")
    let script = #"""
    #!/bin/sh
    ( sleep 20; echo late ) &
    echo early
    exit 0

    """#
    try Data(script.utf8).write(to: shim)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shim.path)

    let started = Date()
    #expect(throws: CommandError.timedOut(after: 1)) {
        try SystemCommandRunner().run(shim.path, [], timeout: 1)
    }
    let elapsed = Date().timeIntervalSince(started)
    // The discriminating assertion. Unbounded, this call returns only once the
    // 20 s grandchild exits; 5 s leaves room for a loaded machine while staying
    // nowhere near 20.
    #expect(elapsed < 5)
}

@Test func aDegenerateTimeoutIsBoundedBeforeItReachesDispatch() {
    // `DispatchTime.now() + Double.nan` yields a deadline that NEVER arrives.
    // Measured on macOS 26.5.2: a DispatchGroup with an outstanding enter(),
    // waited on that deadline, was still blocked when the probe was killed at
    // 5 minutes. Passing a caller's NaN straight through would reintroduce —
    // through the bound itself — the exact unbounded hang the bound exists to
    // prevent, and `min`/`max` propagate NaN rather than clamping it.
    //
    // Asserted on the bounding function directly: the only end-to-end
    // discriminator for the unbounded version is "hangs forever", which cannot
    // live in a suite.
    #expect(SystemCommandRunner.boundedTimeout(.nan) == 30)
    #expect(SystemCommandRunner.boundedTimeout(.infinity) == 86_400)
    #expect(SystemCommandRunner.boundedTimeout(-5) == 0.001)
    #expect(SystemCommandRunner.boundedTimeout(1.5) == 1.5)
}
