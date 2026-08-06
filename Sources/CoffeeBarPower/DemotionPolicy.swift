// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

/// Why a process may not be demoted.
///
/// One case per rule, so a refusal can say which rule stopped it. A user whose
/// opt-in did nothing needs to know whether they named the wrong process or
/// named a protected one; "refused" alone sends them to change the wrong thing.
public enum DemotionRefusal: String, Codable, Equatable, Sendable, CaseIterable {
    /// The user never opted this process in. The default answer.
    case notInDemotableSet
    /// `pid` below `DemotionPolicy.lowestDemotablePID`, which the system owns.
    case systemProcess
    /// Another user's process. `setpriority` would refuse anyway; refusing here
    /// means the attempt is never made and is reported honestly.
    case foreignUID
    /// coffee-bar's own process.
    case ownProcessGroup
    /// coffee-bar itself.
    case coffeeBarItself
    /// coffee-bar's parent chain — the user's shell and terminal session.
    case ancestor
    /// A name the system depends on. Compiled in, never configurable.
    case protectedName
    /// An agent tool coffee-bar is tracking. Demoting the agent whose work keeps
    /// the machine awake is self-defeating.
    case trackedAgent
    /// The application the user is looking at.
    case frontmostApplication
}

public enum DemotionVerdict: Equatable, Sendable {
    case allowed
    case refused(DemotionRefusal)
}

/// Whether one process may be demoted. The whole rule, in one place.
///
/// **The invariant.** A process may be demoted if and only if the user named it
/// in the demotable set AND no deny rule matches it. The deny set wins over the
/// demotable set in every case, including when a process is in both.
///
/// `everyCombinationOfDenyRulesAndTheDemotableSetObeysTheInvariant` holds that
/// sentence across all 512 combinations of the nine conditions, so this type is
/// checked against the rule rather than against a list of pids somebody thought
/// of.
///
/// **One door.** This is the only place the rule is written, and
/// `ProcGovernor.demote(_:)` is the only caller. Issue #11 shipped the opposite
/// shape — a value bounded on the decision path and not on the display path —
/// and traded a stale-floor defect for an unbounded-floor one.
/// `nothingOutsideTheGovernorPutsAForeignProcessIntoBackground` keeps the
/// second door from being opened.
///
/// **Pure, and that is deliberate.** Every input is a value the caller measured.
/// Discovering them — the ancestor walk, the frontmost application, the tracked
/// agents — is I/O and belongs at the composition root, which is also the only
/// place that can know them. It keeps this type checkable against processes this
/// suite could not otherwise create, such as `pid` 1 or a foreign uid.
public struct DemotionPolicy: Sendable {

    /// Below this, the process belongs to the system.
    ///
    /// Handoff §5.6 sets the bound at 100 and the brief names `pid` 0 and 1.
    /// 100 is the stricter of the two and implies both. Nothing a user opts in
    /// to lands under it: the kernel hands low pids out once, at boot.
    public static let lowestDemotablePID: pid_t = 100

    /// Names that are never demotable, whatever the user configures.
    ///
    /// Handoff §5.6 names the first four. Compiled in rather than read from
    /// settings on purpose: if this list came from a preference, an empty or
    /// unreadable value would silently disable the protection, and the failure
    /// would look like a working app on a machine whose window server has just
    /// been throttled.
    ///
    /// This is a floor, not the whole protected set. The frontmost application,
    /// the tracked agents and the parent chain are all protected by rules that
    /// no name list can express.
    public static let alwaysProtectedNames: Set<String> = [
        "WindowServer",
        "loginwindow",
        "coreaudiod",
        "avconferenced",
        "launchd",
        "Dock",
        "SystemUIServer",
        "Finder",
    ]

    private let demotableNames: Set<String>
    private let agentPIDs: Set<pid_t>
    private let frontmostPID: pid_t?
    private let selfPID: pid_t
    private let selfUID: uid_t
    private let selfPGID: pid_t
    private let ancestorPIDs: Set<pid_t>
    private let protectedNames: Set<String>

