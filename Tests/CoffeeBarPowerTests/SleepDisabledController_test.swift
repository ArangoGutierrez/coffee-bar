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

@Test func realRunnerRunsItsReadersWithoutAFreeSharedPoolWorker() throws {
    // `run()` blocks its caller until BOTH pipe readers finish. While the
    // readers lived on `DispatchQueue.global()`, that made the call depend on
    // two free workers from a pool that is bounded and shared by the whole
    // process — so a caller holding pool threads deadlocked against itself and
    // `run()` reported `timedOut` for a child that had already exited.
    //
    // This is what turned CI red while the suite stayed green here. Swift
    // Testing runs test bodies on a pool sized from the core count; a GitHub
    // macos-15 runner has 3 cores and this machine has 14, so the runner
    // saturated where the laptop never came close. Measured on the shipped
    // runner with the pool held: `run()` against `echo hello` threw
    // timedOut(after: 10.0) at 10.002 s, against 0.526 s with the pool free.
    //
    // Not cosmetic beyond the suite: M5's privileged watchdog calls `run()` in
    // a loop for days and the menu-bar app calls it from its own task pool.
    //
    // The saturation point is DISCOVERED rather than assumed, because it
    // tracks the core count: occupiers are added until one fails to reach a
    // thread, which is the exact condition under test on any host.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-pool-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let shim = dir.appendingPathComponent("quiet")
    try Data("#!/bin/sh\necho hello\nexit 0\n".utf8).write(to: shim)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shim.path)

    // 256 is chosen to sit far above the pool's hard ceiling on any host —
    // measured at 70 on this 14-core machine, and lower on a 3-core runner —
    // so the queue is guaranteed to have work left over once the pool stops
    // handing out workers.
    let occupiers = 256
    let release = DispatchSemaphore(value: 0)
    // Released on every path, including a thrown `run()`, so a failure here
    // cannot leave the pool held for the rest of the suite. Blocks that never
    // reached a thread take their signal whenever they do start, so the count
    // balances either way.
    defer { for _ in 0..<occupiers { release.signal() } }
    for _ in 0..<occupiers {
        DispatchQueue.global().async { release.wait() }
    }

    // Saturation is CONFIRMED, not assumed. An earlier version of this test
    // stopped at the first occupier that was slow to start; that read a
    // transient stall as saturation, so the pool still had room to grow and
    // the test passed against the unfixed runner inside the full suite. It
    // discriminated only under `--filter`, which is no guard at all.
    //
    // A probe block that cannot reach a thread within a second, three times
    // running, means the pool is handing out nothing. The window is generous
    // against a slow ramp: the kernel adds workers on the order of 200 ms
    // apart as the held ones block.
    var consecutiveStalls = 0
    while consecutiveStalls < 3 {
        let probeRan = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { probeRan.signal() }
        if probeRan.wait(timeout: .now() + 1) == .timedOut {
            consecutiveStalls += 1
        } else {
            consecutiveStalls = 0
        }
    }

    // The discriminating assertion. The child writes 6 bytes and exits, so the
    // only thing 2 s can fail to cover is a reader that never got a thread.
    let result = try SystemCommandRunner().run(shim.path, [], timeout: 2)
    #expect(result.exitCode == 0)
    #expect(result.stdout == "hello\n")
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

/// Open descriptors of THIS process. Counted by listing `/dev/fd` rather than
/// by shelling out to `lsof`, which would spawn a process and open pipes of
/// its own — perturbing the very number being measured.
private func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

@Test func realRunnerDoesNotStrandPipeDescriptorsAcrossRepeatedCalls() throws {
    // `Pipe` does not close its descriptors when it is deallocated, and
    // `Process` takes ownership of only the two WRITE ends — it invalidates
    // those during spawn. Nothing owned the read ends but `run()` itself,
    // which dropped them: measured +2 descriptors per SUCCESSFUL call, linear
    // and unbounded. Census sampled every 8 calls over 40 was
    // [6, 22, 38, 54, 70, 86] both before and after the timeout work, so the
    // leak long predates it.
    //
    // Why this is not cosmetic. M5's privileged watchdog calls this in a loop
    // for days. The first thing to fail once the descriptor table is exhausted
    // is `run()`'s own `dup()` of the read end, and that failure used to fall
    // back to reading the SHARED descriptor — the exact unsafe path the dup
    // was introduced to prevent. The leak is what made EMFILE reachable, so
    // the safety mechanism degraded precisely when it was needed.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-fd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let shim = dir.appendingPathComponent("quiet")
    try Data("#!/bin/sh\necho hello\nexit 0\n".utf8).write(to: shim)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shim.path)

    let runner = SystemCommandRunner()
    // One warm-up call outside the measurement so lazily-created globals
    // (dispatch worker queues, the loader's caches) are already charged.
    _ = try runner.run(shim.path, [])

    let before = try openFileDescriptorCount()
    for _ in 0..<40 {
        let result = try runner.run(shim.path, [])
        // The runs must actually SUCCEED, or a `run()` that failed fast would
        // satisfy the descriptor assertion without doing the work.
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello\n")
    }
    let after = try openFileDescriptorCount()

    // The discriminating assertion. Unfixed this delta is +80; fixed it is 0.
    // The 20 of headroom absorbs descriptors transiently held by tests running
    // in parallel with this one, while staying a factor of four below the
    // leak it has to catch.
    #expect(after - before <= 20,
            "descriptor count grew by \(after - before) over 40 runs (\(before) -> \(after))")
}

@Test func realRunnerDoesNotStrandPipeDescriptorsWhenTheSpawnItselfFails() throws {
    // The failed-spawn path leaked twice as fast as the successful one — +4
    // descriptors per call, measured 8 -> 88 over 20 calls — because when
    // `process.run()` throws, `Process` has not yet taken the write ends, so
    // all four of the pipe's descriptors are stranded rather than two.
    //
    // This path is not exotic: a probe pointed at a tool that is absent on
    // this host takes it on every single iteration of the watchdog loop, which
    // is exactly the caller least able to afford a leak.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-fd-nospawn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let missing = dir.appendingPathComponent("does-not-exist").path

    // 400 iterations rather than the 40 the successful path uses, because this
    // one costs almost nothing and the descriptor count is process-global.
    // This test finishes in milliseconds, so it samples `before` and `after`
    // on either side of the suite's PARALLEL RAMP-UP and charges every
    // descriptor the sibling tests open in between to itself. Measured over 8
    // full-suite runs at 40 iterations, that ramp alone contributed deltas of
    // 16, 19, 21, 17, 21, 22, 18 and -1 — enough to trip a bound of 20 in
    // three of the eight. The ramp is a fixed offset that does not grow with
    // the iteration count, so raising the count raises only the signal.
    let runner = SystemCommandRunner()
    _ = try? runner.run(missing, [])            // warm-up, as above
    let before = try openFileDescriptorCount()
    for _ in 0..<400 {
        #expect(throws: (any Error).self) { try runner.run(missing, []) }
    }
    let after = try openFileDescriptorCount()

    // Unfixed this delta is +1600; fixed it is the ramp alone. 100 sits a
    // factor of four above the worst ramp observed and a factor of sixteen
    // below the leak it has to catch.
    #expect(after - before <= 100,
            "descriptor count grew by \(after - before) over 400 failed spawns (\(before) -> \(after))")
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
