// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import AppKit
import Darwin
import CoffeeBarPower

/// Which application processes are running, and which one is in front.
///
/// **A seam at the app-layer boundary, and it lives HERE rather than in
/// `CoffeeBarPower`.** The three seams this package already has —
/// `PowerReadingProviding`, `SettingsStoring` and the one behind the sleep
/// assertion — each sit beside the thing they abstract, and the thing abstracted
/// here is `NSWorkspace`, which is AppKit. `DemotionPolicy`'s own doc comment
/// states the rule this follows: discovering the frontmost application, the
/// tracked agents and the ancestor chain "is I/O and belongs at the composition
/// root, which is also the only place that can know them". The composition root
/// is this layer.
///
/// **It answers with PIDS and with nothing else, and that is the point.** A
/// provider that also handed back `NSRunningApplication.localizedName` is a
/// provider somebody can match the user's demotable set against, and that match
/// is wrong in a way nothing reports: the set is matched against the name the
/// KERNEL gives, so `"Visual Studio Code"` would be compared with a kernel name
/// of `"Code"`, miss, and demote nothing. The rule is exact-match, so it fails
/// CLOSED — the user sees a setting they configured doing nothing at all, which
/// reads as a dead product rather than as a defect.
/// `theDemotableSetIsMatchedAgainstTheKernelNameNeverADisplayName` holds both
/// directions.
public protocol RunningApplicationsProviding: Sendable {

    /// Every application process running right now, by pid.
    ///
    /// LIMIT, stated rather than hidden: this reaches applications only. A
    /// headless process — a compiler, a test runner, a container daemon —
    /// appears nowhere here and therefore cannot be demoted by this build. That
    /// is a deliberate bound on the blast radius rather than an oversight;
    /// `docs/ACCEPTED-RISKS.md` records it.
    func runningApplicationPIDs() -> [pid_t]

    /// The application the user is looking at, or `nil` when there is none.
    func frontmostApplicationPID() -> pid_t?
}

/// The real one, over `NSWorkspace`.
///
/// `proc_listpids(PROC_ALL_PIDS)` is the alternative and is rejected. The
/// handoff's own capability table records that it blocks sandboxing, which is a
/// permanent constraint on the whole application bought for a feature whose
/// demotable set is empty by default. It is NOT a capability question:
/// `DemotionPolicy_test.swift` already enumerates with `proc_listallpids` and it
/// works unprivileged. It is a question of scope, and of how far this app can
/// reach when it goes wrong.
public struct WorkspaceApplications: RunningApplicationsProviding {

    public init() {}

    public func runningApplicationPIDs() -> [pid_t] {
        NSWorkspace.shared.runningApplications.map(\.processIdentifier)
    }

    public func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// What the trigger decided this time round.
public enum QuietOthersDecision: Equatable, Sendable {

    /// All four conditions hold: put the demotable set into darwin background
    /// state.
    case quiet

    /// At least one condition does not hold: undo everything this app demoted.
    case restore
}

/// Reports the FIRST failure of a run of failures, and stays quiet after it.
///
/// `ProcessGovernance.restoreEverythingDemoted()` runs on the 30-second ticker,
/// so a journal file it cannot read reports the same failure about 2900 times a
/// day for as long as the app runs. Measured at 5 lines for 5 ticks. The signal
/// is in the FIRST line; every line after it is noise, and the noise buries
/// whatever is reported next.
///
/// **Edge-triggered on the attempt, and NEVER on the message text.** The first
/// draft compared the whole message and it did not work: `String(describing:)`
/// of a `DecodingError` prints the underlying `NSError`'s `UserInfo`, which is a
/// DICTIONARY, so its keys come out in hash order and two reports of one
/// unchanged file differ. Measured — five ticks over one corrupt file produced
/// `UserInfo={NSJSONSerializationErrorIndex=1, NSDebugDescription=…}` and
/// `UserInfo={NSDebugDescription=…, NSJSONSerializationErrorIndex=1}`,
/// alternating. Any rule keyed on that text is a rule keyed on a hash seed.
///
/// LIMIT, stated rather than hidden: two DIFFERENT failures with no successful
/// attempt between them report once, not twice. That is the price of not keying
/// on the text. `succeeded()` runs after every attempt that does not throw, so a
/// failure that returns after a good run is reported again — without it this
/// would be a switch that turns reporting off for ever.
/// `aFailureThatReturnsAfterAGoodRunIsReportedAgain` holds that half.
///
/// A class inside a `Sendable` struct on purpose. Every copy of a
/// `ProcessGovernance` then shares ONE box, which is what makes "once" mean once
/// for the process rather than once per copy — and the struct is copied on every
/// call, because that is what passing a struct does.
final class FailureEdge: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false

