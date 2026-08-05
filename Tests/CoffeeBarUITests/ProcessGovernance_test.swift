// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import Darwin
import CoffeeBarPower
@testable import CoffeeBarUI

// The composition root for process demotion, and the trigger that drives it.
//
// **Every check here is SYNCHRONOUS, and that is a requirement rather than a
// style.** Four of them assert an ABSENCE — that nothing was demoted — and an
// absence asserted inside a bounded wait passes for the wrong reason under
// starvation: the awaited call has simply not happened yet. `reconcile` returns
// only after it has finished deciding and acting, so the recorded call list is
// complete at the moment it returns and no clock takes part in any assertion.
//
// **No check here touches a process it does not own.** The kernel is a fake and
// the journal is a real `FileDemotionJournalStore` on a throwaway path, which is
// the shape `ProcGovernor_test.swift` already uses.

// MARK: - Test doubles

/// The kernel, faked at ONE boundary.
///
/// It is both the inspector and the setter on purpose. Those two are the same
/// thing on a real machine — `setpriority` is what makes the next
/// `proc_pidinfo` report the external background bit — and two separate doubles
/// could not express "already demoted", which is the state
/// `aSecondReconcileDoesNotJournalTheSameProcessAgain` is about.
private final class FakeKernel: ProcessInspecting, DarwinBackgroundSetting, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [pid_t: ProcSnapshot]
    private var identities: [pid_t: ProcIdentity]
    private var _calls: [(on: Bool, pid: pid_t)] = []
    private let result: Int32

    init(table: [pid_t: ProcSnapshot], identities: [pid_t: ProcIdentity], result: Int32 = 0) {
        self.table = table
        self.identities = identities
        self.result = result
    }

    var calls: [(on: Bool, pid: pid_t)] { lock.withLock { _calls } }
    var demoted: [pid_t] { calls.filter(\.on).map(\.pid) }
    var restored: [pid_t] { calls.filter { !$0.on }.map(\.pid) }

    func snapshot(of pid: pid_t) -> ProcSnapshot? { lock.withLock { table[pid] } }

    func identity(of pid: pid_t) -> ProcIdentity? { lock.withLock { identities[pid] } }

    func setBackground(_ on: Bool, for pid: pid_t) -> Int32 {
        lock.withLock {
            _calls.append((on, pid))
            guard let was = table[pid] else { return }
            let flags = on
                ? was.flags | ProcSnapshot.externalDarwinBackground
                : was.flags & ~ProcSnapshot.externalDarwinBackground
            table[pid] = ProcSnapshot(pid: was.pid, uid: was.uid, ppid: was.ppid,
                                      pgid: was.pgid, name: was.name, flags: flags)
        }
        return result
    }
}

/// A fixed list of pids, and a fixed frontmost pid.
///
/// It hands back PIDS ONLY, and no display name, because that is the whole
/// shape of the real one: a provider that could answer with
/// `NSRunningApplication.localizedName` is a provider somebody can match the
/// demotable set against, and that match fails closed and looks like a dead
/// setting. See `theDemotableSetIsMatchedAgainstTheKernelNameNeverADisplayName`.
private struct FakeApplications: RunningApplicationsProviding {
    let pids: [pid_t]
    var frontmost: pid_t?

    func runningApplicationPIDs() -> [pid_t] { pids }
    func frontmostApplicationPID() -> pid_t? { frontmost }
}

// MARK: - The machine every check below runs on

/// coffee-bar's own pid, its process group, and the shell above it.
///
/// Values no real process on the machine holds, so a check cannot pass by
/// accident against the suite's own process.
private let selfPID: pid_t = 9_000_100
private let selfPGID: pid_t = 9_000_200
private let parentPID: pid_t = 9_000_050

/// The untouched flags word, measured on macOS 26.5.2 (25F84) and recorded in
/// `ProcessInspector.swift`.
private let untouchedFlags: UInt32 = 0x140_4010