    /// - Parameters:
    ///   - demotableNames: what the user opted in. Empty by default everywhere
    ///     it is built, per handoff §2.3.
    ///   - agentPIDs: the agent tools coffee-bar is tracking right now.
    ///   - frontmostPID: the application the user is looking at, when known.
    ///     `nil` protects nothing extra; it never widens what is allowed.
    ///   - ancestorPIDs: coffee-bar's parent chain, from `ancestors(of:)`.
    ///   - extraProtectedNames: added to `alwaysProtectedNames`, never replacing
    ///     it. A caller cannot shrink the floor.
    public init(demotableNames: Set<String>,
                agentPIDs: Set<pid_t> = [],
                frontmostPID: pid_t? = nil,
                selfPID: pid_t,
                selfUID: uid_t,
                selfPGID: pid_t,
                ancestorPIDs: Set<pid_t> = [],
                extraProtectedNames: Set<String> = []) {
        self.demotableNames = demotableNames
        self.agentPIDs = agentPIDs
        self.frontmostPID = frontmostPID
        self.selfPID = selfPID
        self.selfUID = selfUID
        self.selfPGID = selfPGID
        self.ancestorPIDs = ancestorPIDs
        self.protectedNames = Self.alwaysProtectedNames.union(extraProtectedNames)
    }

    /// Whether `snapshot` may be demoted.
    ///
    /// Deny rules run FIRST and every one of them runs before the demotable set
    /// is consulted. Reversing those two blocks is the bug the cross-product
    /// check exists to catch: it would let a user's opt-in beat the protection.
    public func verdict(for snapshot: ProcSnapshot) -> DemotionVerdict {
        if snapshot.pid < Self.lowestDemotablePID { return .refused(.systemProcess) }
        if snapshot.uid != selfUID { return .refused(.foreignUID) }
        if snapshot.pid == selfPID { return .refused(.coffeeBarItself) }
        if snapshot.pgid == selfPGID { return .refused(.ownProcessGroup) }
        if ancestorPIDs.contains(snapshot.pid) { return .refused(.ancestor) }
        if protectedNames.contains(snapshot.name) { return .refused(.protectedName) }
        if agentPIDs.contains(snapshot.pid) { return .refused(.trackedAgent) }
        if let frontmost = frontmostPID, snapshot.pid == frontmost {
            return .refused(.frontmostApplication)
        }

        // Only now, and an ALLOW list rather than a deny list. An empty set
        // refuses everything, which is the documented default.
        //
        // Matched exactly, with no prefix or substring rule. This set decides
        // what MAY be demoted, so a loose match widens the blast radius: the
        // kernel truncates a name at `SystemProcessInspector.nameLimit`, and a
        // prefix rule would let one long name stand for every other name that
        // starts the same way.
        guard demotableNames.contains(snapshot.name) else {
            return .refused(.notInDemotableSet)
        }
        return .allowed
    }
}

extension ProcessInspecting {

    /// Every pid above `pid` in the parent chain, up to the root.
    ///
    /// The user's shell and the terminal above it are coffee-bar's ancestors, so
    /// walking the chain states "the user's session" as a relationship. A name
    /// list cannot: the user's shell may be any binary.
    ///
    /// Bounded twice — a pid already seen ends the walk, and so does the depth
    /// limit. This runs before every demotion, so a ppid chain that loops must
    /// not spin.
    public func ancestors(of pid: pid_t, limit: Int = 64) -> Set<pid_t> {
        var found: Set<pid_t> = []
        var current = pid
        for _ in 0..<limit {
            guard let snapshot = snapshot(of: current) else { break }
            let parent = snapshot.ppid
            if parent <= 0 || found.contains(parent) { break }
            found.insert(parent)
            current = parent
        }
        return found
    }
}
