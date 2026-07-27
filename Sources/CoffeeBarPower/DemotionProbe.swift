// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CoffeeBarCore

/// S5 — does putting a same-uid process into Darwin background state succeed,
/// and does clearing it work?
///
/// Handoff §2.1: this is a brake, never an accelerator. `PRIO_DARWIN_BG` has no
/// counterpart — there is no mechanism to promote a process onto P-cores, and
/// neither this probe nor a `.pass` from it implies one. All a `.pass` means is
/// that a process can be pushed DOWN and let back up again.
///
/// The argument order is load-bearing and is **not** the one the handoff sketch
/// used. `PRIO_DARWIN_BG` (`0x1000`, `sys/resource.h:120`) is a *prio* value,
/// not a *which* selector: `setpriority(PRIO_DARWIN_BG, pid, 0)` returns
/// -1/EINVAL and changes nothing at all. Per getpriority(2) the `which` is
/// `PRIO_DARWIN_PROCESS` and the `prio` is `PRIO_DARWIN_BG` to demote, `0` to
/// restore — `1` is not the documented clear value, it merely happens not to be
/// `PRIO_DARWIN_BG`.
public struct DemotionProbe {
    public init() {}

    public func run(targetPID: pid_t?) -> SpikeResult {
        run(targetPID: targetPID, whileDemoted: { _ in })
    }

    /// `run(targetPID:)` with an observation seam.
    ///
    /// `whileDemoted` is invoked between the demote and the restore — the only
    /// window in which the background state exists to be read back. Without it
    /// this probe is indistinguishable from one that makes neither syscall and
    /// reports the numbers it wishes were true, since every field below is
    /// self-reported. `run(targetPID:)` is the only production caller and
    /// passes an empty body.
    func run(targetPID: pid_t?, whileDemoted: (pid_t) -> Void) -> SpikeResult {
        guard let pid = targetPID else {
            return SpikeResult(
                id: .s5DemotionPrivilege, verdict: .notApplicable,
                detail: "no target process supplied", durationMS: 0,
                evidence: [:])
        }
        let start = Date()

        // `id_t` is unsigned; `id_t(pid)` would trap on a negative pid rather
        // than let the kernel reject it.
        let who = id_t(bitPattern: pid)

        errno = 0
        let demote = setpriority(PRIO_DARWIN_PROCESS, who, PRIO_DARWIN_BG)
        let demoteErrno = errno

        whileDemoted(pid)

        errno = 0
        let restore = setpriority(PRIO_DARWIN_PROCESS, who, 0)
        let restoreErrno = errno

        // Read the state back rather than trusting the restore's return code.
        // Leaving a process throttled is the one failure this probe must never
        // commit silently, and a return code is a claim about a call, not about
        // the machine.
        //
        // `getpriority` may legitimately return -1, hence the errno clear.
        // The reading is only conclusive when the target is us: verified on
        // macOS 26.5.2 (25F84) that `getpriority(PRIO_DARWIN_PROCESS, <other
        // pid>)` reads 0 even for a process Apple's own `/usr/sbin/taskpolicy
        // -b -p` has just backgrounded. `targetIsSelf` records which kind of
        // reading this was, so a `finalStateRestored: true` for a third party
        // is not mistaken for a verified one.
        errno = 0
        let background = getpriority(PRIO_DARWIN_PROCESS, who)
        let backgroundReadable = !(background == -1 && errno != 0)
        let backgroundText = backgroundReadable ? String(background) : "unreadable"

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let restored = restore == 0 && backgroundReadable && background == 0
        let ok = demote == 0 && restored

        return SpikeResult(
            id: .s5DemotionPrivilege,
            verdict: ok ? .pass : .fail,
            detail: ok
                ? "demoted pid \(pid) to background QoS and restored it"
                : "demote rc=\(demote) errno=\(demoteErrno), "
                  + "restore rc=\(restore) errno=\(restoreErrno), "
                  + "background after=\(backgroundText)",
            durationMS: ms,
            evidence: ["demoteReturn": String(demote),
                       "demoteErrno": String(demoteErrno),
                       "restoreReturn": String(restore),
                       "restoreErrno": String(restoreErrno),
                       "backgroundAfter": backgroundText,
                       "finalStateRestored": String(restored),
                       "targetIsSelf": String(pid == getpid()),
                       "pid": String(pid)])
    }
}
