// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
import Darwin
@testable import CoffeeBarPower

// The protected set, checked as an INVARIANT rather than as a list of examples.
//
// A demotion applied to the wrong process degrades the user's machine silently:
// nothing reports it, the process just gets slow. So the rule is stated once,
// as one sentence, and the checks below hold that sentence rather than a
// handful of pids somebody thought of:
//
//   A process may be demoted if and only if the user named it in the demotable
//   set AND no deny rule matches it. The deny set wins over the demotable set in
//   every case, including when a process is in both.
//
// `everyCombinationOfDenyRulesAndTheDemotableSetObeysTheInvariant` walks all 512
// combinations of the nine conditions and compares each against that sentence,
// written out independently. A guard built from the implementation's own
// structure would agree with any bug the implementation has.

/// A synthetic process, so a check can describe `pid` 1 or a foreign uid without
/// this suite needing the privilege to create one.
///
/// Every field is set explicitly. A default would let a dimension the caller
/// meant to vary sit at a constant, and the cross-product below would then test
/// half of what it claims to.
private func snapshot(pid: pid_t, uid: uid_t, ppid: pid_t, pgid: pid_t,
                      name: String, flags: UInt32 = 0x1404010) -> ProcSnapshot {
    ProcSnapshot(pid: pid, uid: uid, ppid: ppid, pgid: pgid, name: name, flags: flags)
}

/// The first process on this machine, at `pid` 100 or above, that belongs to
/// another user.
///
/// Found rather than named: which uid runs which daemon is not this project's to
/// pin, and a hard-coded `WindowServer` would make the check depend on a window
/// server being up. `proc_listallpids` is the unprivileged enumeration and needs
/// no entitlement.
private func firstForeignUIDProcess(_ inspector: SystemProcessInspector) -> ProcSnapshot? {
    let capacity = Int(proc_listallpids(nil, 0))
    guard capacity > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: capacity)
    let bytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return nil }
    let count = Int(bytes) / MemoryLayout<pid_t>.size

    return pids.prefix(count)
        .filter { $0 >= DemotionPolicy.lowestDemotablePID }
        .sorted()
        .lazy
        .compactMap { inspector.snapshot(of: $0) }
        .first { $0.uid != getuid() }
}

@Suite struct DemotionPolicyTests {

    // MARK: - The invariant

    @Test func everyCombinationOfDenyRulesAndTheDemotableSetObeysTheInvariant() {
        // THE check for this task. The bug it catches: a policy that consults
        // the demotable set FIRST and returns early, so a process the user opted
        // in is demoted even though it is the frontmost app, an agent, or
        // coffee-bar itself. Issue #11 shipped exactly that shape of defect —
        // a value bounded on one path and not on another — and the fix was one
        // door with one rule.
        //
        // Nine independent conditions, all 512 combinations. The expected answer
        // is computed from the rule as one sentence, not from the policy's
        // control flow.
        let ourPID: pid_t = 4242
        let ourUID = getuid()
        let ourPGID: pid_t = 777
        let ancestor: pid_t = 6001
        let frontmost: pid_t = 6002
        let agent: pid_t = 6003

        for mask in 0..<512 {
            let lowPID          = mask & 0b0_0000_0001 != 0
            let foreignUID      = mask & 0b0_0000_0010 != 0
            let isSelf          = mask & 0b0_0000_0100 != 0
            let sameGroup       = mask & 0b0_0000_1000 != 0
            let isAncestor      = mask & 0b0_0001_0000 != 0
            let isProtectedName = mask & 0b0_0010_0000 != 0
            let isAgent         = mask & 0b0_0100_0000 != 0
            let isFrontmost     = mask & 0b0_1000_0000 != 0
            let inDemotable     = mask & 0b1_0000_0000 != 0

            // One pid dimension at a time, so the conditions stay independent.
            var pid: pid_t = 5000
            if lowPID { pid = 42 }
            if isSelf { pid = ourPID }
            if isAncestor { pid = ancestor }
            if isFrontmost { pid = frontmost }
            if isAgent { pid = agent }

            let name = isProtectedName ? "WindowServer" : "cb-ordinary"
            let subject = snapshot(
                pid: pid,
                uid: foreignUID ? ourUID &+ 1 : ourUID,
                ppid: 1,
                pgid: sameGroup ? ourPGID : 888,
                name: name)

            let policy = DemotionPolicy(
                demotableNames: inDemotable ? [name] : [],
                agentPIDs: isAgent ? [agent] : [],
                frontmostPID: isFrontmost ? frontmost : nil,
                selfPID: isSelf ? pid : ourPID,
                selfUID: ourUID,
                selfPGID: ourPGID,
                ancestorPIDs: isAncestor ? [ancestor] : [])

            // The rule, as one sentence. Written as a list rather than a chain
            // of `&&` because the Swift type checker gives up on the chain.
            let denyRules = [lowPID, foreignUID, isSelf, sameGroup,
                             isAncestor, isProtectedName, isAgent, isFrontmost]
            let noDenyRuleMatches = !denyRules.contains(true)
            let shouldBeAllowed = inDemotable && noDenyRuleMatches

            let verdict = policy.verdict(for: subject)
            let message = "mask \(mask): verdict \(verdict), expected allowed="
                + "\(shouldBeAllowed) (demotable=\(inDemotable), deny-free=\(noDenyRuleMatches))"
            #expect((verdict == .allowed) == shouldBeAllowed, "\(message)")
        }
    }

