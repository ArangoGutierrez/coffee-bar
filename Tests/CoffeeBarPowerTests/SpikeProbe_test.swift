// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Testing
import Foundation
@testable import CoffeeBarPower
@testable import CoffeeBarCore

/// Live read of a process's Darwin background state: 1 while backgrounded, 0
/// when not, `nil` when the call itself failed.
///
/// `getpriority` can legitimately return -1, so errno is cleared first and
/// consulted after — the discrimination getpriority(2) explicitly requires.
///
/// Spelled with `PRIO_DARWIN_PROCESS` / `id_t` straight from `sys/resource.h`
/// rather than through anything `DemotionProbe` exports, so this reading cannot
/// agree with a wrong implementation by sharing its constants.
///
/// Only meaningful for a process we *are*. Verified on macOS 26.5.2 (25F84):
/// `getpriority(PRIO_DARWIN_PROCESS, <other pid>)` reads 0 even for a process
/// Apple's own `/usr/sbin/taskpolicy -b -p` has just backgrounded, so it cannot
/// confirm or refute a third party's state.
private func darwinBackgroundState(of pid: pid_t) -> Int32? {
    errno = 0
    let value = getpriority(PRIO_DARWIN_PROCESS, id_t(bitPattern: pid))
    if value == -1 && errno != 0 { return nil }
    return value
}

@Test func energyProbeSyscallSucceedsOnOwnProcess() {
    // The syscall must succeed for a process we own — that is a real
    // invariant and this test goes red if it regresses. Whether
    // ri_billed_energy is POPULATED is the open question S3 exists to
    // answer, so it is recorded as evidence and deliberately NOT asserted:
    // pinning the verdict here would presuppose the spike's result.
    let r = EnergyProbe().run(targetPID: getpid())
    #expect(r.id == .s3EnergyFields)
    #expect(r.evidence["returnCode"] == "0")
    #expect(r.evidence["ri_billed_energy"] != nil)
    #expect(r.evidence["rusageFlavor"] == "V4")
}

@Test func energyProbeWithNoTargetIsNotApplicableNotAFailure() {
    let r = EnergyProbe().run(targetPID: nil)
    #expect(r.verdict == .notApplicable)
}

@Test func energyProbeReportsTheSyscallFailureAndPublishesNoReading() {
    // The success path above cannot catch a probe that ignores
    // `proc_pid_rusage`'s return code: on a live pid the call succeeds, so
    // dropping the check changes nothing observable there. This exercises the
    // other side. pid -1 is not a process, so the call fails with ESRCH —
    // verified on macOS 26.5.2 (25F84).
    //
    // The load-bearing assertion is the LAST one. A probe that skips the
    // return-code check falls through to the success path and publishes
    // `ri_billed_energy: "0"` read out of a struct the kernel never wrote —
    // a fabricated measurement, and far worse than a reported failure. The
    // failure path must carry the errno instead, because EPERM ("not ours,
    // need an entitlement") and ESRCH ("gone") are different answers to S3.
    let r = EnergyProbe().run(targetPID: -1)
    #expect(r.id == .s3EnergyFields)
    #expect(r.verdict == .fail)
    #expect(r.evidence["returnCode"] == "-1")
    #expect(r.evidence["errno"] == String(ESRCH))
    #expect(r.evidence["ri_billed_energy"] == nil)
}

@Test func demotionProbeWithNoTargetIsNotApplicable() {
    let r = DemotionProbe().run(targetPID: nil)
    #expect(r.verdict == .notApplicable)
}

/// Serialized because both tests move *this whole process* in and out of
/// Darwin background state, and the second one reads that state back. Run in
/// parallel they would interleave one's restore into the other's observation
/// window. Same reason `AssertionHolder_test.swift` is serialized.
@Suite(.serialized)
struct DemotionProbeStateTests {

    @Test func demotionProbeOnOwnProcessRoundTrips() {
        // Demoting ourselves and restoring must leave no lasting change.
        let r = DemotionProbe().run(targetPID: getpid())
        #expect(r.id == .s5DemotionPrivilege)
        #expect(r.evidence["demoteReturn"] != nil)
        #expect(r.evidence["restoreReturn"] != nil)
        // Guarantee the probe cleaned up after itself.
        #expect(r.evidence["finalStateRestored"] == "true")
    }

    @Test func demotionProbeEntersAndLeavesBackgroundStateObservably() {
        // The evidence dictionary above is self-reported: a probe that makes
        // neither syscall and writes the numbers it wishes were true produces
        // a byte-identical `SpikeResult`. So the state is read out of the
        // kernel instead, on both sides of the restore.
        //
        // This is the test that pins the two things S5 actually claims — that
        // the demote takes effect, and that the process is not left throttled.
        // Note what it does NOT claim: nothing here promotes anything. Handoff
        // §2.1, `PRIO_DARWIN_BG` is a brake with no counterpart.
        #expect(darwinBackgroundState(of: getpid()) == 0,
                "already in background state before the run; readings below would be stale")

        var whileDemoted: Int32?
        let r = DemotionProbe().run(targetPID: getpid(), whileDemoted: { pid in
            whileDemoted = darwinBackgroundState(of: pid)
        })

        // Deliberately NOT `if let whileDemoted { ... }` — that form is
        // vacuously green for a `run` that never enters the seam at all.
        #expect(whileDemoted == 1,
                "setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG) did not take effect")
        #expect(darwinBackgroundState(of: getpid()) == 0,
                "probe returned with this process still demoted: it left the machine throttled")
        #expect(r.verdict == .pass)
        #expect(r.evidence["backgroundAfter"] == "0")
    }
}