private func snapshot(_ pid: pid_t, _ name: String,
                      ppid: pid_t = 1, pgid: pid_t = 5555,
                      flags: UInt32 = untouchedFlags) -> ProcSnapshot {
    ProcSnapshot(pid: pid, uid: getuid(), ppid: ppid, pgid: pgid, name: name, flags: flags)
}

private func identity(_ pid: pid_t) -> ProcIdentity {
    ProcIdentity(pid: pid, startedAtSeconds: 1_785_911_481, startedAtMicroseconds: UInt64(pid))
}

private func journalPath() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cb-governance-\(UUID().uuidString)")
        .appendingPathComponent("demotion-journal.json")
}

/// The whole composition root, with the kernel faked and the journal real.
private struct Fixture {
    let governance: ProcessGovernance
    let kernel: FakeKernel
    let journal: FileDemotionJournalStore
    let journalURL: URL

    /// - Parameters:
    ///   - running: what the workspace reports, by pid.
    ///   - frontmost: the application the user is looking at.
    ///   - table: what the kernel says about each pid.
    init(running: [pid_t], frontmost: pid_t? = nil, table: [ProcSnapshot]) {
        var byPID = Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) })
        byPID[selfPID] = snapshot(selfPID, "coffee-bar", ppid: parentPID, pgid: selfPGID)
        byPID[parentPID] = snapshot(parentPID, "zsh", ppid: 0, pgid: selfPGID)

        kernel = FakeKernel(
            table: byPID,
            identities: Dictionary(uniqueKeysWithValues: byPID.keys.map { ($0, identity($0)) }))
        journalURL = journalPath()
        journal = FileDemotionJournalStore(url: journalURL)
        governance = ProcessGovernance(
            applications: FakeApplications(pids: running, frontmost: frontmost),
            inspector: kernel,
            journal: journal,
            setter: kernel,
            selfPID: selfPID,
            selfUID: getuid(),
            selfPGID: selfPGID)
    }

    func removeJournal() {
        try? FileManager.default.removeItem(at: journalURL.deletingLastPathComponent())
    }
}

/// The demotable process every check below points at.
private let slackPID: pid_t = 4242

private func slackRunning(frontmost: pid_t? = nil) -> Fixture {
    Fixture(running: [slackPID], frontmost: frontmost, table: [snapshot(slackPID, "Slack")])
}

@Suite struct ProcessGovernanceTests {

    // MARK: - The trigger is an AND of four conditions

    @Test func allFourConditionsTogetherQuietTheProcessTheUserNamed() throws {
        // The positive control for the four checks below. Without it each of
        // them could pass because the wiring demotes NOTHING, ever, which is
        // exactly what a dead setting looks like.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        let decision = fixture.governance.reconcile(
            onBattery: true,
            workingAgentCount: 1,
            protectedAgentPIDs: [777],
            demotableNames: ["Slack"],
            quietEverythingElse: true)

