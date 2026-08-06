// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import Darwin
import CoffeeBarCore
import CoffeeBarIngest
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

// MARK: - The model that drives it

/// Holds nothing and counts nothing. These checks are about demotion.
private struct NoHold: AssertionHolding, @unchecked Sendable {
    @discardableResult func acquire(displaySleep: Bool) -> Bool { true }
    func release() {}
}

private struct FixedPower: PowerReadingProviding {
    let reading: PowerReading
    func read() -> PowerReading { reading }
}

/// Reports every tool wired, and reads NO file.
///
/// The shipping default is `HookHealthReader()` over the real
/// `~/.claude/settings.json`, so a model built without this would report a
/// different health on every developer's machine — and would read a file these
/// checks have no business opening.
private struct WiredHooks: HookHealthProviding {
    func status() -> HookHealthStatus { .wired }
    func statuses() -> [AgentTool: HookHealthStatus] { [.claudeCode: .wired] }
}

/// Binds nothing. The shipping default is the REAL listener, which would take
/// `~/Library/Application Support/coffee-bar/ingest.sock` off a live app.
private struct NoIngest: IngestListening {
    func start(onEvent: @escaping @Sendable (AgentTool, HookEvent) -> Void) throws {}
    func stop() {}
    var isReady: Bool { false }
}

