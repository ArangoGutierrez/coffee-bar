// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower

// The instrument `ProcGovernor` reads the machine through, and the reason it is
// `proc_pidinfo` rather than `getpriority`.
//
// `getpriority(PRIO_DARWIN_PROCESS, <other pid>)` cannot see another process's
// darwin background state. It reads 0 for a process that is demoted, which looks
// exactly like a process that is not. A previous session collected four such
// zeroes, concluded that cross-process demotion is a no-op, and shipped that
// conclusion. `DemotionCrashPath_test.swift` pins the limit as
// `getpriorityCannotReportAnotherProcessDarwinBackgroundState`.
//
// Everything the governor decides rests on this file reading the right word out
// of the right structure, so the checks below observe TRANSITIONS on a process
// this suite created rather than trusting a constant.
//
// Measured on macOS 26.5.2 (25F84), 2026-08-05, with `proc_pidinfo`:
//
//   untouched                     flags=0x1404010
//   after a SELF demote           flags=0x140c010   sets   0x8000
//   after an EXTERNAL demote      flags=0x1014010   sets   0x10000, clears 0x400000
//   external restore, self-demoted  unchanged        does NOT clear 0x8000
//   external restore, untouched     unchanged
//
// The last two rows are why `DemotionEntry` records the flags word it MEASURED
// before demoting: the two channels are independent, and a restore must only
// undo the channel this app drove.

// MARK: - Shared fixtures

// Internal rather than private, so the other governor checks share one
// definition. `DocsClaims_test.swift` takes the same line about `repoRoot()`: a
// second copy of a process fixture is a second thing to get wrong, and the two
// would not have to drift far to disagree about what they spawned.