    @Test func aProcessInBothSetsIsRefused() {
        // The precedence rule on its own, spelled out because it is the one an
        // author gets wrong: the user opting a process in must NOT beat the
        // protected set. Stated separately from the cross-product so the failure
        // message names the rule rather than a bit mask.
        let subject = snapshot(pid: 5000, uid: getuid(), ppid: 1, pgid: 888,
                               name: "WindowServer")
        let policy = DemotionPolicy(
            demotableNames: ["WindowServer"],
            selfPID: 4242, selfUID: getuid(), selfPGID: 777)

        #expect(policy.verdict(for: subject) == .refused(.protectedName))
    }

    // MARK: - Each rule reports itself

    @Test func eachDenyRuleIsReportedUnderItsOwnReason() {
        // The bug: a policy that refuses correctly but blames the wrong rule.
        // The refusal reason is what the report and the logs show a user who
        // asks why their opt-in did nothing, so a wrong reason sends them to
        // change the wrong setting.
        let ourUID = getuid()
        let ordinary = "cb-ordinary"

        let cases: [(DemotionRefusal, ProcSnapshot, DemotionPolicy)] = [
            (.systemProcess,
             snapshot(pid: 42, uid: ourUID, ppid: 1, pgid: 888, name: ordinary),
             DemotionPolicy(demotableNames: [ordinary], selfPID: 4242,
                            selfUID: ourUID, selfPGID: 777)),

            (.foreignUID,
             snapshot(pid: 5000, uid: ourUID &+ 1, ppid: 1, pgid: 888, name: ordinary),
             DemotionPolicy(demotableNames: [ordinary], selfPID: 4242,
                            selfUID: ourUID, selfPGID: 777)),

            (.coffeeBarItself,
             snapshot(pid: 4242, uid: ourUID, ppid: 1, pgid: 888, name: ordinary),
             DemotionPolicy(demotableNames: [ordinary], selfPID: 4242,
                            selfUID: ourUID, selfPGID: 777)),

            (.ownProcessGroup,
             snapshot(pid: 5000, uid: ourUID, ppid: 1, pgid: 777, name: ordinary),
             DemotionPolicy(demotableNames: [ordinary], selfPID: 4242,
                            selfUID: ourUID, selfPGID: 777)),

            (.ancestor,
             snapshot(pid: 6001, uid: ourUID, ppid: 1, pgid: 888, name: ordinary),
             DemotionPolicy(demotableNames: [ordinary], selfPID: 4242,
                            selfUID: ourUID, selfPGID: 777, ancestorPIDs: [6001])),

            (.protectedName,
             snapshot(pid: 5000, uid: ourUID, ppid: 1, pgid: 888, name: "loginwindow"),
             DemotionPolicy(demotableNames: ["loginwindow"], selfPID: 4242,
                            selfUID: ourUID, selfPGID: 777)),

            (.trackedAgent,
             snapshot(pid: 6003, uid: ourUID, ppid: 1, pgid: 888, name: ordinary),
             DemotionPolicy(demotableNames: [ordinary], agentPIDs: [6003],
                            selfPID: 4242, selfUID: ourUID, selfPGID: 777)),

            (.frontmostApplication,
             snapshot(pid: 6002, uid: ourUID, ppid: 1, pgid: 888, name: ordinary),
             DemotionPolicy(demotableNames: [ordinary], frontmostPID: 6002,
                            selfPID: 4242, selfUID: ourUID, selfPGID: 777)),

            (.notInDemotableSet,
             snapshot(pid: 5000, uid: ourUID, ppid: 1, pgid: 888, name: ordinary),
             DemotionPolicy(demotableNames: [], selfPID: 4242,
                            selfUID: ourUID, selfPGID: 777)),
        ]

        for (expected, subject, policy) in cases {
            #expect(policy.verdict(for: subject) == .refused(expected),
                    "\(expected) was not reported for pid \(subject.pid) named \(subject.name)")
        }

