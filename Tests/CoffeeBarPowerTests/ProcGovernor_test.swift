// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower

// The governor: the one door every demotion crosses, and the recovery a later
// run performs.
//
// Two rules decide almost everything here.
//
// **Journal first.** The record is written and forced to stable storage BEFORE
// `setpriority`, never after. A journal written afterwards is defeated by a
// `SIGKILL` in the window between the two calls: the process is demoted, nothing
// on disk says so, and no later run can undo it. Carlos settled this over a
// recommendation panel HARD-DISSENT on 2026-08-05, and it is the same ordering
// rule the sleep watchdog already follows.
//
// **Restore only what this app demoted, and only if it is still the same
// process.** Four conditions, each catching a different way of promoting
// something nobody asked to promote.

// MARK: - Seams

/// An inspector over a fixed table, so recovery can be checked against a pid
/// that has been REUSED — which no suite can create on demand.
private struct StubInspector: ProcessInspecting {
    let table: [pid_t: ProcSnapshot]
    func snapshot(of pid: pid_t) -> ProcSnapshot? { table[pid] }
}

/// Records every call, and reads the journal off DISK at the moment the call is
/// made.
///
/// That reading is the ordering proof. Asserting that both things happened would
/// pass for either order; asserting that the journal already named the pid when
/// `setpriority` was about to run cannot.
private final class JournalWatchingSetter: DarwinBackgroundSetting, @unchecked Sendable {
    private let journalURL: URL
    private let lock = NSLock()
    private var _calls: [(on: Bool, pid: pid_t)] = []
    private var _journalNamedThePID: [Bool] = []
    let result: Int32

    init(journalURL: URL, result: Int32 = 0) {
        self.journalURL = journalURL
        self.result = result
    }

    var calls: [(on: Bool, pid: pid_t)] { lock.withLock { _calls } }
    var journalNamedThePID: [Bool] { lock.withLock { _journalNamedThePID } }

    func setBackground(_ on: Bool, for pid: pid_t) -> Int32 {
        let onDisk = (try? FileDemotionJournalStore(url: journalURL).load())?.entries ?? []
        let named = onDisk.contains { $0.identity.pid == pid }
        lock.withLock {
            _calls.append((on, pid))
            _journalNamedThePID.append(named)
        }
        return result
    }
}

/// A journal whose `append` always fails.
private struct FailingJournal: DemotionJournalStoring {
    func load() throws -> DemotionJournalRecord? { nil }
    func append(_ entry: DemotionEntry) throws {
        throw DemotionJournalError.writeFailed("the disk said no")
    }
    func clear() throws {}
}

private func snapshot(pid: pid_t, name: String, flags: UInt32 = 0x1404010,
                      startedAt: UInt64 = 1_785_911_481,
                      microseconds: UInt64 = 335_072,
                      uid: uid_t? = nil, pgid: pid_t = 999_001) -> ProcSnapshot {
    ProcSnapshot(pid: pid, uid: uid ?? getuid(), ppid: 1, pgid: pgid, name: name, flags: flags,
                 identity: ProcIdentity(pid: pid, startedAtSeconds: startedAt,
                                        startedAtMicroseconds: microseconds))
}

private func journalPath() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-governor-\(UUID().uuidString)")
        .appendingPathComponent("demotion-journal.json")
}

/// An open policy that allows exactly `names`, with none of the deny rules
/// pointing at the pids these checks use.
private func openPolicy(_ names: Set<String>) -> DemotionPolicy {
    DemotionPolicy(demotableNames: names, selfPID: 1_000_001,
                   selfUID: getuid(), selfPGID: 1_000_002)
}

@Suite struct ProcGovernorTests {

    // MARK: - Journal first

