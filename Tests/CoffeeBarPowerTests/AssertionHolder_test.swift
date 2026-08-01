// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit.pwr_mgt
import Testing

@testable import CoffeeBarPower

/// Assertions live in process-global IOKit state, so two of these tests running
/// concurrently would see each other's assertions and the live-count checks
/// would be meaningless. Serialize the suite.
@Suite(.serialized)
struct AssertionHolderTests {

    // MARK: - Live IOKit inspection
    //
    // Every count below is read back out of IOKit rather than off the holder's
    // own bookkeeping. A holder that only flipped a Bool would satisfy `isHeld`
    // and still fail every one of these.

    /// Power-management assertions currently owned by *this* process, filtered
    /// to a given assertion name.
    ///
    /// Key strings are the documented literals (`kIOPMAssertionNameKey` ==
    /// `"AssertName"`), spelled out so the test does not depend on the same
    /// constants the implementation uses.
    private func liveAssertions(named name: String) -> [[String: Any]] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
            let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return []
        }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (byProcess[pid] ?? []).filter { $0["AssertName"] as? String == name }
    }

    /// Every assertion TYPE this process owns, whatever each assertion is
    /// CALLED.
    ///
    /// `liveAssertions(named:)` filters by `AssertName`, and that filter is
    /// finding B6. An assertion raised under any other name is invisible to it,
    /// so six lines inside `acquire()` could pin the display awake with this
    /// whole suite green. The type is what IOKit acts on; the name is only what
    /// `pmset -g assertions` prints, and nothing stops a second assertion from
    /// choosing a different one.
    private func liveAssertionTypes() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
            let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return []
        }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (byProcess[pid] ?? []).compactMap { $0["AssertType"] as? String }
    }

    // MARK: - Naming

    @Test func assertionNameIdentifiesCoffeeBarToPmset() {
        // `pmset -g assertions` prints this string verbatim. If it stops
        // naming the product, the user cannot tell which process is holding
        // their machine awake.
        #expect(AssertionHolder.assertionName.contains("coffee-bar"))
    }

    // MARK: - Acquire / release

    @Test func acquireRegistersALiveSystemSleepAssertion() {
        let holder = AssertionHolder()
        defer { holder.release() }

        #expect(holder.isHeld == false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)

        #expect(holder.acquire() == true)

        #expect(holder.isHeld == true)
        let live = liveAssertions(named: AssertionHolder.assertionName)
        #expect(live.count == 1)
        #expect(live.first?["AssertType"] as? String == "PreventUserIdleSystemSleep")
    }

    @Test func releaseRetiresTheLiveAssertion() {
        let holder = AssertionHolder()
        holder.acquire()
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)

        holder.release()

        #expect(holder.isHeld == false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)
    }

    // MARK: - Idempotence

    @Test func acquireTwiceThenReleaseOnceLeaksNothing() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire()
        holder.acquire()

        // A holder that created a fresh assertion on every `acquire()` and
        // overwrote its stored id would show 2 live assertions here, and would
        // strand one of them after the single release below.
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)

        holder.release()

        #expect(holder.isHeld == false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)
    }

    @Test func releaseWithNothingHeldIsANoOp() {
        let holder = AssertionHolder()

        holder.release()
        holder.release()

        #expect(holder.isHeld == false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)
    }

    @Test func acquireAfterReleaseWorksAgain() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire()
        holder.release()
        #expect(holder.acquire() == true)

        #expect(holder.isHeld == true)
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)
    }

    // MARK: - Teardown

    @Test func deinitReleasesAStillHeldAssertion() {
        var holder: AssertionHolder? = AssertionHolder()
        holder?.acquire()
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)

        holder = nil

        // Dropping the last reference must not strand an assertion holding the
        // machine awake for the rest of the process's life.
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)
    }

    // MARK: - §6.1 differentiator

    @Test func holderNeverPreventsDisplaySleep() {
        let holder = AssertionHolder()
        defer { holder.release() }
        holder.acquire()

        // The product's whole point versus `caffeinate -d` / KeepingYouAwake is
        // that the screen is still allowed to sleep. Holding
        // PreventUserIdleDisplaySleep would destroy that.
        //
        // SCOPE, corrected: this reads only assertions carrying OUR name, so it
        // proves the named assertion is the system-sleep one. It does NOT see an
        // assertion raised under a different name — that is finding B6, and
        // `noDisplayAssertionIsHeldUnderAnyNameWhileServing` below is what
        // covers it.
        let types = liveAssertions(named: AssertionHolder.assertionName)
            .compactMap { $0["AssertType"] as? String }
        #expect(types == ["PreventUserIdleSystemSleep"])
        #expect(types.contains("PreventUserIdleDisplaySleep") == false)
    }

    @Test func noDisplayAssertionIsHeldUnderAnyNameWhileServing() {
        // Finding B6, the behavioural half, and the audit's exact escape: six
        // lines inside `acquire()` raising
        // `kIOPMAssertionTypePreventUserIdleDisplaySleep` under any name other
        // than `AssertionHolder.assertionName`. Every other check in this file
        // filters by name and stays green while the display is pinned awake.
        //
        // So this asserts on the TYPES the PROCESS owns and never mentions a
        // name. Reading the process rather than the holder also catches a
        // display assertion raised anywhere else in CoffeeBarPower during
        // `acquire()`, which no name filter could reach.
        let holder = AssertionHolder()
        defer { holder.release() }

        #expect(holder.acquire() == true)

        let types = liveAssertionTypes()

        // Proves the read WORKED. `IOPMCopyAssertionsByProcess` failing returns
        // an empty list, which would make the check below vacuously true — the
        // exact theater this test exists to remove. Serving means this process
        // owns a system-sleep assertion, so its absence is a broken read.
        #expect(types.contains("PreventUserIdleSystemSleep"), """
            the process owns no PreventUserIdleSystemSleep assertion while \
            serving, so this read found nothing and proves nothing: \(types)
            """)

        // Both documented display-holding types. `kIOPMAssertionTypeNoDisplay\
        // Sleep` is the legacy spelling and its value is "NoDisplaySleepAssertion".
        for displayType in ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"] {
            #expect(types.contains(displayType) == false, """
                this process holds a \(displayType) assertion while serving. \
                Letting the display sleep while the machine stays awake is the \
                product's whole difference from caffeinate -d (design §6.1). \
                Live types: \(types)
                """)
        }
    }
}