        // Completeness. A new refusal reason added without a fixture above turns
        // this red, so the table cannot silently fall behind the rule it checks.
        #expect(Set(cases.map(\.0)) == Set(DemotionRefusal.allCases))
    }

    // MARK: - The default

    @Test func anEmptyDemotableSetRefusesEveryOrdinaryProcess() {
        // Handoff §2.3: "Default `demotable` to empty. Opt-in only." The bug
        // this catches is a policy that treats an empty set as "no restriction"
        // — which is how an allow list becomes a deny list by accident, and
        // every same-uid process on the machine becomes eligible.
        let policy = DemotionPolicy(demotableNames: [], selfPID: 4242,
                                    selfUID: getuid(), selfPGID: 777)

        for name in ["Xcode", "node", "cb-ordinary", ""] {
            let subject = snapshot(pid: 5000, uid: getuid(), ppid: 1, pgid: 888, name: name)
            #expect(policy.verdict(for: subject) == .refused(.notInDemotableSet),
                    "an empty demotable set let \(name) through")
        }
    }

    @Test func theNamesThatAreAlwaysProtectedCannotBeOptedIn() {
        // Handoff §5.6 names these. They are compiled in rather than
        // configurable: a user who types `WindowServer` into their demotable
        // list has made a mistake, and honouring it freezes their display
        // server. The bug this catches is a protected list read from settings,
        // where an empty or corrupt value would disable the protection.
        let ourUID = getuid()
        #expect(!DemotionPolicy.alwaysProtectedNames.isEmpty,
                "an empty floor protects nothing; the loop below would be vacuous")

        for name in DemotionPolicy.alwaysProtectedNames {
            let policy = DemotionPolicy(demotableNames: [name], selfPID: 4242,
                                        selfUID: ourUID, selfPGID: 777)
            let subject = snapshot(pid: 5000, uid: ourUID, ppid: 1, pgid: 888, name: name)
            #expect(policy.verdict(for: subject) == .refused(.protectedName),
                    "\(name) was demotable")
        }
    }

    // MARK: - Against real processes

    @Test func thePolicyRefusesThisProcessAndThePidsTheSystemOwns() throws {
        // Read against the real machine rather than a synthetic snapshot, so a
        // field the inspector fills differently from this suite's fixture
        // cannot hide a hole. coffee-bar demoting itself is the self-defeating
        // case; `pid` 1 is `launchd`.
        let inspector = SystemProcessInspector()
        let me = try #require(inspector.snapshot(of: getpid()))
        let policy = DemotionPolicy(
            demotableNames: [me.name],           // opted in, deliberately
            selfPID: getpid(), selfUID: getuid(), selfPGID: pid_t(getpgrp()))

        #expect(policy.verdict(for: me) == .refused(.coffeeBarItself))

        // `launchd`. Readable because the inspector reads the UNPRIVILEGED
        // record; an earlier version of this task read the privileged one, saw
        // `nil`, and the rule below was unreachable.
        let launchd = try #require(inspector.snapshot(of: 1),
                                   "the protected set cannot refuse a process it cannot see")
        let openForLaunchd = DemotionPolicy(
            demotableNames: [launchd.name],
            selfPID: getpid(), selfUID: getuid(), selfPGID: pid_t(getpgrp()))
        #expect(openForLaunchd.verdict(for: launchd) == .refused(.systemProcess))

        // A real process belonging to a real other user — `WindowServer` runs as
        // uid 88 on this machine. The uid rule is the one that matters most in
        // practice, because most of what a protected set refuses belongs to
        // somebody else, and it can only fire on a process the inspector sees.
        let foreign = try #require(
            firstForeignUIDProcess(inspector),
            "no process of another uid was visible; the uid rule below is untested here")
        let openForForeign = DemotionPolicy(
            demotableNames: [foreign.name],
            selfPID: getpid(), selfUID: getuid(), selfPGID: pid_t(getpgrp()))
        #expect(openForForeign.verdict(for: foreign) == .refused(.foreignUID))
    }

    @Test func aChildThisSuiteStartedIsAllowedOnlyOnceItIsOptedIn() throws {
        // The other half of the invariant, and the one that proves the policy is
        // not simply refusing everything. A policy that always refused would
        // pass every check above.
        let child = try spawnIdleChild(named: "cb-optin")
        defer { child.stop() }
        let inspector = SystemProcessInspector()
        let subject = try #require(inspector.snapshot(of: child.pid))

        // The real group of this test runner, not a stand-in. The helper leaves
        // our process group on the way up, so the own-group rule is exercised
        // rather than dodged — a check that passed a fake group would prove
        // nothing about the rule a real run applies.
        let ourGroup = pid_t(getpgrp())
        try #require(subject.pgid != ourGroup,
                     "the child stayed in our process group; the allow below would be unreachable")

        let closed = DemotionPolicy(demotableNames: [], selfPID: getpid(),
                                    selfUID: getuid(), selfPGID: ourGroup)
        #expect(closed.verdict(for: subject) == .refused(.notInDemotableSet))

        let open = DemotionPolicy(demotableNames: ["cb-optin"], selfPID: getpid(),
                                  selfUID: getuid(), selfPGID: ourGroup)
        #expect(open.verdict(for: subject) == .allowed)
    }

    // MARK: - Ancestors

    @Test func theAncestorWalkReachesTheTestRunnerAndStops() throws {
        // Why ancestors are protected at all: the shell that launched
        // coffee-bar, and the terminal above it, are the user's session. The
        // brief calls for "the user's shell session leaders", and a name list
        // cannot express that — the user's shell could be any binary. Walking
        // the parent chain states it as a relationship instead.
        //
        // The bug this catches is a walk that does not terminate. A ppid chain
        // with a cycle, or one that never reaches 0, spins for ever inside a
        // path that runs before any demotion.
        let child = try spawnIdleChild(named: "cb-ancestor")
        defer { child.stop() }

        let ancestors = SystemProcessInspector().ancestors(of: child.pid)

        #expect(ancestors.contains(getpid()), "the test runner is the child's parent")
        #expect(!ancestors.contains(child.pid), "a process is not its own ancestor")
        #expect(ancestors.count < 64, "the walk did not terminate promptly")
    }

    // MARK: - Which rule refuses, and not merely that one did

    @Test func aForeignProcessIsRefusedByItsUidBeforeItsNameIsEverConsulted() {
        // Nothing pinned this ordering, and that was measured rather than
        // supposed: moving the `foreignUID` rule below `protectedName` left all
        // 700 checks green. Both are deny rules, so the invariant every other
        // check in this file holds — allowed if and only if named AND no deny
        // rule matches — is blind to their order.
        //
        // The order decides WHICH refusal a user is shown, and that is the whole
        // reason `DemotionRefusal` carries nine cases instead of one: "you named
        // another user's process" and "you named a process the system depends
        // on" send the user to change different things.
        //
        // It also settles a reason that was attached to the 15-character bound
        // on `alwaysProtectedNames` and was wrong. That bound cannot exist so
        // that foreign-uid processes match the protected list, because a
        // foreign-uid process never reaches the list.
        let policy = DemotionPolicy(demotableNames: ["WindowServer"],
                                    selfPID: 4001, selfUID: getuid(), selfPGID: 4002)

        // Another user's WindowServer: in the protected list AND foreign.
        let foreign = snapshot(pid: 5000, uid: getuid() &+ 1, ppid: 1, pgid: 999_001,
                               name: "WindowServer")
        #expect(policy.verdict(for: foreign) == .refused(.foreignUID),
                "a foreign-uid process reached the name rule; the uid rule must refuse first")

        // The same name, this user's own process, so the name rule is the one
        // left to fire. Without this the check above would pass for a policy
        // that had lost the protected-name rule altogether.
        let mine = snapshot(pid: 5001, uid: getuid(), ppid: 1, pgid: 999_001,
                            name: "WindowServer")
        #expect(policy.verdict(for: mine) == .refused(.protectedName))
    }

    @Test func everyProtectedNameStillMatchesWhenOnlyTheShortFieldIsAvailable() {
        // The TRUE reason for the bound on `alwaysProtectedNames`, stated as
        // behaviour instead of as a character count.
        //
        // The reachable path is not a foreign-uid process — that one is refused
        // by uid first, as the check above pins. It is a process this user OWNS
        // whose privileged record `SystemProcessInspector.snapshot(of:)` could
        // not read, which happens when the process exits between the two reads.
        // `snapshot(of:)` then falls back to `pbsi_comm`, 15 characters, and the
        // uid is still this user's, so the name rule IS consulted against a
        // truncated name.
        //
        // The bug: a 21-character entry added to the protected list. It would
        // match the full name and silently fail to match the truncated one, so
        // the process would fall through to the demotable set — and a user who
        // had named it would demote a process the list exists to protect.
        // Asserting `name.count <= 15` says the same thing; asserting the
        // verdict says it in the terms the failure arrives in.
        let policy = DemotionPolicy(demotableNames: DemotionPolicy.alwaysProtectedNames,
                                    selfPID: 4001, selfUID: getuid(), selfPGID: 4002)

        for name in DemotionPolicy.alwaysProtectedNames {
            let truncated = String(name.prefix(SystemProcessInspector.shortNameLimit))
            let short = snapshot(pid: 5000, uid: getuid(), ppid: 1, pgid: 999_001,
                                 name: truncated)
            #expect(policy.verdict(for: short) == .refused(.protectedName),
                    """
                    \(name) is \(name.count) characters, so the kernel's short field \
                    reports "\(truncated)" and the protected list does not match it. \
                    A user who named that process would demote it.
                    """)
        }
    }
}
