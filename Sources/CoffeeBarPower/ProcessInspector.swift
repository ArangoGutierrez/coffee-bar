// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin

/// What the kernel reports about one process, read through `proc_pidinfo`.
///
/// **`proc_pidinfo` and never `getpriority`.** `getpriority(PRIO_DARWIN_PROCESS,
/// <other pid>)` cannot see another process's darwin background state: it reads
/// 0 for a demoted process, which is the same answer it gives for an undemoted
/// one. `DemotionProbe.swift` records that limit, and
/// `getpriorityCannotReportAnotherProcessDarwinBackgroundState` pins it. A
/// previous session read four zeroes out of that blind instrument and concluded
/// that cross-process demotion does nothing. It does.
///
/// **Two independent channels.** A process can be backgrounded by ITSELF and by
/// SOMEONE ELSE, and the two are separate bits that can both be set. Measured on
/// macOS 26.5.2 (25F84):
///
/// | state | `pbi_flags` |
/// |---|---|
/// | untouched | `0x1404010` |
/// | after a self demote | `0x140c010` — sets `0x8000` |
/// | after an external demote | `0x1014010` — sets `0x10000`, clears the donor bit |
///
/// An external restore clears only the EXTERNAL bit. Measured: a process that
/// backgrounded itself keeps `0x8000` through
/// `setpriority(PRIO_DARWIN_PROCESS, pid, 0)` from outside. So this app can undo
/// its own demotion without promoting a process that chose to be background —
/// but it can still undo a demotion a THIRD party applied, which is why
/// `DemotionEntry` stores the flags word measured before the demotion.
public struct ProcSnapshot: Equatable, Sendable {

    /// `PROC_FLAG_EXT_DARWINBG` and `PROC_FLAG_DARWINBG` from XNU
    /// `bsd/sys/proc_info.h`. The public SDK header stops at `PROC_FLAG_EXEC`
    /// (`0x4000`), so both are spelled out here.
    ///
    /// Nothing in this package rests on the names being right. Every check reads
    /// the word BEFORE and AFTER the call it makes, so what is asserted is the
    /// transition, which is observed rather than assumed.
    public static let externalDarwinBackground: UInt32 = 0x1_0000
    public static let selfDarwinBackground: UInt32 = 0x8000

    public let pid: pid_t
    public let uid: uid_t
    public let ppid: pid_t
    public let pgid: pid_t
    /// The longest name the kernel would give for this process.
    ///
    /// Up to `SystemProcessInspector.nameLimit` characters for a process this
    /// user owns, and only `SystemProcessInspector.shortNameLimit` for anybody
    /// else's — the long record is privileged. Every name in
    /// `DemotionPolicy.alwaysProtectedNames` fits the short bound for that
    /// reason, and `everyAlwaysProtectedNameFitsTheShortField` holds it.
    public let name: String
    public let flags: UInt32

    /// Someone else put this process into darwin background state.
    public var isExternallyBackgrounded: Bool {
        flags & Self.externalDarwinBackground != 0
    }

    /// The process put ITSELF into darwin background state. A different channel,
    /// which this app never drives and must never undo.
    public var isSelfBackgrounded: Bool {
        flags & Self.selfDarwinBackground != 0
    }

    public init(pid: pid_t, uid: uid_t, ppid: pid_t, pgid: pid_t,
                name: String, flags: UInt32) {
        self.pid = pid
        self.uid = uid
        self.ppid = ppid
        self.pgid = pgid
        self.name = name
        self.flags = flags
    }
}

/// Which process a pid was, at the moment it was read.
///
/// **A pid is not an identity.** macOS reuses pids, so a journal that names only
/// a pid tells a later run to clear a background bit on whatever process happens
/// to hold that number when it reads. The start time settles it: two processes
/// cannot occupy the same pid at the same microsecond, and a pid can only be
/// reused after the kernel has wrapped through the whole pid space. Measured on
/// macOS 26.5.2 (25F84): `pbi_start_tvsec`/`pbi_start_tvusec` are stable across
/// reads of one process and differ between two processes started in the same
/// second.
///
/// `Codable`, because it is the part of a snapshot that goes into the journal.
public struct ProcIdentity: Codable, Equatable, Sendable {
    public let pid: pid_t
    public let startedAtSeconds: UInt64
    public let startedAtMicroseconds: UInt64

    public init(pid: pid_t, startedAtSeconds: UInt64, startedAtMicroseconds: UInt64) {
        self.pid = pid
        self.startedAtSeconds = startedAtSeconds
        self.startedAtMicroseconds = startedAtMicroseconds
    }
}