    /// True when the previous attempt did NOT fail, so this failure is news.
    func isNews() -> Bool {
        lock.withLock {
            defer { failing = true }
            return failing == false
        }
    }

    /// Records an attempt that did not throw, so the next failure is reported.
    func succeeded() { lock.withLock { failing = false } }
}

/// The composition root for process demotion.
///
/// **This is the type that makes `ProcGovernor` reachable.** It is in
/// `CoffeeBarUI` and not in `CoffeeBarPower` for two reasons that agree. It
/// needs AppKit, which the power layer does not import. And every optional
/// protection `DemotionPolicy` takes is live state that only the running
/// application can measure, which is the same reason `CoffeeBarGovernorHarness`
/// builds its policy in `main.swift`.
///
/// **Every optional protection is supplied here, on every call.**
/// `DemotionPolicy.init` defaults `agentPIDs`, `frontmostPID`, `ancestorPIDs`
/// and `extraProtectedNames` to empty, so four of its nine deny rules are OFF
/// unless a caller fills them — and no caller but this one can. Leaving any of
/// them at its default is not a missing feature, it is a protection silently
/// removed. `theAppLayerSuppliesEveryOptionalProtectionToDemotionPolicy` refuses
/// a construction here that omits one, and four checks in
/// `ProcessGovernance_test.swift` measure each rule biting.
///
/// **Correctly bounded, so do not read more into it than is there.** The
/// demotable set is opt-in and empty by default, so nothing on the machine is
/// demotable until a user names something. The hazard this closes is "the user
/// named Slack and Slack is in front", not "anything can be demoted".
public struct ProcessGovernance: Sendable {

    /// coffee-bar's own executables, which no user list may reach.
    ///
    /// The `selfPID` and `selfPGID` rules do not cover these. `coffeebar-hook`
    /// runs on EVERY agent tool call and is spawned by the agent tool, so it
    /// belongs to the AGENT's process group rather than to coffee-bar's — a
    /// user who named it would put a brake on every tool call an agent makes,
    /// through the one component whose contract is that it never delays the
    /// agent. The names are the `Package.swift` product names, which is what the
    /// kernel reports for each.
    public static let ownExecutableNames: Set<String> = [
        "coffee-bar",
        "coffeebar-hook",
        "coffee-bar-probe",
    ]

    private let applications: any RunningApplicationsProviding
    private let inspector: any ProcessInspecting
    private let journal: any DemotionJournalStoring
    private let setter: any DarwinBackgroundSetting
    private let selfPID: pid_t
    private let selfUID: uid_t
    private let selfPGID: pid_t
    private let report: @Sendable (String) -> Void

    /// Shared by every copy of this struct, which is what makes "reported once"
    /// mean once for the process. Built here rather than injected: it is state
    /// this type owns, and no caller has anything to say about it.
    private let reported = FailureEdge()

    /// Every default is the REAL implementation, for the reason `ServingModel`'s
    /// listener default is: a null default lets a missing wire ship silently.
    /// The identity values are read once at construction, because none of them
    /// can change for the life of a process.
    ///
    /// - Parameter report: where a failure this type cannot rethrow goes. A seam
    ///   because the alternative is a check that reads Console.app. The message
    ///   is passed as an ARGUMENT and never as the format string: an error
    ///   description is text this process did not write, and a `%s` in it would
    ///   send `NSLog` reading from a pointer that is not there.
    public init(applications: any RunningApplicationsProviding = WorkspaceApplications(),
                inspector: any ProcessInspecting = SystemProcessInspector(),
                journal: any DemotionJournalStoring = FileDemotionJournalStore(),
                setter: any DarwinBackgroundSetting = SystemDarwinBackground(),
                selfPID: pid_t = getpid(),
                selfUID: uid_t = getuid(),
                selfPGID: pid_t = pid_t(getpgrp()),
                report: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) {
        self.applications = applications
        self.inspector = inspector
        self.journal = journal
        self.setter = setter
        self.selfPID = selfPID
        self.selfUID = selfUID
        self.selfPGID = selfPGID
        self.report = report
    }

