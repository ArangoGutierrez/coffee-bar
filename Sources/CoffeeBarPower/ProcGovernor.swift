// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

/// Puts a process into darwin background state, or takes it out again.
///
/// A seam, so the governor's ordering and its refusals can be checked without
/// moving a real process. The one real implementation is `SystemDarwinBackground`.
public protocol DarwinBackgroundSetting: Sendable {
    /// - Returns: 0 on success, otherwise the `errno` the call set.
    func setBackground(_ on: Bool, for pid: pid_t) -> Int32
}

/// The real one, over `setpriority(2)`.
public struct SystemDarwinBackground: DarwinBackgroundSetting {
    public init() {}

    /// The argument order is load-bearing and is not the one the handoff sketch
    /// used. `PRIO_DARWIN_BG` (`0x1000`, `sys/resource.h:120`) is a *prio*
    /// value, not a *which* selector: `setpriority(PRIO_DARWIN_BG, pid, 0)`
    /// returns -1/EINVAL and changes nothing at all. Per `getpriority(2)` the
    /// `which` is `PRIO_DARWIN_PROCESS` and the `prio` is `PRIO_DARWIN_BG` to
    /// demote and `0` to restore. `DemotionProbe.swift` records the same thing.
    public func setBackground(_ on: Bool, for pid: pid_t) -> Int32 {
        // `id_t` is unsigned; `id_t(pid)` would trap on a negative pid rather
        // than let the kernel reject it.
        let who = id_t(bitPattern: pid)
        errno = 0
        let rc = setpriority(PRIO_DARWIN_PROCESS, who, on ? PRIO_DARWIN_BG : 0)
        return rc == 0 ? 0 : errno
    }
}

public enum ProcGovernorError: Error, Equatable {
    /// The protected set stopped it. Carries the rule that did.
    case refused(DemotionRefusal)
    /// There is no such process. The pid may already belong to something else.
    case vanished(pid_t)
    /// The process is there, but the kernel would not say WHICH process it is.
    ///
    /// A journal entry without an identity cannot be safely restored: a later
    /// run would have only the pid to go on, and a pid is not an identity.
    /// Reachable when the process exits between the two reads.
    case unidentifiable(pid_t)
    case setBackgroundFailed(pid_t, Int32)
}

/// What one recovery did, split by the reason.
///
/// Counts alone would hide which pid fell into which bucket, and the buckets are
/// the point: three of the four are refusals to act.
public struct RecoveryReport: Equatable, Sendable {
    /// Put back, because this app demoted it and it is still the same process.
    public let restored: [pid_t]
    /// Gone. Darwin background state is an attribute of the task, so it died
    /// with the process and there is nothing to undo.
    public let gone: [pid_t]
    /// Alive, but a DIFFERENT process now holds that pid.
    public let reused: [pid_t]
    /// Already background before this app touched it, so the bit belongs to
    /// somebody else.
    public let leftAlone: [pid_t]
    /// The restore call itself failed.
    public let failed: [pid_t]

    public init(restored: [pid_t] = [], gone: [pid_t] = [], reused: [pid_t] = [],
                leftAlone: [pid_t] = [], failed: [pid_t] = []) {
        self.restored = restored
        self.gone = gone
        self.reused = reused
        self.leftAlone = leftAlone
        self.failed = failed
    }
}

/// Demotes processes coffee-bar does not own, and undoes it after a crash.
///
/// **The first thing in this repository that touches a pid it does not own.**
/// `DemotionProbe` demotes and restores `getpid()` and nothing else, which is
/// what makes it safe under a crash for free: the state lives on the task that
/// dies. That is not available here, because a demotion applied to a FOREIGN
/// process is state on THAT process and outlives whatever applied it —
/// `anExternallyDemotedProcessStaysDemotedWhenTheDemoterIsSIGKILLed` measures it.
///
/// **Recovery is a journal a later run reads back. There is no supervisor
/// process.** Carlos chose this on 2026-08-05 over a recommendation panel
/// HARD-DISSENT. The reason is that a supervisor is a second process to install,
/// keep running and keep in step — not privilege: a supervisor would not have
/// needed root, and an earlier claim that it would was wrong and was withdrawn.
///
/// **The exposure this leaves, stated plainly.** A long-lived process such as a
/// browser stays demoted until coffee-bar next starts. It is bounded by
/// construction, because darwin background state is a process attribute and so
/// dies with the process and never survives a reboot. "Bounded" can still mean
/// days. This is not solved; it is accepted, and `docs/ROADMAP.md` says so.
///
/// **One door.** `demote(_:)` is the only method that puts a foreign process
/// into background state, and it is the only caller of `DemotionPolicy`.
/// `nothingOutsideTheGovernorPutsAForeignProcessIntoBackground` scans `Sources`
/// for a second call site. Issue #11 shipped the opposite shape — a value
/// bounded on the decision path and not on the display path — and traded one
/// defect for another.
public struct ProcGovernor: Sendable {
    private let policy: DemotionPolicy
    private let journal: any DemotionJournalStoring
    private let inspector: any ProcessInspecting
    private let setter: any DarwinBackgroundSetting
    private let now: @Sendable () -> Date

