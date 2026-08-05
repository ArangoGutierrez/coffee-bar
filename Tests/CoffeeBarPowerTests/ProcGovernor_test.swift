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

/// An inspector over two fixed tables, so recovery can be checked against a pid
/// that has been REUSED — which no suite can create on demand.
///
/// Two tables and not one, mirroring the real inspector: the deny rules read a
/// record every process answers, and the identity comes from a PRIVILEGED record
/// the kernel refuses for another user's process. A stub that fused them could
/// not express "visible but unidentifiable", which is a state the real machine
/// produces for `pid` 1.
private struct StubInspector: ProcessInspecting {
    let table: [pid_t: ProcSnapshot]
    var identities: [pid_t: ProcIdentity] = [:]
    func snapshot(of pid: pid_t) -> ProcSnapshot? { table[pid] }
    func identity(of pid: pid_t) -> ProcIdentity? { identities[pid] }
}

private func identity(_ pid: pid_t, startedAt: UInt64 = 1_785_911_481,
                      microseconds: UInt64 = 335_072) -> ProcIdentity {
    ProcIdentity(pid: pid, startedAtSeconds: startedAt, startedAtMicroseconds: microseconds)
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
    func replace(with entries: [DemotionEntry]) throws {}
    func clear() throws {}
}

/// A setter whose answer depends on the pid.
///
/// One recovery can then hold a restore that worked AND a restore that failed,
/// which is what tells "keep the failures" apart from "keep everything".
private final class PerPIDSetter: DarwinBackgroundSetting, @unchecked Sendable {
    private let results: [pid_t: Int32]
    private let lock = NSLock()
    private var _calls: [(on: Bool, pid: pid_t)] = []

    init(results: [pid_t: Int32]) { self.results = results }

    var calls: [(on: Bool, pid: pid_t)] { lock.withLock { _calls } }

    func setBackground(_ on: Bool, for pid: pid_t) -> Int32 {
        lock.withLock { _calls.append((on, pid)) }
        return results[pid] ?? 0
    }
}

private func snapshot(pid: pid_t, name: String, flags: UInt32 = 0x1404010,
                      uid: uid_t? = nil, pgid: pid_t = 999_001) -> ProcSnapshot {
    ProcSnapshot(pid: pid, uid: uid ?? getuid(), ppid: 1, pgid: pgid, name: name, flags: flags)
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

/// Swift source with `//` line comments and `/* … */` block comments removed.
///
/// A `//` inside a string literal is treated as a comment here. That is wrong in
/// general and harmless for the one use below: a `setpriority(` inside a string
/// literal is not a call, so losing it cannot hide a call site.
private func codeWithoutComments(_ text: String) -> String {
    enum State { case code, lineComment, blockComment }
    var state = State.code
    var out = ""
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let following = text.index(after: index)
        let next: Character? = following < text.endIndex ? text[following] : nil
        var skip = false

        switch state {
        case .code:
            if character == "/", next == "/" { state = .lineComment; skip = true }
            else if character == "/", next == "*" { state = .blockComment; skip = true }
            else { out.append(character) }
        case .lineComment:
            if character == "\n" { state = .code; out.append(character) }
        case .blockComment:
            if character == "*", next == "/" { state = .code; skip = true }
        }

        index = skip ? text.index(after: following) : following
    }
    return out
}

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // …/Tests/CoffeeBarPowerTests
        .deletingLastPathComponent()      // …/Tests
        .deletingLastPathComponent()      // package root
}

/// The sentence every document describing the governor must carry while nothing
/// calls it.
///
/// A literal, because the guard below has to look for something. It is the
/// shortest phrase that cannot be written by accident and cannot be true of a
/// wired feature.
private let unwiredMarker = "no production code path calls it"