    @Test func theJournalNamesThePidBeforeSetpriorityIsCalled() throws {
        // THE ordering check, and the requirement Carlos settled over a panel
        // HARD-DISSENT. The bug: journal AFTER the demotion. A SIGKILL between
        // the two calls then leaves a demoted process that nothing on disk
        // names, so no later run can restore it — and darwin background state
        // survives its author, which the repository already measured.
        //
        // The setter reads the journal off the filesystem at the moment it is
        // called. Asserting that both things happened would pass for either
        // order.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setter = JournalWatchingSetter(journalURL: url)
        let subject = snapshot(pid: 5000, name: "cb-ordered")

        let governor = ProcGovernor(
            policy: openPolicy(["cb-ordered"]),
            journal: FileDemotionJournalStore(url: url),
            inspector: StubInspector(table: [5000: subject]),
            setter: setter)

        try governor.demote(5000)

        #expect(setter.calls.count == 1)
        #expect(setter.calls.first?.on == true)
        #expect(setter.journalNamedThePID == [true],
                "setpriority ran before the journal named the pid; a crash in that window strands the process")
    }

    @Test func aJournalThatCannotBeWrittenStopsTheDemotion() throws {
        // The other half of "journal first": if the record cannot be made
        // durable, the mutation must not happen at all. A governor that demotes
        // anyway produces exactly the state the ordering rule exists to prevent,
        // and does it without even crashing first.
        let setter = JournalWatchingSetter(journalURL: journalPath())
        let subject = snapshot(pid: 5000, name: "cb-unwritable")

        let governor = ProcGovernor(
            policy: openPolicy(["cb-unwritable"]),
            journal: FailingJournal(),
            inspector: StubInspector(table: [5000: subject]),
            setter: setter)

        #expect(throws: DemotionJournalError.self) { try governor.demote(5000) }
        #expect(setter.calls.isEmpty, "the process was demoted although its journal write failed")
    }

    @Test func theMeasuredPriorFlagsReachTheJournalRatherThanAnAssumedZero() throws {
        // The restore target is MEASURED, never assumed — the same rule
        // JournalRecord.priorValue follows for the sleep setting. The bug: a
        // governor journalling `priorFlags: 0`. Recovery would then treat a
        // process some other tool had already backgrounded as this app's doing
        // and promote it.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let alreadyBackground: UInt32 = 0x1014010
        let subject = snapshot(pid: 5000, name: "cb-measured", flags: alreadyBackground)

        let governor = ProcGovernor(
            policy: openPolicy(["cb-measured"]),
            journal: FileDemotionJournalStore(url: url),
            inspector: StubInspector(table: [5000: subject]),
            setter: JournalWatchingSetter(journalURL: url))

        try governor.demote(5000)

        let written = try #require(try FileDemotionJournalStore(url: url).load())
        #expect(written.entries.first?.priorFlags == alreadyBackground)
        #expect(written.entries.first?.appliedByThisApp == false)
    }

    // MARK: - The protected set, at the door

    @Test func aProtectedProcessIsRefusedAndIsNeitherJournalledNorTouched() throws {
        // Invariant 1 at the choke point. The refusal must land BEFORE the
        // journal too: an entry for a process this app never demoted would make
        // a later run clear a background bit somebody else set.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setter = JournalWatchingSetter(journalURL: url)
        let subject = snapshot(pid: 5000, name: "WindowServer")

        let governor = ProcGovernor(
            policy: openPolicy(["WindowServer"]),      // opted in, deliberately
            journal: FileDemotionJournalStore(url: url),
            inspector: StubInspector(table: [5000: subject]),
            setter: setter)

        #expect(throws: ProcGovernorError.refused(.protectedName)) { try governor.demote(5000) }
        #expect(setter.calls.isEmpty)
        #expect(try FileDemotionJournalStore(url: url).load() == nil,
                "a refused process reached the journal")
    }

    @Test func aPidWithNoProcessIsRefusedRatherThanDemotedBlind() throws {
        // The bug: demoting a pid the inspector could not read. Between the
        // caller choosing a pid and the governor acting on it the process may
        // have exited, and the pid may already belong to something else.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy(["cb-anything"]),
            journal: FileDemotionJournalStore(url: url),
            inspector: StubInspector(table: [:]),
            setter: setter)

        #expect(throws: ProcGovernorError.vanished(5000)) { try governor.demote(5000) }
        #expect(setter.calls.isEmpty)
    }

    // MARK: - Recovery

    @Test func recoveryRestoresALivePidTheJournalNames() throws {
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        let demoted = snapshot(pid: 5000, name: "cb-live", flags: 0x1014010)
        try store.append(DemotionEntry(identity: demoted.identity, name: "cb-live",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(table: [5000: demoted]), setter: setter)

        let report = try governor.recover()

        #expect(report.restored == [5000])
        #expect(setter.calls.count == 1)
        #expect(setter.calls.first?.on == false, "recovery demoted instead of restoring")
        #expect(try store.load() == nil, "the journal outlived the recovery it described")
    }

    @Test func recoveryLeavesAReusedPidAlone() throws {
        // THE pid-reuse check, and the one the brief asks to be told about. A
        // pid that is alive but now belongs to a DIFFERENT process must not be
        // restored: clearing a background bit on a stranger's process is a
        // change the user never asked for, and the stranger may have set that
        // bit on purpose.
        //
        // The journal carries pid AND start time. Same pid, different start
        // time, so this is a different process — which is a state no suite can
        // create on demand, hence the stub.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        let journalled = ProcIdentity(pid: 5000, startedAtSeconds: 1_785_911_481,
                                      startedAtMicroseconds: 335_072)
        try store.append(DemotionEntry(identity: journalled, name: "cb-was-here",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        // Same pid, started later: the kernel handed 5000 out again.
        let stranger = snapshot(pid: 5000, name: "someone-else", flags: 0x1014010,
                                startedAt: 1_785_999_999)
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(table: [5000: stranger]), setter: setter)

        let report = try governor.recover()

        #expect(report.reused == [5000])
        #expect(report.restored.isEmpty)
        #expect(setter.calls.isEmpty, "a reused pid was restored; a stranger's process was promoted")
    }

    @Test func recoveryLeavesAProcessSomeoneElseBackgroundedAlone() throws {
        // Invariant 2. The journal says the process ALREADY carried
        // EXT_DARWINBG when coffee-bar demoted it, so some other tool put it
        // there. Clearing it now promotes a process the user never asked to
        // promote — the hazard handoff §5.6 records for `taskpolicy -B`.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        let subject = snapshot(pid: 5000, name: "cb-borrowed", flags: 0x1014010)
        try store.append(DemotionEntry(identity: subject.identity, name: "cb-borrowed",
                                       priorFlags: 0x1014010,   // already background
                                       demotedAt: Date()))
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(table: [5000: subject]), setter: setter)

        let report = try governor.recover()

        #expect(report.leftAlone == [5000])
        #expect(setter.calls.isEmpty, "a bit this app never set was cleared")
    }

    @Test func recoveryAsksNothingOfAPidThatIsGone() throws {
        // A process that exited needs nothing: darwin background state is an
        // attribute of the task, so it died with it. The bug this catches is a
        // recovery that calls `setpriority` on a dead pid anyway — which the
        // kernel may refuse today and may hand to a new process tomorrow.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        try store.append(DemotionEntry(
            identity: ProcIdentity(pid: 5000, startedAtSeconds: 1, startedAtMicroseconds: 2),
            name: "cb-departed", priorFlags: 0x1404010, demotedAt: Date()))
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(table: [:]), setter: setter)

        let report = try governor.recover()

        #expect(report.gone == [5000])
        #expect(setter.calls.isEmpty)
    }

    @Test func recoveryTouchesNoPidTheJournalDoesNotName() throws {
        // Invariant 2, stated the other way round. The bug: a recovery that
        // sweeps every process matching the demotable names, or every process
        // it can see, rather than only the entries on disk. `-B` on a process
        // born background PROMOTES it.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        let named = snapshot(pid: 5000, name: "cb-named", flags: 0x1014010)
        let bystander = snapshot(pid: 5001, name: "cb-named", flags: 0x1014010,
                                 startedAt: 1_785_911_999)
        try store.append(DemotionEntry(identity: named.identity, name: "cb-named",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy(["cb-named"]), journal: store,
            inspector: StubInspector(table: [5000: named, 5001: bystander]), setter: setter)

        _ = try governor.recover()

        #expect(setter.calls.map(\.pid) == [5000],
                "recovery touched a pid the journal never named")
    }

    @Test func anEmptyJournalIsACleanStartRatherThanAnError() throws {
        // Runs on every launch, including the ordinary one where no run ever
        // demoted anything. A throw here would turn a clean start into a
        // reported failure.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: FileDemotionJournalStore(url: url),
            inspector: StubInspector(table: [:]), setter: setter)

        let report = try governor.recover()

        #expect(report == RecoveryReport())
        #expect(setter.calls.isEmpty)
    }

    // MARK: - One door

    @Test func nothingOutsideTheGovernorPutsAForeignProcessIntoBackground() throws {
        // A STRUCTURAL guard, in the shape `PrivacyBoundary_test.swift` uses.
        //
        // The bug it catches is the one issue #11 shipped: a rule applied at one
        // door and not at another. A second call site for `setpriority` anywhere
        // under Sources would demote without crossing DemotionPolicy, and every
        // check in this file would still pass. It cannot prove no route exists —
        // only that no source file outside these two opens one.
        //
        // `DemotionProbe.swift` is allowed because it targets `getpid()` and
        // nothing else, which `theShippedProbeDemotesOnlyItsOwnProcess` pins.
        let allowed: Set<String> = ["DemotionProbe.swift", "ProcGovernor.swift"]

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/Tests/CoffeeBarPowerTests
            .deletingLastPathComponent()      // …/Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources")

        var callers: Set<String> = []
        let walker = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("setpriority(") { callers.insert(file.lastPathComponent) }
        }

        // Pins the premise. An empty scan — a moved directory, a changed
        // extension — would make the comparison below pass for the wrong reason.
        #expect(callers.contains("ProcGovernor.swift"),
                "the scan found no call in the governor itself; it is looking in the wrong place")
        #expect(callers == allowed,
                "setpriority is called outside the governor: \(callers.subtracting(allowed))")
    }
}