    /// Whether to quiet anything right now. Carlos settled these four, and they
    /// are an AND.
    ///
    /// 1. the machine is **on battery** — handoff §1.3 makes power triage an
    ///    on-battery behaviour;
    /// 2. at least one **agent is working** — with no work to give the
    ///    performance cores to, demoting the user's applications is a cost with
    ///    nothing behind it;
    /// 3. the **demotable set is non-empty** — the first opt-in, handoff §2.3;
    /// 4. the **switch is on** — the second opt-in.
    ///
    /// **PURE, and every input is a value the caller measured.** That is what
    /// makes the four checks proving the AND synchronous: they call this, read
    /// the answer, and no clock takes part. An absence asserted after a wait —
    /// "nothing was demoted yet" — passes under load whether the wiring is right
    /// or not.
    ///
    /// `static`, because it reads none of this type's state, and a check that
    /// wants to ask it a question should not have to build a governor first.
    ///
    /// **Condition 2 is a COUNT of working sessions and never a set of pids,
    /// and that is measured rather than a preference.** `AgentSession` carries
    /// a `pid` and it is ALWAYS `nil` in a shipped build: `HookEvent` has no pid
    /// field and `SessionHub` constructs every session with `pid: nil`. A
    /// condition that required a non-empty pid set would therefore be false on
    /// every real machine for ever — the switch on, the list configured, the
    /// battery discharging, and nothing happening.
    /// `aWorkingSessionWithNoPidStillMeetsTheAgentCondition` holds it.
    public static func decision(onBattery: Bool,
                                workingAgentCount: Int,
                                demotableNames: Set<String>,
                                quietEverythingElse: Bool) -> QuietOthersDecision {
        guard onBattery,
              workingAgentCount > 0,
              demotableNames.isEmpty == false,
              quietEverythingElse
        else { return .restore }
        return .quiet
    }

    /// Decides, then makes the machine match. Safe to call on the ticker.
    ///
    /// SYNCHRONOUS from end to end. Everything it does is finished when it
    /// returns, so a caller — and a check — reads the result immediately and
    /// never has to wait to find out that nothing happened.
    ///
    /// - Parameters:
    ///   - workingAgentCount: how many sessions are doing work, which drives
    ///     condition 2.
    ///   - protectedAgentPIDs: every agent coffee-bar tracks, working or not.
    ///     WIDER than the working sessions on purpose: an agent blocked on the
    ///     user is still an agent, and demoting it is still self-defeating.
    ///
    ///     **Empty in a shipped build today, and that is stated rather than
    ///     hidden.** No ingest payload carries a pid, so `AgentSession.pid` is
    ///     always `nil`. The rule is wired and the data is missing, which is a
    ///     protection that does nothing until ingest learns a pid — never a
    ///     protection that was left switched off here.
    @discardableResult
    public func reconcile(onBattery: Bool,
                          workingAgentCount: Int,
                          protectedAgentPIDs: Set<pid_t>,
                          demotableNames: Set<String>,
                          quietEverythingElse: Bool) -> QuietOthersDecision {
        let decision = Self.decision(onBattery: onBattery,
                                     workingAgentCount: workingAgentCount,
                                     demotableNames: demotableNames,
                                     quietEverythingElse: quietEverythingElse)

        switch decision {
        case .quiet:
            quiet(demotableNames: demotableNames, protectedAgentPIDs: protectedAgentPIDs)
        case .restore:
            restoreEverythingDemoted()
        }
        return decision
    }