/// Writes `ready` to `argv[1]`, then blocks for ever.
///
/// A readiness MARKER rather than a sleep, and that is not fussiness. While
/// writing this file a bare `sleep 1` after `fork` read a self-demoted child as
/// untouched — the child had not reached its `setpriority` yet — and that
/// reading looks identical to a real negative result. The machine these run on
/// is under variable load, so nothing here waits on wall-clock time.
/// It also leaves this test runner's process group first, and that is not
/// incidental. `Process` gives a child the parent's process group, so without
/// `setpgid` every child here would sit in coffee-bar's own group and the
/// governor would refuse it under `ownProcessGroup` — a check that dodged the
/// rule by passing a fake group would prove nothing about the real one. A
/// foreign application really is in a group of its own.
let idleChildSource = #"""
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (setpgid(0, 0) != 0) return 4;
    FILE *f = fopen(argv[1], "w");
    if (!f) return 3;
    fprintf(f, "ready");
    fclose(f);
    for (;;) pause();
}
"""#

/// A process this suite created, and never one it found.
///
/// The rule the whole task is bound by: only ever demote a process the test
/// itself started. `directory` is unique per child, so two children never share
/// a marker file.
struct SpawnedChild {
    let process: Process
    let directory: URL
    var pid: pid_t { process.processIdentifier }

    /// Kills the child and removes its scratch directory. Safe to call twice.
    func stop() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Compiles the idle helper under `basename` and runs it, returning once the
/// child has reported that it is ready.
///
/// `basename` is the EXECUTABLE's file name, which is what the kernel records
/// as the process name — so a caller can choose a name longer than the kernel's
/// own field and see what survives.
func spawnIdleChild(named basename: String = "cb-idle") throws -> SpawnedChild {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-proc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appendingPathComponent("idle.c")
    let binary = dir.appendingPathComponent(basename)
    let marker = dir.appendingPathComponent("ready")
    try Data(idleChildSource.utf8).write(to: source)

    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    cc.arguments = ["-O0", "-o", binary.path, source.path]
    let errors = Pipe()
    cc.standardError = errors
    try cc.run()
    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    cc.waitUntilExit()
    // `#require` rather than a skip: a helper that did not build would make
    // every assertion that follows vacuous.
    try #require(cc.terminationStatus == 0, "cc refused the idle helper: \(text)")

    let child = Process()
    child.executableURL = binary
    child.arguments = [marker.path]
    try child.run()
    let spawned = SpawnedChild(process: child, directory: dir)

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if (try? String(contentsOf: marker, encoding: .utf8)) == "ready" { return spawned }
        usleep(10_000)
    }
    spawned.stop()
    throw ChildNeverStarted(basename: basename)
}

struct ChildNeverStarted: Error, CustomStringConvertible {
    let basename: String
    var description: String {
        "the child \(basename) never wrote its readiness marker; any reading of it would be stale"
    }
}

/// `pbsi_flags` from the SHORT flavour — the second, independent reading.
///
/// The governor reads `PROC_PIDTBSDINFO`, because that is the only flavour that
/// also carries the process start time it needs to tell pid reuse apart. This
/// helper exists so one check can prove the two flavours report the SAME flags
/// word, rather than the governor assuming it.
func shortFlavourFlags(of pid: pid_t) -> UInt32? {
    var info = proc_bsdshortinfo()
    let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbsi_flags
}

/// Demotes `pid` from outside, the way a foreign process does.
@discardableResult
func externallyDemote(_ pid: pid_t) -> Int32 {
    setpriority(PRIO_DARWIN_PROCESS, id_t(bitPattern: pid), PRIO_DARWIN_BG)
}

@discardableResult
func externallyRestore(_ pid: pid_t) -> Int32 {
    setpriority(PRIO_DARWIN_PROCESS, id_t(bitPattern: pid), 0)
}

/// Polls until `flags(of:)` satisfies `predicate`, so no check waits on a fixed
/// delay. Returns the satisfying word, or `nil` when the deadline passes.
func waitForFlags(of pid: pid_t, within seconds: TimeInterval,
                  satisfying predicate: (UInt32) -> Bool) -> UInt32? {
    let inspector = SystemProcessInspector()
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let f = inspector.snapshot(of: pid)?.flags, predicate(f) { return f }
        usleep(10_000)
    } while Date() < deadline
    return nil
}

// MARK: - The instrument

@Suite struct ProcessInspectorTests {

    @Test func theInspectorSeesAnExternalDemotionThatGetpriorityCannotSee() throws {
        // THE bug this catches, and it has already been shipped once: reading
        // the demotion through `getpriority` reports a demoted process as
        // undemoted. Every refusal and every restore in `ProcGovernor` would
        // then act on a blind reading. This check demands that the inspector
        // sees the transition at the same moment `getpriority` misses it.
        let child = try spawnIdleChild()
        defer { child.stop() }
        let inspector = SystemProcessInspector()

        let before = try #require(inspector.snapshot(of: child.pid))
        try #require(!before.isExternallyBackgrounded,
                     "the child is already demoted; the transition below would be invisible")

        #expect(externallyDemote(child.pid) == 0)

        let after = try #require(waitForFlags(of: child.pid, within: 10) {
            $0 & ProcSnapshot.externalDarwinBackground != 0
        }, "the inspector never saw the external demotion it is supposed to see")
        #expect(after & ProcSnapshot.externalDarwinBackground != 0)

        // The blind instrument, at the same moment, on the same process. Kept
        // so this check names which reading it distrusts.
        errno = 0
        let blind = getpriority(PRIO_DARWIN_PROCESS, id_t(bitPattern: child.pid))
        #expect(blind == 0, "getpriority stopped being blind; the design note above needs rewriting")

        externallyRestore(child.pid)
    }

    @Test func bothProcInfoFlavoursReportTheSameFlagsWord() throws {
        // The governor reads `PROC_PIDTBSDINFO`; the brief and the existing
        // crash-path check name `PROC_PIDT_SHORTBSDINFO`. They must agree, or
        // this task changed instruments without saying so. Measured rather than
        // assumed, before and after a real demotion.
        let child = try spawnIdleChild()
        defer { child.stop() }
        let inspector = SystemProcessInspector()

        let longBefore = try #require(inspector.snapshot(of: child.pid)).flags
        let shortBefore = try #require(shortFlavourFlags(of: child.pid))
        #expect(longBefore == shortBefore)

        #expect(externallyDemote(child.pid) == 0)
        _ = waitForFlags(of: child.pid, within: 10) {
            $0 & ProcSnapshot.externalDarwinBackground != 0
        }

        let longAfter = try #require(inspector.snapshot(of: child.pid)).flags
        let shortAfter = try #require(shortFlavourFlags(of: child.pid))
        #expect(longAfter == shortAfter)
        // Pins that the readings above were taken across a real transition, so
        // two flavours agreeing on an unchanged word cannot pass for agreement.
        #expect(longAfter != longBefore)

        externallyRestore(child.pid)
    }

    @Test func aDeadPidHasNoSnapshotRatherThanAnEmptyOne() throws {
        // The bug: a failed read reported as flags 0. The governor would then
        // journal `priorFlags: 0` for a process it never saw, and a later run
        // would clear a bit on whatever holds that pid next. `nil` is the only
        // honest answer for a process that is gone.
        let child = try spawnIdleChild()
        let pid = child.pid
        child.stop()

        let inspector = SystemProcessInspector()
        var seen: ProcSnapshot?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            seen = inspector.snapshot(of: pid)
            if seen == nil { break }
            usleep(10_000)
        } while Date() < deadline

        #expect(seen == nil)
    }

    @Test func twoProcessesOfTheSameNameHaveDifferentIdentities() throws {
        // The bug this catches is pid reuse. A journal that identifies a demoted
        // process by pid alone — or by pid and name — tells a later run to
        // restore whatever now holds that pid. Two children of the SAME name are
        // the case a name check cannot separate, so identity must carry more.
        let first = try spawnIdleChild(named: "cb-twin")
        defer { first.stop() }
        let second = try spawnIdleChild(named: "cb-twin")
        defer { second.stop() }
        let inspector = SystemProcessInspector()

        let a = try #require(inspector.snapshot(of: first.pid))
        let b = try #require(inspector.snapshot(of: second.pid))
        try #require(a.name == b.name, "the two children were not named alike; this proves nothing")

        let idA = try #require(inspector.identity(of: first.pid))
        let idB = try #require(inspector.identity(of: second.pid))
        #expect(idA != idB)

        // And identity is STABLE for one process, or it would reject every
        // legitimate restore instead of only the reused pids.
        #expect(inspector.identity(of: first.pid) == idA)
    }

    @Test func theProtectedSetCanSeeProcessesTheIdentityReadCannot() throws {
        // A measured limit, and the reason this type makes two readings.
        //
        // `PROC_PIDTBSDINFO` is PRIVILEGED: on macOS 26.5.2 (25F84) it answers
        // `EPERM` for `pid` 1 (uid 0) and for `WindowServer` (uid 88).
        // `PROC_PIDT_SHORTBSDINFO` answers for every process on the machine.
        //
        // The bug this catches, and this task shipped it for one commit: an
        // inspector built on the privileged flavour alone reads `nil` for every
        // process another user owns. `nil` means "no such process", so the
        // protected set never gets to refuse `launchd` or `WindowServer` — it
        // never sees them. The refusal is still fail-closed, but the rule that
        // was supposed to hold was unreachable and untestable.
        let inspector = SystemProcessInspector()

        let launchd = try #require(inspector.snapshot(of: 1),
                                   "the protected set cannot refuse a process it cannot see")
        #expect(launchd.uid == 0)
        #expect(launchd.uid != getuid())
        #expect(inspector.identity(of: 1) == nil,
                "the privileged flavour stopped being privileged; the two-reading design needs rewriting")

        // Our own process answers both, which is what a demotable process looks
        // like. Without this the check above would pass for an inspector that
        // simply never returns an identity.
        #expect(inspector.snapshot(of: getpid()) != nil)
        #expect(inspector.identity(of: getpid()) != nil)
    }

    @Test func everyAlwaysProtectedNameFitsTheShortField() {
        // The trap the two readings leave behind, pinned so it cannot be walked
        // into. A process another user owns reports only `pbsi_comm`, which
        // holds 15 characters. A protected name longer than that would never
        // match such a process — and `WindowServer` and `coreaudiod` are exactly
        // the foreign-uid processes the list exists to protect.
        for name in DemotionPolicy.alwaysProtectedNames {
            #expect(name.count <= SystemProcessInspector.shortNameLimit,
                    "\(name) is \(name.count) characters and cannot match another user's process")
        }
    }

    @Test func theNameSurvivesTheKernelsShortCommandField() throws {
        // The bug: matching a user's demotable entry against `pbi_comm` alone.
        // That field holds 15 characters. Measured on macOS 26.5.2 (25F84): an
        // executable named `cb-a-name-longer-than-comm` reports
        // `pbi_comm='cb-a-name-longe'` and `pbi_name='cb-a-name-longer-than-comm'`.
        // A governor reading only `comm` can never match a name the user typed
        // in full, so an opt-in demotable entry would silently never fire.
        let basename = "cb-a-name-longer-than-comm"
        try #require(basename.count > 15, "this check needs a name longer than pbi_comm")
        let child = try spawnIdleChild(named: basename)
        defer { child.stop() }

        let snapshot = try #require(SystemProcessInspector().snapshot(of: child.pid))
        #expect(snapshot.name == basename)
    }

    @Test func aNameBeyondTheKernelsBoundIsReportedTruncated() throws {
        // The honest limit, pinned so nobody documents a longer one. `pbi_name`
        // is `char[2 * MAXCOMLEN]`, so 31 characters survive. A demotable entry
        // longer than that can never match any process, and the settings
        // documentation says so because of this check.
        let basename = String(repeating: "z", count: 40)
        let child = try spawnIdleChild(named: basename)
        defer { child.stop() }

        let snapshot = try #require(SystemProcessInspector().snapshot(of: child.pid))
        #expect(snapshot.name.count == SystemProcessInspector.nameLimit)
        #expect(snapshot.name != basename)
        #expect(basename.hasPrefix(snapshot.name))
    }

    @Test func theSnapshotReportsTheProcessOwnUidParentAndGroup() throws {
        // The bug: reading the fields off the wrong offsets. Three of the
        // governor's deny rules — foreign uid, own process group, ancestor —
        // are decided entirely by these fields, so a mis-read makes all three
        // refuse the wrong processes. Checked against values this process
        // already knows independently: the child's parent IS the test runner.
        let child = try spawnIdleChild()
        defer { child.stop() }

        let snapshot = try #require(SystemProcessInspector().snapshot(of: child.pid))
        #expect(snapshot.pid == child.pid)
        #expect(snapshot.uid == getuid())
        #expect(snapshot.ppid == getpid())
    }
}