        #expect(decision == .quiet)
        #expect(fixture.kernel.demoted == [slackPID])
        // Journal FIRST, then the call. The entry is what a later run reads
        // back, so a demotion nothing on disk names is unrecoverable.
        #expect(try fixture.journal.load()?.entries.map(\.identity.pid) == [slackPID])
    }

    @Test func onACPowerNothingIsQuieted() throws {
        // Condition 1 of four, with the other three held true. Handoff §1.3
        // makes power triage an ON BATTERY behaviour: quieting the user's apps
        // while the machine is plugged in buys nothing and costs them a
        // sluggish Slack.
        //
        // The assertion is on the RETURNED decision and on the completed call
        // list, both available the instant `reconcile` returns. There is no
        // wait here and there must never be one: "nothing was demoted" checked
        // after a timeout passes under load whether the wiring is right or not.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        let decision = fixture.governance.reconcile(
            onBattery: false,
            workingAgentCount: 1,
            protectedAgentPIDs: [777],
            demotableNames: ["Slack"],
            quietEverythingElse: true)

        #expect(decision == .restore)
        #expect(fixture.kernel.demoted.isEmpty)
    }

    @Test func withNoAgentWorkingNothingIsQuieted() throws {
        // Condition 2 of four. The feature exists to give an agent's work the
        // performance cores while it runs. With nothing running there is no
        // work to give them to, so demoting the user's own applications would
        // be a cost with no purpose behind it.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        let decision = fixture.governance.reconcile(
            onBattery: true,
            workingAgentCount: 0,
            protectedAgentPIDs: [],
            demotableNames: ["Slack"],
            quietEverythingElse: true)

        #expect(decision == .restore)
        #expect(fixture.kernel.demoted.isEmpty)
    }

    @Test func withAnEmptyDemotableSetNothingIsQuieted() throws {
        // Condition 3 of four, and the FIRST of the two opt-ins. Handoff §2.3
        // makes the set opt-in only, because an app that silently demotes a
        // compile job or a video call is uninstalled the same day.
        //
        // `DemotionPolicy` refuses an unnamed process on its own, so this looks
        // redundant. It is not: it holds the TRIGGER, which must not reach the
        // demote loop at all with an empty set — and it is the one condition
        // whose absence would leave the app enumerating every running
        // application every 30 seconds to demote none of them.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        let decision = fixture.governance.reconcile(
            onBattery: true,
            workingAgentCount: 1,
            protectedAgentPIDs: [777],
            demotableNames: [],
            quietEverythingElse: true)

        #expect(decision == .restore)
        #expect(fixture.kernel.demoted.isEmpty)
    }

    @Test func withTheSwitchOffNothingIsQuieted() throws {
        // Condition 4 of four, and the SECOND opt-in. Carlos chose two over
        // one on 2026-08-05: a user who has named a process needs a way to
        // stop the behaviour that does not cost them their list.
        //
        // Named bug this catches: a trigger that reads the demotable set and
        // ignores the switch. Every other check in this file would stay green,
        // and the panel control would be a switch that does nothing — which
        // reads to a user as a broken product rather than as a missing wire.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        let decision = fixture.governance.reconcile(
            onBattery: true,
            workingAgentCount: 1,
            protectedAgentPIDs: [777],
            demotableNames: ["Slack"],
            quietEverythingElse: false)

        #expect(decision == .restore)
        #expect(fixture.kernel.demoted.isEmpty)
    }

    // MARK: - The name that is matched is the kernel's

    @Test func theDemotableSetIsMatchedAgainstTheKernelNameNeverADisplayName() throws {
        // THE trap, and it fails CLOSED, which is what makes it dangerous: the
        // user names "Visual Studio Code", the kernel calls that process
        // "Code", the exact match misses, and nothing is demoted. No error is
        // reported anywhere. The user sees a setting they configured that does
        // nothing at all, which is worse than a crash.
        //
        // Both directions are held, because the passing half alone would also
        // pass for a wiring that matched a SUBSTRING or a prefix — and a loose
        // match widens the blast radius, which is the opposite of what this
        // set is for.
        let kernelName = Fixture(running: [slackPID], table: [snapshot(slackPID, "Code")])
        defer { kernelName.removeJournal() }

        #expect(kernelName.governance.reconcile(
            onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [777],
            demotableNames: ["Code"], quietEverythingElse: true) == .quiet)
        #expect(kernelName.kernel.demoted == [slackPID],
                "the kernel's own name for the process did not match the set")

        let displayName = Fixture(running: [slackPID], table: [snapshot(slackPID, "Code")])
        defer { displayName.removeJournal() }

        #expect(displayName.governance.reconcile(
            onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [777],
            demotableNames: ["Visual Studio Code"], quietEverythingElse: true) == .quiet)
        #expect(displayName.kernel.demoted.isEmpty,
                "a display name matched a process whose kernel name is Code")
    }

    // MARK: - Every optional protection is supplied here, and each one bites

    @Test func theFrontmostApplicationIsRefusedEvenWhenTheUserNamedIt() throws {
        // `DemotionPolicy.init` takes `frontmostPID: pid_t? = nil`, and `nil`
        // switches the rule OFF. Wiring the governor and leaving that default
        // makes the application the user is looking at demotable the moment
        // they name it — the single most visible way this feature can go wrong.
        //
        // The composition root is the only place that can know the answer, so
        // this check reads the value through the provider rather than asserting
        // that some argument was written.
        let fixture = slackRunning(frontmost: slackPID)
        defer { fixture.removeJournal() }

        #expect(fixture.governance.reconcile(
            onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [777],
            demotableNames: ["Slack"], quietEverythingElse: true) == .quiet)

        #expect(fixture.kernel.demoted.isEmpty,
                "the application the user is looking at was demoted")
    }

    @Test func aTrackedAgentIsRefusedEvenWhenTheUserNamedIt() throws {
        // `agentPIDs` defaults to empty too. Demoting the agent whose work
        // keeps the machine awake is self-defeating, and a user who put a
        // terminal application in their list has done exactly that.
        let fixture = Fixture(running: [slackPID], table: [snapshot(slackPID, "Slack")])
        defer { fixture.removeJournal() }

        #expect(fixture.governance.reconcile(
            onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [slackPID],
            demotableNames: ["Slack"], quietEverythingElse: true) == .quiet)

        #expect(fixture.kernel.demoted.isEmpty, "a tracked agent's process was demoted")
    }

    @Test func anAncestorOfCoffeeBarIsRefusedEvenWhenTheUserNamedIt() throws {
        // `ancestorPIDs` defaults to empty. The parent chain is the user's
        // shell and the terminal above it, and demoting the terminal an agent
        // is running inside slows the agent this feature exists to serve.
        //
        // The walk starts at coffee-bar's own pid, so this also proves the
        // composition root passes its OWN pid to `ancestors(of:)` and not some
        // other one: `parentPID` is reachable only from `selfPID`.
        let fixture = Fixture(running: [parentPID], table: [])
        defer { fixture.removeJournal() }

        #expect(fixture.governance.reconcile(
            onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [777],
            demotableNames: ["zsh"], quietEverythingElse: true) == .quiet)

        #expect(fixture.kernel.demoted.isEmpty, "coffee-bar's own parent shell was demoted")
    }

    @Test func coffeeBarsOwnHookIsRefusedEvenWhenTheUserNamedIt() throws {
        // `extraProtectedNames` defaults to empty, and it is the fourth
        // protection the composition root is the only place able to fill.
        //
        // The `selfPID` and `selfPGID` rules do not cover this one. The hook
        // shim runs on EVERY tool call, spawned by the agent tool, so it is in
        // the AGENT's process group and not coffee-bar's — a user who put
        // "coffeebar-hook" in their list would put a brake on every tool call
        // the agent makes, through the one component whose whole contract is
        // that it never delays the agent.
        let fixture = Fixture(running: [slackPID], table: [snapshot(slackPID, "coffeebar-hook")])
        defer { fixture.removeJournal() }

        #expect(fixture.governance.reconcile(
            onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [777],
            demotableNames: ["coffeebar-hook"], quietEverythingElse: true) == .quiet)

        #expect(fixture.kernel.demoted.isEmpty, "coffee-bar's own hook shim was demoted")
    }

    // MARK: - Reconciling repeatedly, and restoring

    @Test func aSecondReconcileDoesNotJournalTheSameProcessAgain() throws {
        // `refresh()` runs every 30 seconds, so this path is walked ~2900 times
        // a day. Named bug this catches: a demote loop that journals an entry
        // per pass. The journal then grows without bound for the life of the
        // process, and every entry after the first records `priorFlags` with
        // the external bit ALREADY set — which `DemotionEntry.appliedByThisApp`
        // reads as "somebody else put it there", so recovery refuses them.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        for _ in 0..<3 {
            _ = fixture.governance.reconcile(
                onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [777],
                demotableNames: ["Slack"], quietEverythingElse: true)
        }

        #expect(fixture.kernel.demoted == [slackPID], "the same process was demoted repeatedly")
        #expect(try fixture.journal.load()?.entries.count == 1)
    }

    @Test func aConditionGoingFalseRestoresWhatWasQuieted() throws {
        // "Restore when ANY of the four stops". The machine going back on AC
        // power is the commonest way that happens, and it happens while the
        // app is running rather than at a restart.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        _ = fixture.governance.reconcile(
            onBattery: true, workingAgentCount: 1, protectedAgentPIDs: [777],
            demotableNames: ["Slack"], quietEverythingElse: true)
        #expect(fixture.kernel.demoted == [slackPID], "nothing was quieted, so nothing can restore")

        let decision = fixture.governance.reconcile(
            onBattery: false, workingAgentCount: 1, protectedAgentPIDs: [777],
            demotableNames: ["Slack"], quietEverythingElse: true)

        #expect(decision == .restore)
        #expect(fixture.kernel.restored == [slackPID], "the process stayed demoted on AC power")
        // The entry is gone, so a later run does not act on it twice.
        #expect(try fixture.journal.load() == nil)
    }

    @Test func restoringEverythingDemotedUndoesWhatAnEarlierRunLeftBehind() throws {
        // The launch and clean-exit path. An earlier run demoted this process
        // and was killed before it could restore, so the journal on disk is the
        // only record naming it — which is the whole reason the journal is
        // written before the call it describes.
        let fixture = Fixture(
            running: [], table: [snapshot(slackPID, "Slack",
                                          flags: untouchedFlags | ProcSnapshot.externalDarwinBackground)])
        defer { fixture.removeJournal() }

        try fixture.journal.append(DemotionEntry(identity: identity(slackPID), name: "Slack",
                                                 priorFlags: untouchedFlags,
                                                 demotedAt: Date(timeIntervalSince1970: 1_785_911_481)))

        fixture.governance.restoreEverythingDemoted()

        #expect(fixture.kernel.restored == [slackPID],
                "a demotion an earlier run recorded was left in place")
        #expect(try fixture.journal.load() == nil)
    }

    @Test func aWorkingSessionWithNoPidStillMeetsTheAgentCondition() throws {
        // THE condition that decides whether this feature works at all in a
        // shipped build, and it is measured here rather than assumed.
        //
        // `AgentSession` carries a `pid`, and it is ALWAYS `nil` in production:
        // `HookEvent` has no pid field, and `SessionHub` builds every session
        // with `pid: nil`. So a trigger whose "an agent is working" condition
        // counted session PIDS would be false on every real machine, for ever.
        // The switch would be on, the list would be configured, the battery
        // would be discharging, and nothing would happen — the exact "appears
        // configured and does nothing" failure this task exists to avoid.
        //
        // The condition is therefore a COUNT of working sessions. The pids are
        // still passed, as `protectedAgentPIDs`, because that is a PROTECTION:
        // it is empty today for the same upstream reason, and an empty deny set
        // protects nothing while a wrong trigger breaks everything.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        let decision = fixture.governance.reconcile(
            onBattery: true,
            workingAgentCount: 1,
            protectedAgentPIDs: [],
            demotableNames: ["Slack"],
            quietEverythingElse: true)

        #expect(decision == .quiet)
        #expect(fixture.kernel.demoted == [slackPID],
                "a working session with no pid did not meet the agent condition")
    }

    @Test func restoringPromotesNothingTheJournalDoesNotName() throws {
        // The other half, and the failure it prevents is worse than the one
        // above. `setpriority(PRIO_DARWIN_PROCESS, pid, 0)` on a process that
        // was ALREADY background PROMOTES it — handoff §5.6 warns about exactly
        // that. A restore that swept every running application would speed up
        // processes their own authors put on the E-cores.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }

        fixture.governance.restoreEverythingDemoted()

        #expect(fixture.kernel.calls.isEmpty,
                "a restore touched a process no journal entry named")
    }
}
