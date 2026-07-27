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
        // PreventUserIdleDisplaySleep — under our name or any other — would
        // destroy that.
        let types = liveAssertions(named: AssertionHolder.assertionName)
            .compactMap { $0["AssertType"] as? String }
        #expect(types == ["PreventUserIdleSystemSleep"])
        #expect(types.contains("PreventUserIdleDisplaySleep") == false)
    }
}
