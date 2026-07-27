// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Darwin
import CoffeeBarCore

/// S3 — are `proc_pid_rusage` energy fields populated, and for whom?
///
/// Handoff §3 lists `ri_billed_energy` as the same source Activity Monitor's
/// Energy Impact derives from. The open question is whether it is readable
/// for processes this app does not own, without an extra entitlement.
///
/// `RUSAGE_INFO_V4` is pinned deliberately. `RUSAGE_INFO_CURRENT` is `V6` on
/// this SDK (`sys/resource.h:193`), and a probe that followed `CURRENT` would
/// change which struct layout it measured on the next SDK bump — an answer
/// that moves with the toolchain answers nothing. V4 is the earliest flavour
/// carrying `ri_billed_energy` (`sys/resource.h:322`).
///
/// The `rusageFlavor` and `rusageStructBytes` evidence is derived from the
/// constant and the struct this probe actually uses, never written out as a
/// fixed string: evidence that restates an intention rather than a measurement
/// would report "V4" from a run that had been quietly upgraded to V6.
public struct EnergyProbe {
    public init() {}

    public func run(targetPID: pid_t?) -> SpikeResult {
        guard let pid = targetPID else {
            return SpikeResult(
                id: .s3EnergyFields, verdict: .notApplicable,
                detail: "no target process supplied", durationMS: 0,
                evidence: [:])
        }
        let start = Date()
        let flavor = RUSAGE_INFO_V4
        var info = rusage_info_v4()
        // Read off the struct that is about to be handed to the kernel, so the
        // evidence below describes the buffer that was really measured. 296
        // bytes for v4, 464 for v6 on the current SDK.
        let structBytes = MemoryLayout.size(ofValue: info)
        errno = 0
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, flavor, $0)
            }
        }
        // Captured before anything else can run: `Date()` below is a syscall in
        // its own right and is free to overwrite errno first. Reading `errno`
        // lazily inside the failure branch would report whichever call happened
        // to touch it last.
        let callErrno = errno
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        guard rc == 0 else {
            // No `ri_billed_energy` key here, and that omission is load-bearing:
            // `info` is whatever it was before a call that wrote nothing, so
            // publishing a reading from it would fabricate a measurement. The
            // errno is the actual answer S3 wants on this path — EPERM means
            // "not ours, an entitlement is missing", ESRCH means "no such
            // process", and those point at different conclusions.
            return SpikeResult(
                id: .s3EnergyFields, verdict: .fail,
                detail: "proc_pid_rusage failed (errno \(callErrno)) for pid \(pid)",
                durationMS: ms,
                evidence: ["rusageFlavor": "V\(flavor)",
                           "rusageStructBytes": String(structBytes),
                           "returnCode": String(rc),
                           "errno": String(callErrno), "pid": String(pid)])
        }

        let billed = info.ri_billed_energy
        let populated = billed > 0
        return SpikeResult(
            id: .s3EnergyFields,
            verdict: populated ? .pass : .fail,
            detail: populated
                ? "ri_billed_energy populated for pid \(pid)"
                : "proc_pid_rusage succeeded but ri_billed_energy is zero",
            durationMS: ms,
            evidence: ["rusageFlavor": "V\(flavor)",
                       "rusageStructBytes": String(structBytes),
                       "returnCode": String(rc),
                       "ri_billed_energy": String(billed),
                       "ri_interrupt_wkups": String(info.ri_interrupt_wkups),
                       "pid": String(pid)])
    }
}