/// A settings store held in memory, so no check edits the preferences of
/// whoever runs the suite.
private final class FakeSettings: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    init(_ initial: [String: Any] = [:]) { values = initial }

    func bool(forKey key: String) -> Bool? { lock.withLock { values[key] as? Bool } }
    func setBool(_ value: Bool, forKey key: String) { lock.withLock { values[key] = value } }
    func integer(forKey key: String) -> Int? { lock.withLock { values[key] as? Int } }
    func setInteger(_ value: Int, forKey key: String) { lock.withLock { values[key] = value } }
    func stringArray(forKey key: String) -> [String]? {
        lock.withLock { values[key] as? [String] }
    }
    func setStringArray(_ value: [String], forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

@MainActor
private func makeModel(fixture: Fixture, settings: FakeSettings,
                       source: PowerSource = .battery) -> ServingModel {
    ServingModel(holder: NoHold(),
                 reader: FixedPower(reading: PowerReading(source: source, percent: 80)),
                 health: WiredHooks(),
                 settings: settings,
                 listener: NoIngest(),
                 governance: fixture.governance)
}

/// One tool call from an agent, which `SessionHub` turns into a WORKING
/// session. It carries no pid, because no hook payload does.
private func aToolCall(session: String = "s1") -> HookEvent {
    HookEvent(hookEventName: "PreToolUse", sessionID: session,
              cwd: "/Users/example/src/coffee-bar", toolName: "Bash")
}

@Suite struct ServingModelGovernanceTests {

    @MainActor
    @Test func theQuietOthersSwitchStartsOffAndIsWrittenWhenTheUserChangesIt() {
        // The second opt-in, held to the shape `holdDisplayAwake` set. The
        // write half is what makes the choice survive a relaunch; without it
        // the panel remembers it for exactly as long as the app runs and every
        // other check here stays green.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }
        let store = FakeSettings()
        let model = makeModel(fixture: fixture, settings: store)

        #expect(model.quietEverythingElse == false, "the switch did not ship off")
        #expect(store.bool(forKey: SettingsKey.quietEverythingElse) == nil,
                "precondition: nothing was stored before the user touched anything")

        model.quietEverythingElse = true
        #expect(store.bool(forKey: SettingsKey.quietEverythingElse) == true)

        model.quietEverythingElse = false
        // `false`, not absent. A store that deleted the key on an opt-out would
        // read as "never asked", which is the difference `SettingsStoring`
        // exists to keep.
        #expect(store.bool(forKey: SettingsKey.quietEverythingElse) == false)
    }

    // `@MainActor` because `ServingModel` is, so its labels are too. The three
    // labels beside this one are held the same way rather than made
    // `nonisolated`: `PanelView.versionLine(from:)` records that the 6.1.2 CI
    // toolchain and a 6.3 developer machine disagree about isolation
    // inference, and this repository pins no toolchain.
    @MainActor
    @Test func theQuietOthersLabelNamesWhatIsQuietedAndClaimsNoSpeedUp() {
        // The wording is CONSTRAINED, and the constraint is a measurement
        // rather than a preference. macOS has no mechanism to promote a
        // process: the handoff cites Oakley twice, that `taskpolicy` "functions
        // as a brake, but not as an accelerator", and this package demotes
        // through `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` and
        // has no opposite call. So a label reading "Boost agents" would tell
        // the user something the product cannot do, in the one place this
        // product promises to tell the truth.
        //
        // The banned list is not decoration. A rename to "Boost agents" fails
        // the literal above AND names which rule it broke, which is the
        // difference between a check that says "changed" and one that says
        // "changed, and here is why you may not".
        //
        // `%` covers the other half: no battery saving, no percentage and no
        // duration. A 2026-08-01 audit spent a day removing unverifiable claims
        // of exactly that shape.
        #expect(ServingModel.quietOthersLabel == "Quiet everything else")

        for banned in ["Boost", "boost", "Speed", "speed", "Faster", "faster",
                       "Accelerat", "accelerat", "%", "battery", "minutes", "hours"] {
            #expect(ServingModel.quietOthersLabel.contains(banned) == false, """
                the quiet-others label says "\(banned)". macOS cannot promote a \
                process and this build measures no battery saving, so the label \
                names what is QUIETED and claims nothing else.
                """)
        }
    }

    @MainActor
    @Test func aStoredQuietOthersSwitchIsReadBackAtTheNextLaunch() {
        // The read half. Named bug this catches: an `init` that ignores the
        // store, so every launch starts opted out. Every check that sets the
        // value itself before reading it stays green.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }
        let model = makeModel(fixture: fixture,
                              settings: FakeSettings([SettingsKey.quietEverythingElse: true]))

        #expect(model.quietEverythingElse == true)
    }

    @MainActor
    @Test func aWorkingSessionOnBatteryQuietsTheProcessTheUserNamed() {
        // THE end-to-end claim, and the one no check on `ProcessGovernance`
        // alone can make: that `refresh()` measures the four conditions off the
        // model's own state and hands them down. Named bug this catches: a
        // model that stores the switch, renders it, and calls nothing — which
        // is `LaunchDaemonInstaller` shipping unreachable, one milestone later.
        //
        // The session here carries NO pid, because no hook payload does. That
        // is what makes this a check on the shipped path rather than on a
        // fixture nothing produces.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }
        let model = makeModel(
            fixture: fixture,
            settings: FakeSettings([SettingsKey.quietEverythingElse: true,
                                    SettingsKey.demotableProcessNames: ["Slack"]]))

        // Precondition: nothing is demoted before an agent starts working, so
        // the demotion below is caused by the event.
        model.refresh()
        #expect(fixture.kernel.demoted.isEmpty, "something was demoted with no session running")

        model.ingest(from: .claudeCode, aToolCall())

        #expect(fixture.kernel.demoted == [slackPID],
                "a working agent on battery quieted nothing the user named")
    }

    @MainActor
    @Test func theModelQuietsNothingWhileTheSwitchIsOff() {
        // The switch is the only one of the four conditions the panel can move,
        // so this is the check a user's own hand exercises. Everything else is
        // held true.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }
        let model = makeModel(
            fixture: fixture,
            settings: FakeSettings([SettingsKey.demotableProcessNames: ["Slack"]]))

        model.ingest(from: .claudeCode, aToolCall())

        #expect(fixture.kernel.demoted.isEmpty, "the switch was off and a process was demoted")
    }

    @MainActor
    @Test func turningTheSwitchOffRestoresImmediatelyRatherThanAtTheNextTick() {
        // A user who turns this off is asking for their applications back NOW,
        // not within 30 seconds. `batteryFloorPercent` sets the same rule for
        // the same reason — `changingTheFloorReconcilesImmediatelyRatherThan
        // AtTheNextTick`.
        let fixture = slackRunning()
        defer { fixture.removeJournal() }
        let model = makeModel(
            fixture: fixture,
            settings: FakeSettings([SettingsKey.quietEverythingElse: true,
                                    SettingsKey.demotableProcessNames: ["Slack"]]))

        model.ingest(from: .claudeCode, aToolCall())
        #expect(fixture.kernel.demoted == [slackPID], "nothing was quieted, so nothing can restore")

        model.quietEverythingElse = false

        #expect(fixture.kernel.restored == [slackPID],
                "turning the switch off left the process demoted")
    }

    @MainActor
    @Test func theModelRestoresWhatAnEarlierRunLeftDemoted() {
        // The launch and clean-exit path, through the one method `main.swift`
        // calls. An earlier run was killed before it could restore, so the
        // journal is the only record naming the process it left behind.
        let fixture = Fixture(
            running: [], table: [snapshot(slackPID, "Slack",
                                          flags: untouchedFlags | ProcSnapshot.externalDarwinBackground)])
        defer { fixture.removeJournal() }
        try? fixture.journal.append(
            DemotionEntry(identity: identity(slackPID), name: "Slack",
                          priorFlags: untouchedFlags,
                          demotedAt: Date(timeIntervalSince1970: 1_785_911_481)))

        let model = makeModel(fixture: fixture, settings: FakeSettings())
        model.restoreDemotedProcesses()

        #expect(fixture.kernel.restored == [slackPID],
                "a demotion an earlier run recorded survived this launch")
    }

    @MainActor
    @Test func aModelWithNoGovernanceDemotesNothingAndDoesNotFail() {
        // The default. `governance` is the ONE seam on this type whose default
        // is null rather than real, and the direction is why: a null listener
        // ships an app with no ingest and nothing to notice, while a null
        // governance ships an app that demotes nothing — which is this
        // product's documented default and the safe answer. A real default
        // would also point every check in this package at the user's own
        // journal file and their own running applications.
        //
        // The missing wire cannot ship silently:
        // `theAppComposesTheProcessGovernanceAndRecoversAtLaunchAndOnQuit` reads
        // `main.swift` for it.
        let model = ServingModel(holder: NoHold(),
                                 reader: FixedPower(reading: PowerReading(source: .battery,
                                                                          percent: 80)),
                                 health: WiredHooks(),
                                 settings: FakeSettings([
                                    SettingsKey.quietEverythingElse: true,
                                    SettingsKey.demotableProcessNames: ["Slack"]]),
                                 listener: NoIngest())

        model.ingest(from: .claudeCode, aToolCall())
        model.restoreDemotedProcesses()

        #expect(model.quietEverythingElse == true,
                "the model without a governance stopped reading its own settings")
    }
}