    public init(policy: DemotionPolicy,
                journal: any DemotionJournalStoring,
                inspector: any ProcessInspecting,
                setter: any DarwinBackgroundSetting,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        self.journal = journal
        self.inspector = inspector
        self.setter = setter
        self.now = now
    }

    /// Puts `pid` into darwin background state, after journalling the intent.
    ///
    /// The sequence is fixed and the order is the requirement:
    ///
    /// 1. **Read** the process's current state, so the restore target is
    ///    measured and not assumed.
    /// 2. **Refuse** unless the policy allows it. Before the journal, so a
    ///    process this app never demotes never gets an entry that would make a
    ///    later run clear somebody else's bit.
    /// 3. **Identify** it, and refuse if the kernel will not say which process
    ///    it is. An entry a later run cannot match is worse than no entry.
    /// 4. **Journal** the entry and force it to stable storage.
    /// 5. **Only then** call `setpriority`.
    ///
    /// Steps 4 and 5 are in that order because a journal written afterwards is
    /// defeated by a `SIGKILL` in the window between them: the process is
    /// demoted, nothing on disk names it, and no later run can undo it.
    /// `theJournalNamesThePidBeforeSetpriorityIsCalled` reads the journal off
    /// the filesystem at the moment the call is made, so agreeing that both
    /// happened is not enough to pass.
    public func demote(_ pid: pid_t) throws {
        guard let snapshot = inspector.snapshot(of: pid) else {
            throw ProcGovernorError.vanished(pid)
        }
        if case .refused(let reason) = policy.verdict(for: snapshot) {
            throw ProcGovernorError.refused(reason)
        }
        guard let identity = inspector.identity(of: pid) else {
            throw ProcGovernorError.unidentifiable(pid)
        }

        try journal.append(DemotionEntry(
            identity: identity,
            name: snapshot.name,
            priorFlags: snapshot.flags,
            demotedAt: now()))

        let code = setter.setBackground(true, for: pid)
        guard code == 0 else {
            // The entry stays. A journal naming a process this app failed to
            // demote costs one refused restore on the next run — the entry's
            // `priorFlags` show the bit was never set — where removing it would
            // cost a stranded process if the call in fact took effect.
            throw ProcGovernorError.setBackgroundFailed(pid, code)
        }
    }

    /// Undoes every demotion an earlier run recorded. Call it at start.
    ///
    /// **Four conditions, and a restore needs all four.** Each one is a separate
    /// way of promoting a process nobody asked to promote:
    ///
    /// 1. **The journal names it.** Nothing else is touched. `-B` on a process
    ///    born background PROMOTES it, which handoff §5.6 warns about.
    /// 2. **It is still alive.** A process that exited needs nothing: the state
    ///    was an attribute of the task and died with it.
    /// 3. **It is still the SAME process.** A pid is not an identity, because
    ///    macOS reuses pids. The journal carries the start time as well, so a
    ///    pid handed out again is left alone rather than restored blindly.
    /// 4. **This app set the bit.** A process that already carried
    ///    `EXT_DARWINBG` was put there by some other tool.
    ///
    /// The journal is cleared afterwards, so a later run does not act on it
    /// twice. Cleared even when some entries were refused: those entries
    /// describe processes this run has now decided never to touch, and keeping
    /// them only ages the pids further.
    @discardableResult
    public func recover() throws -> RecoveryReport {
        guard let record = try journal.load() else { return RecoveryReport() }

        var restored: [pid_t] = []
        var gone: [pid_t] = []
        var reused: [pid_t] = []
        var leftAlone: [pid_t] = []
        var failed: [pid_t] = []

        for entry in record.entries {
            let pid = entry.identity.pid

            guard inspector.snapshot(of: pid) != nil else {
                gone.append(pid)
                continue
            }
            // An unreadable identity lands here too, and belongs here: the
            // kernel refuses the privileged record for another user's process,
            // so a pid that now answers that way is not the process this app
            // demoted.
            guard inspector.identity(of: pid) == entry.identity else {
                reused.append(pid)
                continue
            }
            guard entry.appliedByThisApp else {
                leftAlone.append(pid)
                continue
            }

            if setter.setBackground(false, for: pid) == 0 {
                restored.append(pid)
            } else {
                failed.append(pid)
            }
        }

        try journal.clear()
        return RecoveryReport(restored: restored, gone: gone, reused: reused,
                              leftAlone: leftAlone, failed: failed)
    }
}