/// The two targets a call site does not make the feature live.
///
/// `CoffeeBarPower` is the library itself. `CoffeeBarGovernorHarness` is a
/// `Package.swift` TARGET with no product entry, built only by this suite —
/// `scripts/build-app.sh` builds `--product coffee-bar` — so a user cannot run
/// it and a release does not contain it.
private let targetsThatDoNotShipTheFeature = ["/CoffeeBarPower/", "/CoffeeBarGovernorHarness/"]

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
            inspector: StubInspector(table: [5000: subject], identities: [5000: identity(5000)]),
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
            inspector: StubInspector(table: [5000: subject], identities: [5000: identity(5000)]),
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
            inspector: StubInspector(table: [5000: subject], identities: [5000: identity(5000)]),
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

    @Test func aProcessWhoseIdentityTheKernelWithholdsIsRefused() throws {
        // Visible, but unidentifiable. The real machine produces this state: the
        // privileged record `identity(of:)` reads is refused for another user's
        // process, and it is also refused for a process that exits between the
        // two reads.
        //
        // The bug: journalling the entry anyway, with only a pid to name it. A
        // later run would then have no way to tell that pid from a reused one,
        // and would clear a background bit on whatever holds it — which is
        // precisely the promotion invariant 2 forbids. Refusing costs one
        // demotion that did not happen.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let setter = JournalWatchingSetter(journalURL: url)
        let subject = snapshot(pid: 5000, name: "cb-anonymous")

        let governor = ProcGovernor(
            policy: openPolicy(["cb-anonymous"]),
            journal: FileDemotionJournalStore(url: url),
            inspector: StubInspector(table: [5000: subject]),   // no identity for it
            setter: setter)

        #expect(throws: ProcGovernorError.unidentifiable(5000)) { try governor.demote(5000) }
        #expect(setter.calls.isEmpty)
        #expect(try FileDemotionJournalStore(url: url).load() == nil,
                "an entry a later run could not match reached the journal")
    }

    // MARK: - Recovery

    @Test func recoveryRestoresALivePidTheJournalNames() throws {
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        let demoted = snapshot(pid: 5000, name: "cb-live", flags: 0x1014010)
        try store.append(DemotionEntry(identity: identity(5000), name: "cb-live",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(table: [5000: demoted], identities: [5000: identity(5000)]),
            setter: setter)

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
        try store.append(DemotionEntry(identity: identity(5000), name: "cb-was-here",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        // Same pid, started later: the kernel handed 5000 out again.
        let stranger = snapshot(pid: 5000, name: "someone-else", flags: 0x1014010)
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(table: [5000: stranger],
                                     identities: [5000: identity(5000, startedAt: 1_785_999_999)]),
            setter: setter)

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
        try store.append(DemotionEntry(identity: identity(5000), name: "cb-borrowed",
                                       priorFlags: 0x1014010,   // already background
                                       demotedAt: Date()))
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(table: [5000: subject], identities: [5000: identity(5000)]),
            setter: setter)

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
            identity: identity(5000, startedAt: 1, microseconds: 2),
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
        let bystander = snapshot(pid: 5001, name: "cb-named", flags: 0x1014010)
        try store.append(DemotionEntry(identity: identity(5000), name: "cb-named",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        let setter = JournalWatchingSetter(journalURL: url)

        let governor = ProcGovernor(
            policy: openPolicy(["cb-named"]), journal: store,
            inspector: StubInspector(table: [5000: named, 5001: bystander],
                                     identities: [5000: identity(5000),
                                                  5001: identity(5001, startedAt: 1_785_911_999)]),
            setter: setter)

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

    // MARK: - A restore that FAILED is not a refusal

    @Test func aRestoreThatFailedKeepsItsEntryAndTheOtherBucketsAreCleared() throws {
        // The bug: `recover()` clearing the WHOLE journal, including entries
        // whose restore FAILED. One transient EPERM then leaves a process on the
        // E-cores AND deletes the only record naming it, so no later run can
        // find it. That is the exact state the journal-first ordering exists to
        // prevent, reached from the other end.
        //
        // A failed restore is not a refusal. The three refusal buckets describe
        // processes this run has decided never to touch; `failed` describes a
        // process this run still means to restore and could not.
        //
        // Three entries, one per outcome, so "keep the failures" cannot pass by
        // keeping everything: the gone entry must go and the restored one too.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)

        try store.append(DemotionEntry(identity: identity(5000), name: "cb-stubborn",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        try store.append(DemotionEntry(identity: identity(5001), name: "cb-obliging",
                                       priorFlags: 0x1404010, demotedAt: Date()))
        try store.append(DemotionEntry(identity: identity(5002), name: "cb-departed",
                                       priorFlags: 0x1404010, demotedAt: Date()))

        let setter = PerPIDSetter(results: [5000: EPERM, 5001: 0])
        let governor = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(
                table: [5000: snapshot(pid: 5000, name: "cb-stubborn", flags: 0x1014010),
                        5001: snapshot(pid: 5001, name: "cb-obliging", flags: 0x1014010)],
                identities: [5000: identity(5000), 5001: identity(5001)]),
            setter: setter)

        let report = try governor.recover()

        #expect(report.failed == [5000])
        #expect(report.restored == [5001])
        #expect(report.gone == [5002])

        let kept = try #require(
            try store.load(),
            "the journal was deleted although a restore failed; nothing on disk names the stranded process any more")
        #expect(kept.entries.map(\.identity.pid) == [5000],
                "recovery kept \(kept.entries.map(\.identity.pid)); only the failed entry may survive")
    }

    @Test func aLaterRunRetriesTheEntryWhoseRestoreFailed() throws {
        // Keeping the entry is worth nothing unless a later run acts on it, and
        // acting on it is the whole reason not to delete it: the transient EPERM
        // clears, the next launch reads the journal back, and the process comes
        // off the E-cores.
        //
        // The bug this catches is a fix that keeps the entry but marks it spent,
        // or one that keeps it and then skips it for ever.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        try store.append(DemotionEntry(identity: identity(5000), name: "cb-stubborn",
                                       priorFlags: 0x1404010, demotedAt: Date()))

        let live = StubInspector(
            table: [5000: snapshot(pid: 5000, name: "cb-stubborn", flags: 0x1014010)],
            identities: [5000: identity(5000)])

        let firstRun = ProcGovernor(policy: openPolicy([]), journal: store,
                                    inspector: live,
                                    setter: PerPIDSetter(results: [5000: EPERM]))
        #expect(try firstRun.recover().failed == [5000])

        // A SECOND store over the same path, because this is what a later launch
        // has: the file and nothing else.
        let laterStore = FileDemotionJournalStore(url: url)
        let retrySetter = PerPIDSetter(results: [5000: 0])
        let secondRun = ProcGovernor(policy: openPolicy([]), journal: laterStore,
                                     inspector: live, setter: retrySetter)

        let report = try secondRun.recover()

        #expect(report.restored == [5000], "the later run never retried the failed entry")
        #expect(retrySetter.calls.map(\.on) == [false], "the retry demoted instead of restoring")
        #expect(try laterStore.load() == nil, "the entry outlived the restore that succeeded")
    }

    @Test func aKeptEntryDisappearsOnceItsProcessDoes() throws {
        // The BOUND on retention, and the answer to "what stops a dead pid
        // sitting in the journal for ever".
        //
        // An entry is kept only when its process is alive, still the same
        // process, and carries a bit this app set — the three guards that run
        // BEFORE the restore is attempted. When that process exits, the next
        // recovery classifies it `gone` and drops it. So a retained entry cannot
        // outlive its process, and the journal cannot grow a permanent tail of
        // pids nobody can act on.
        //
        // The bug: "keep whatever was not restored", which retains the `gone`,
        // `reused` and `leftAlone` buckets as well and never releases them.
        let url = journalPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileDemotionJournalStore(url: url)
        try store.append(DemotionEntry(identity: identity(5000), name: "cb-stubborn",
                                       priorFlags: 0x1404010, demotedAt: Date()))

        let whileAlive = ProcGovernor(
            policy: openPolicy([]), journal: store,
            inspector: StubInspector(
                table: [5000: snapshot(pid: 5000, name: "cb-stubborn", flags: 0x1014010)],
                identities: [5000: identity(5000)]),
            setter: PerPIDSetter(results: [5000: EPERM]))
        #expect(try whileAlive.recover().failed == [5000])
        #expect(try store.load() != nil, "the failed entry was not kept, so this check proves nothing")

        // The process exits. Nothing answers for that pid any more.
        let afterItExits = ProcGovernor(policy: openPolicy([]), journal: store,
                                        inspector: StubInspector(table: [:]),
                                        setter: PerPIDSetter(results: [:]))
        let report = try afterItExits.recover()

        #expect(report.gone == [5000])
        #expect(try store.load() == nil,
                "a pid whose process is gone stayed in the journal; nothing will ever clear it")
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
        var discussedInProse: Set<String> = []
        let walker = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("setpriority(") { discussedInProse.insert(file.lastPathComponent) }
            if codeWithoutComments(text).contains("setpriority(") {
                callers.insert(file.lastPathComponent)
            }
        }

        // Pins that the comment stripping does something. Several files in this
        // package DISCUSS the call in prose — the argument order is a trap worth
        // documenting — and a scan that counted those would fire on every run.
        // A guard that cries wolf gets deleted, and the guard is the point.
        #expect(discussedInProse.count > callers.count,
                "no file discusses setpriority in prose any more; the stripping below is untested")

        // Pins the premise. An empty scan — a moved directory, a changed
        // extension — would make the comparison below pass for the wrong reason.
        #expect(callers.contains("ProcGovernor.swift"),
                "the scan found no call in the governor itself; it is looking in the wrong place")
        #expect(callers == allowed,
                "setpriority is called outside the governor: \(callers.subtracting(allowed))")
    }

    // MARK: - The documents must match what the product does

    @Test func everyDocumentAboutTheGovernorSaysNothingCallsItYet() throws {
        // The `LaunchDaemonInstaller` shape that issue #13 complains about,
        // repeating one milestone later: prose in the PRESENT TENSE about a
        // feature no code path reaches. `docs/ACCEPTED-RISKS.md` said "every
        // process it had demoted stays demoted until coffee-bar next starts and
        // reads its journal back", and `docs/ROADMAP.md` said issue #14 "added a
        // SECOND journal" at a path the app never creates. coffee-bar demotes
        // nothing and creates no such file. The code is honest about itself and
        // that does not help, because the documents are what a person reads.
        //
        // **This guard lifts itself.** The moment anything outside the library
        // and the harness calls the governor, the feature IS live, the sentence
        // is no longer required and this check stops asking for it. So it cannot
        // block the follow-up that wires it, and it cannot become the reason
        // somebody deletes it.
        let root = packageRoot()

        var productionCallers: Set<String> = []
        var anyCaller: Set<String> = []
        let walker = try #require(FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
        for case let file as URL in walker where file.pathExtension == "swift" {
            let code = codeWithoutComments(try String(contentsOf: file, encoding: .utf8))
            guard code.contains("ProcGovernor(") || code.contains(".recover()") else { continue }
            anyCaller.insert(file.lastPathComponent)
            if !targetsThatDoNotShipTheFeature.contains(where: { file.path.contains($0) }) {
                productionCallers.insert(file.lastPathComponent)
            }
        }

        // Pins the premise. An empty scan — a moved directory, a renamed type —
        // would satisfy "no production caller" for the wrong reason and turn the
        // branch below into a guard that can never fire. The harness builds a
        // governor and demotes with it, so the scan must see that one.
        #expect(anyCaller.contains("main.swift"),
                "the scan found no ProcGovernor construction anywhere under Sources; it is looking in the wrong place")

        // Wired: the documents may speak in the present tense, because it is
        // then true.
        guard productionCallers.isEmpty else { return }

        for name in ["docs/ACCEPTED-RISKS.md", "docs/ROADMAP.md",
                     "docs/coffee-bar-HANDOFF.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            // Failure-closed. A mis-resolved path would otherwise report a clean
            // document, which is the false-absence trap `DocsClaims_test.swift`
            // records.
            #expect(text.count > 1000,
                    "\(name) read back as \(text.count) bytes; this guard is scanning the wrong file")
            #expect(text.contains(unwiredMarker),
                    """
                    \(name) describes ProcGovernor but never says "\(unwiredMarker)", \
                    and no file outside \(targetsThatDoNotShipTheFeature) calls it. \
                    A reader concludes the feature is live. It is not.
                    """)
        }
    }
}
