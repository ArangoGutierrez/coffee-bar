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

    /// Every default is the REAL implementation, for the reason `ServingModel`'s
    /// listener default is: a null default lets a missing wire ship silently.
    /// The identity values are read once at construction, because none of them
    /// can change for the life of a process.
    public init(applications: any RunningApplicationsProviding = WorkspaceApplications(),
                inspector: any ProcessInspecting = SystemProcessInspector(),
                journal: any DemotionJournalStoring = FileDemotionJournalStore(),
                setter: any DarwinBackgroundSetting = SystemDarwinBackground(),
                selfPID: pid_t = getpid(),
                selfUID: uid_t = getuid(),
                selfPGID: pid_t = pid_t(getpgrp())) {
        self.applications = applications
        self.inspector = inspector
        self.journal = journal
        self.setter = setter
        self.selfPID = selfPID
        self.selfUID = selfUID
        self.selfPGID = selfPGID
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
    public static func decision(onBattery: Bool,
                                workingAgentPIDs: Set<pid_t>,
                                demotableNames: Set<String>,
                                quietEverythingElse: Bool) -> QuietOthersDecision {
        guard onBattery,
              workingAgentPIDs.isEmpty == false,
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
    ///   - workingAgentPIDs: the agents doing work, which drives condition 2.
    ///   - protectedAgentPIDs: every agent coffee-bar tracks, working or not.
    ///     WIDER than the set above on purpose: an agent blocked on the user is
    ///     still an agent, and demoting it is still self-defeating.
    @discardableResult
    public func reconcile(onBattery: Bool,
                          workingAgentPIDs: Set<pid_t>,
                          protectedAgentPIDs: Set<pid_t>,
                          demotableNames: Set<String>,
                          quietEverythingElse: Bool) -> QuietOthersDecision {
        let decision = Self.decision(onBattery: onBattery,
                                     workingAgentPIDs: workingAgentPIDs,
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
            try makeGovernor(demotableNames: [], protectedAgentPIDs: []).recover()
        } catch {
            // Reported and not rethrown, for the reason `main.swift` catches a
            // refused socket: this runs at launch and on the ticker, and an
            // unreadable journal must not stop the app. The entries stay on
            // disk, so the next run tries again.
            NSLog("coffee-bar: could not restore demoted processes: \(error)")
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
    private func makeGovernor(demotableNames: Set<String>,
                              protectedAgentPIDs: Set<pid_t>) -> ProcGovernor {
        ProcGovernor(
            policy: DemotionPolicy(demotableNames: demotableNames,
                                   agentPIDs: protectedAgentPIDs,
                                   frontmostPID: applications.frontmostApplicationPID(),
                                   selfPID: selfPID,
                                   selfUID: selfUID,
                                   selfPGID: selfPGID,
                                   ancestorPIDs: inspector.ancestors(of: selfPID),
                                   extraProtectedNames: Self.ownExecutableNames),
            journal: journal,
            inspector: inspector,
            setter: setter)
    }
}