/// Reads one process's state.
///
/// A protocol so the policy and the governor can be checked against processes
/// that are awkward to create — `pid` 1, a foreign uid — without this suite
/// needing the privilege to make one.
/// **Two readings, because one flavour of `proc_pidinfo` is privileged and the
/// other is not.** Measured on macOS 26.5.2 (25F84) as an ordinary user:
///
/// | pid | uid | `PROC_PIDT_SHORTBSDINFO` | `PROC_PIDTBSDINFO` |
/// |---|---|---|---|
/// | 1 `launchd` | 0 | succeeds | `EPERM` |
/// | `WindowServer` | 88 | succeeds | `EPERM` |
/// | own child | 502 | succeeds | succeeds |
///
/// The deny rules must decide about processes this user does NOT own — that is
/// most of what a protected set is for — so they read the short flavour, which
/// answers for every process on the machine. Only the start time needs the long
/// one, and only a process this app is about to demote needs a start time.
public protocol ProcessInspecting: Sendable {
    /// Everything the deny rules need. Answers for any process on the machine.
    ///
    /// `nil` means there is no such process, and never a zero-filled snapshot:
    /// a failed read reported as `flags: 0` would make the governor journal a
    /// prior state it never saw, and a later run would then clear a bit on
    /// whatever holds that pid.
    func snapshot(of pid: pid_t) -> ProcSnapshot?

    /// WHICH process this is, so a later run can tell pid reuse apart.
    ///
    /// `nil` when the kernel refuses the privileged record, which it does for
    /// another user's process. That is not a problem in practice and it is not
    /// papered over: a process this app may demote is always its own, and
    /// `ProcGovernor.demote(_:)` refuses outright rather than journalling an
    /// entry it could not identify.
    func identity(of pid: pid_t) -> ProcIdentity?
}

/// The real inspector, over `proc_pidinfo`.
public struct SystemProcessInspector: ProcessInspecting {

    /// The longest process name the kernel keeps for a process this user owns.
    ///
    /// `proc_bsdinfo.pbi_name` is `char[2 * MAXCOMLEN]` — 32 bytes, one of them
    /// the terminator. A demotable entry longer than this can never match any
    /// process, so the settings documentation states the bound.
    public static let nameLimit = 31

    /// The longest name available for ANY process, including another user's.
    ///
    /// `proc_bsdshortinfo.pbsi_comm` is `char[MAXCOMLEN]` — 16 bytes with a
    /// terminator. Every name in `DemotionPolicy.alwaysProtectedNames` fits
    /// inside it, because a protected name that did not would silently fail to
    /// match the foreign-uid processes it exists to protect.
    public static let shortNameLimit = 15

    public init() {}

    public func snapshot(of pid: pid_t) -> ProcSnapshot? {
        // The SHORT flavour decides everything here, because it is the only one
        // that answers for a process this user does not own — and refusing to
        // demote another user's `WindowServer` is exactly what the protected set
        // is for. The two flavours report the same `flags` word, and
        // `bothProcInfoFlavoursReportTheSameFlagsWord` measures that on every
        // run rather than assuming it.
        var short = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size else {
            return nil
        }
        let comm = Self.text(from: short.pbsi_comm)

        // Upgrade the name when the kernel allows it. `pbi_name` holds 31
        // characters where `pbsi_comm` holds 15, and a demotable entry the user
        // typed in full would never match the short one. This read fails for
        // another user's process, which keeps the short name — acceptable
        // because the only thing a foreign name is used for is the protected
        // list, and every entry in it fits.
        let full = Self.longRecord(of: pid).map { Self.text(from: $0.pbi_name) } ?? ""

        return ProcSnapshot(
            pid: pid_t(bitPattern: short.pbsi_pid),
            uid: short.pbsi_uid,
            ppid: pid_t(bitPattern: short.pbsi_ppid),
            pgid: pid_t(bitPattern: short.pbsi_pgid),
            name: full.isEmpty ? comm : full,
            flags: short.pbsi_flags)
    }

    public func identity(of pid: pid_t) -> ProcIdentity? {
        guard let info = Self.longRecord(of: pid) else { return nil }
        return ProcIdentity(pid: pid_t(bitPattern: info.pbi_pid),
                            startedAtSeconds: info.pbi_start_tvsec,
                            startedAtMicroseconds: info.pbi_start_tvusec)
    }

    /// The privileged record. `nil` when the kernel refuses it, which it does
    /// with `EPERM` for a process belonging to another user.
    private static func longRecord(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return info
    }

    /// Reads a fixed-size C character array, which Swift imports as a tuple.
    ///
    /// Bounded by the tuple's own size rather than by a terminator search past
    /// its end: the kernel is free to fill every byte, and a name that fills the
    /// field carries no terminator at all.
    private static func text(from field: some Any) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