    /// Undoes every demotion this app recorded, and nothing else.
    ///
    /// Call it at launch and on a clean exit. Both are the same operation: the
    /// journal names what to undo, and an entry outlives whatever wrote it.
    ///
    /// It restores what the JOURNAL names and never what is running.
    /// `setpriority(PRIO_DARWIN_PROCESS, pid, 0)` on a process that was already
    /// background PROMOTES it — handoff §5.6 — so a sweep over the running
    /// applications would speed up processes their own authors put on the
    /// E-cores. `restoringPromotesNothingTheJournalDoesNotName` holds it.
    public func restoreEverythingDemoted() {
        do {
            // Nothing is recorded, so there is nothing to undo. Deciding that
            // costs one read of a file that usually does not exist, and it is
            // the ORDINARY answer: the demotable set is empty by default, so
            // `reconcile` lands on `.restore` on every one of the ~2900 ticks a
            // day that every user who never opted in runs.
            //
            // Without it, this path builds a `DemotionPolicy` first — which
            // asks `NSWorkspace` for the frontmost application AND walks this
            // process's parent chain through the kernel. Measured over 3 idle
            // ticks before this line existed: 3 workspace queries and 6 kernel
            // queries, all of them about a journal with nothing in it.
            // `aTickThatRestoresNothingMeasuresNothing` holds the zeroes.
            //
            // `try` and never `try?`. A journal that will not decode must not
            // read as "nothing was demoted": `FileDemotionJournalStore.load()`
            // states that rule, and `try?` here would strand every process the
            // unreadable record names.
            guard try journal.load()?.entries.isEmpty == false else {
                reported.succeeded()
                return
            }
            try makeGovernor(demotableNames: [], protectedAgentPIDs: []).recover()
            reported.succeeded()
        } catch {
            // Reported and not rethrown, for the reason `main.swift` catches a
            // refused socket: this runs at launch and on the ticker, and an
            // unreadable journal must not stop the app. The entries stay on
            // disk, so the next run tries again.
            //
            // ONCE per distinct failure, and that is why `reported` exists.
            // This runs on the ticker, so a corrupt journal wrote the same line
            // every 30 seconds for as long as the app ran — measured at 5 lines
            // for 5 ticks — and the repetition buries the next, DIFFERENT
            // failure a reader needs to see.
            let message = "coffee-bar: could not restore demoted processes: \(error)"
            if reported.isNews() { report(message) }
        }
    }

    /// Puts every running application the user named into background state.
    private func quiet(demotableNames: Set<String>, protectedAgentPIDs: Set<pid_t>) {
        let governor = makeGovernor(demotableNames: demotableNames,
                                    protectedAgentPIDs: protectedAgentPIDs)

        for pid in applications.runningApplicationPIDs() {
            // Already in background state, so leave it alone. Two different
            // situations land here and the answer is the same for both: this
            // run demoted it on an earlier pass, or another tool did. Demoting
            // again would journal a second entry whose `priorFlags` carry the
            // external bit, which `DemotionEntry.appliedByThisApp` correctly
            // reads as somebody else's doing — and this path runs every 30
            // seconds, so the journal would grow for the life of the process.
            // `aSecondReconcileDoesNotJournalTheSameProcessAgain` holds it.
            guard let snapshot = inspector.snapshot(of: pid),
                  snapshot.isExternallyBackgrounded == false
            else { continue }

            do {
                try governor.demote(pid)
            } catch ProcGovernorError.refused(_) {
                // The ORDINARY answer, for every application the user did not
                // name. Reporting it would write one line per running
                // application per pass.
            } catch {
                NSLog("coffee-bar: could not quiet pid \(pid): \(error)")
            }
        }
    }

    /// The one place a `DemotionPolicy` is built outside the library.
    ///
    /// One place, so the four optional protections are filled once and cannot
    /// drift between the demote path and the restore path.
    ///
    /// **`internal` rather than `private`, so a check can ask THIS root what it
    /// decides about one process and read the REASON.** `reconcile` cannot
    /// answer that: it catches `ProcGovernorError.refused(_)` and drops the
    /// case, deliberately, because reporting every refusal would write one line
    /// per running application per pass. A check that composed its own policy
    /// instead would answer about a policy this product never builds — so a
    /// wrong argument to `ancestors(of:)` here would not appear in it, which is
    /// exactly the hole `anAncestorOfCoffeeBarIsRefusedEvenWhenTheUserNamedIt`
    /// had until 2026-08-06.
    func policy(demotableNames: Set<String>,
                protectedAgentPIDs: Set<pid_t>) -> DemotionPolicy {
        DemotionPolicy(demotableNames: demotableNames,
                       agentPIDs: protectedAgentPIDs,
                       frontmostPID: applications.frontmostApplicationPID(),
                       selfPID: selfPID,
                       selfUID: selfUID,
                       selfPGID: selfPGID,
                       ancestorPIDs: inspector.ancestors(of: selfPID),
                       extraProtectedNames: Self.ownExecutableNames)
    }

    private func makeGovernor(demotableNames: Set<String>,
                              protectedAgentPIDs: Set<pid_t>) -> ProcGovernor {
        ProcGovernor(
            policy: policy(demotableNames: demotableNames,
                           protectedAgentPIDs: protectedAgentPIDs),
            journal: journal,
            inspector: inspector,
            setter: setter)
    }
}
