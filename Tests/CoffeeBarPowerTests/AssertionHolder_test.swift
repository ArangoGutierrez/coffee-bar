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

    /// How many assertions of one TYPE this process owns.
    ///
    /// By type and not by name, for the reason `liveAssertionTypes` exists: the
    /// type is what IOKit acts on, and a leak that chose a different name would
    /// be invisible to a name filter. Nothing else in this package raises a
    /// display assertion, so a count above 1 is this holder's own leak.
    private func liveCount(ofType type: String) -> Int {
        liveAssertionTypes().filter { $0 == type }.count
    }

    /// Every assertion this process owns of one TYPE, with its properties.
    ///
    /// `liveAssertions(named:)` filters by name and so cannot answer "what is
    /// this assertion CALLED", which is the question the network checks below
    /// ask: they read the name back off the assertion IOKit actually recorded
    /// rather than off a constant the implementation also uses.
    private func liveAssertions(ofType type: String) -> [[String: Any]] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
            let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else {
            return []
        }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (byProcess[pid] ?? []).filter { $0["AssertType"] as? String == type }
    }

    /// The type string `pmset -g assertions` prints for the display hold.
    ///
    /// The documented literal, spelled out rather than taken from
    /// `kIOPMAssertionTypePreventUserIdleDisplaySleep`, so this check does not
    /// depend on the same constant the implementation uses. A holder that
    /// raised the wrong type under the right constant would satisfy a check
    /// written against that constant.
    private let displayType = "PreventUserIdleDisplaySleep"

    /// The type string `pmset -g assertions` prints for the network hold.
    ///
    /// Spelled out for the same reason `displayType` is, and here the reason is
    /// sharper. Apple's header is INCONSISTENT: the sleep assertions are
    /// `kIOPMAssertionTypePreventUserIdleSystemSleep`, but this one is
    /// `kIOPMAssertNetworkClientActive` — `Assert`, no `ionType`. A check
    /// written against the constant would therefore be a check against whichever
    /// spelling the implementation happened to compile, which is precisely the
    /// thing in doubt. `"NetworkClientActive"` is the value IOKit records and
    /// `pmset` prints, and it is what this file asserts on.
    private let networkType = "NetworkClientActive"

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

        #expect(holder.acquire(displaySleep: false) == true)

        #expect(holder.isHeld == true)
        let live = liveAssertions(named: AssertionHolder.assertionName)
        #expect(live.count == 1)
        #expect(live.first?["AssertType"] as? String == "PreventUserIdleSystemSleep")
    }

    @Test func releaseRetiresTheLiveAssertion() {
        let holder = AssertionHolder()
        holder.acquire(displaySleep: false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)

        holder.release()

        #expect(holder.isHeld == false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)
    }

    // MARK: - Idempotence

    @Test func acquireTwiceThenReleaseOnceLeaksNothing() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire(displaySleep: false)
        holder.acquire(displaySleep: false)

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

        holder.acquire(displaySleep: false)
        holder.release()
        #expect(holder.acquire(displaySleep: false) == true)

        #expect(holder.isHeld == true)
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)
    }

    // MARK: - Teardown

    @Test func deinitReleasesAStillHeldAssertion() {
        var holder: AssertionHolder? = AssertionHolder()
        holder?.acquire(displaySleep: false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)

        holder = nil

        // Dropping the last reference must not strand an assertion holding the
        // machine awake for the rest of the process's life.
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)
    }

    // MARK: - §6.1 differentiator, as issue #12 settled it
    //
    // The differentiator is now a DEFAULT rather than a promise. So the two
    // checks below stopped saying "never" and started saying "while the hold is
    // off" — which is the shipped default and the state every user starts in.
    // The opt-in half is checked separately, further down, and neither half is
    // enough alone: without the "off" checks the product loses its difference,
    // and without the "on" checks the setting can be a control that does
    // nothing.

    @Test func theHolderPreventsNoDisplaySleepWhileTheHoldIsOff() {
        let holder = AssertionHolder()
        defer { holder.release() }
        holder.acquire(displaySleep: false)

        // The product's difference from `caffeinate -d` / KeepingYouAwake is
        // that the screen is still allowed to sleep unless the user asks
        // otherwise. Holding PreventUserIdleDisplaySleep here would delete the
        // default and make the setting a lie.
        //
        // SCOPE, corrected: this reads only assertions carrying OUR system
        // name, so it proves the named assertion is the system-sleep one. It
        // does NOT see an assertion raised under a different name — that is
        // finding B6, and `noDisplayAssertionIsHeldUnderAnyNameWhileTheHoldIsOff`
        // below is what covers it.
        let types = liveAssertions(named: AssertionHolder.assertionName)
            .compactMap { $0["AssertType"] as? String }
        #expect(types == ["PreventUserIdleSystemSleep"])
        #expect(types.contains(displayType) == false)
    }

    @Test func noDisplayAssertionIsHeldUnderAnyNameWhileTheHoldIsOff() {
        // Finding B6, the behavioural half, and the audit's exact escape: six
        // lines inside `acquire()` raising
        // `kIOPMAssertionTypePreventUserIdleDisplaySleep` under any name other
        // than `AssertionHolder.assertionName`. Every other check in this file
        // filters by name and stays green while the display is pinned awake.
        //
        // The escape it closes is UNCHANGED by issue #12, and this is the check
        // that keeps the opt-in honest: the holder may now raise that type, so
        // the only thing standing between a setting and a permanent display
        // hold is that this reads the PROCESS with the setting OFF.
        //
        // So this asserts on the TYPES the PROCESS owns and never mentions a
        // name. Reading the process rather than the holder also catches a
        // display assertion raised anywhere else in CoffeeBarPower during
        // `acquire()`, which no name filter could reach.
        let holder = AssertionHolder()
        defer { holder.release() }

        #expect(holder.acquire(displaySleep: false) == true)

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
        for held in [displayType, "NoDisplaySleepAssertion"] {
            #expect(types.contains(held) == false, """
                this process holds a \(held) assertion while serving with the \
                display hold OFF. Letting the display sleep unless the user asks \
                otherwise is the product's difference from caffeinate -d \
                (design §6.1). Live types: \(types)
                """)
        }
    }

    // MARK: - The opt-in (issue #12)

    @Test func theDisplayAssertionNamesCoffeeBarToPmset() {
        // Same reason as `assertionNameIdentifiesCoffeeBarToPmset`: a user
        // asking "what is keeping my screen on?" reads `pmset -g assertions`,
        // and a hold this product raised has to say so.
        //
        // A DIFFERENT string from the system assertion's, so the two lines
        // `pmset` prints are not the same sentence twice. That difference is
        // asserted, not assumed: one name for both would let a check on either
        // pass while only one assertion existed.
        #expect(AssertionHolder.displayAssertionName.contains("coffee-bar"))
        #expect(AssertionHolder.displayAssertionName != AssertionHolder.assertionName)
    }

    @Test func theHoldOnRaisesTheDisplayAssertionBesideTheSystemOne() {
        let holder = AssertionHolder()
        defer { holder.release() }

        #expect(liveCount(ofType: displayType) == 0)

        #expect(holder.acquire(displaySleep: true) == true)

        let types = liveAssertionTypes()

        // BOTH, and the system one is not optional. Named bug this catches: a
        // holder that swaps one assertion for the other, so opting in to the
        // screen quietly stops holding the MACHINE — and the machine sleeping
        // under a working agent is the defect this whole product exists to
        // prevent.
        #expect(types.contains("PreventUserIdleSystemSleep"), "live types: \(types)")
        #expect(types.contains(displayType), "live types: \(types)")
    }

    @Test func turningTheHoldOffReleasesTheDisplayAssertionAndKeepsTheSystemOne() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire(displaySleep: true)
        #expect(liveCount(ofType: displayType) == 1)

        // The panel writes the setting and `refresh()` calls `acquire` again —
        // it never calls `release()` for a setting change, because the machine
        // is still being held. So the DOWNGRADE has to happen inside `acquire`.
        //
        // Named bug this catches: an `acquire` that only ever adds. The user
        // unticks the box, the panel says the screen may sleep, and the display
        // assertion stays up until they quit the app.
        holder.acquire(displaySleep: false)

        #expect(liveCount(ofType: displayType) == 0,
                "the display assertion survived the setting going off")
        #expect(liveAssertionTypes().contains("PreventUserIdleSystemSleep"),
                "turning the display hold off dropped the system hold too")
    }

    @Test func turningTheHoldOnWhileAlreadyServingRaisesItWithoutReacquiring() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire(displaySleep: false)
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)

        // The UPGRADE path, and it is the one a real user takes: they are
        // already serving when they tick the box. Named bug this catches: the
        // early `if assertionID != nil { return true }` return surviving, which
        // makes the setting do nothing at all for anybody who is already
        // holding — that is, for everybody who can see the panel.
        holder.acquire(displaySleep: true)

        #expect(liveCount(ofType: displayType) == 1)
        // And the system assertion was not created a second time.
        #expect(liveAssertions(named: AssertionHolder.assertionName).count == 1)
    }

    @Test func acquiringTwiceWithTheHoldOnLeaksNoSecondDisplayAssertion() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire(displaySleep: true)
        holder.acquire(displaySleep: true)

        // `refresh()` runs every 30 seconds and on every hook event, so this is
        // the ordinary path and not an edge case. A holder that created a fresh
        // display assertion each time and overwrote its stored id would show 2
        // here and strand one after the single release below.
        #expect(liveCount(ofType: displayType) == 1)

        holder.release()
        #expect(liveCount(ofType: displayType) == 0)
    }

    @Test func releaseRetiresTheDisplayAssertionToo() {
        let holder = AssertionHolder()

        holder.acquire(displaySleep: true)
        #expect(liveCount(ofType: displayType) == 1)

        holder.release()

        #expect(holder.isHeld == false)
        #expect(liveCount(ofType: displayType) == 0)
        #expect(liveAssertions(named: AssertionHolder.assertionName).isEmpty)
    }

    @Test func deinitReleasesAStillHeldDisplayAssertion() {
        var holder: AssertionHolder? = AssertionHolder()
        holder?.acquire(displaySleep: true)
        #expect(liveCount(ofType: displayType) == 1)

        holder = nil

        // A stranded display assertion outlives the object and keeps the SCREEN
        // lit until the process exits, with nothing left to release it. That is
        // strictly worse than the stranded system assertion this mirrors: it
        // burns the battery visibly and the panel reports nothing held.
        #expect(liveCount(ofType: displayType) == 0)
    }

    // MARK: - The network assertion (issue #60)
    //
    // `PreventUserIdleSystemSleep` keeps the CPU running; it does not keep the
    // machine answering. A Mac holding only that assertion can still drop its
    // network clients, and an agent reached over SSH or a forwarded port is then
    // being served by a machine that is awake and unreachable — awake for
    // nobody. `NetworkClientActive` is the documented assertion for "this
    // machine is serving remote clients", and coffee-bar's whole claim is that
    // it is serving.
    //
    // What these checks CAN prove is the lifecycle: that the holder takes the
    // assertion, takes exactly one, keeps it for as long as the machine is held
    // whatever the display setting says, and strands none. What no unit test can
    // prove is the ROUTE — that a packet actually arrives. Apple documents this
    // assertion as a suggestion the system may decline under battery or thermal
    // pressure, so the runtime half is proved separately with `pmset -g
    // assertions` against the built app, and the lid-shut-on-battery round trip
    // needs a second host and is not proved here at all.

    @Test func acquireRaisesTheNetworkAssertionBesideTheSystemOne() {
        let holder = AssertionHolder()
        defer { holder.release() }

        #expect(liveCount(ofType: networkType) == 0)

        #expect(holder.acquire(displaySleep: false) == true)

        let types = liveAssertionTypes()

        // BOTH, and the system one is not optional. Named bug this catches: a
        // holder that raises the network assertion INSTEAD of the sleep one,
        // which would leave the machine reachable right up until it idles out
        // from under the agent — the defect this product exists to prevent,
        // reintroduced by the fix for a different one.
        #expect(types.contains("PreventUserIdleSystemSleep"), "live types: \(types)")
        #expect(types.contains(networkType), "live types: \(types)")
    }

    @Test func theNetworkAssertionNamesCoffeeBarToPmset() {
        let holder = AssertionHolder()
        defer { holder.release() }
        holder.acquire(displaySleep: false)

        // Read off the assertion IOKit RECORDED, not off a static on the type.
        // A constant can hold any string; what a user reads in `pmset -g
        // assertions` is what was actually passed, and those are only the same
        // thing if the implementation passes the constant it publishes.
        let names = liveAssertions(ofType: networkType)
            .compactMap { $0["AssertName"] as? String }

        #expect(names.count == 1, "live network assertions: \(names)")

        // SECURITY.md tells a reader the names are deliberately distinct so a
        // stranded assertion can be attributed to the code that stranded it.
        // Named bug this catches: the network assertion raised under
        // `assertionName`, which prints two identical `pmset` lines and leaves a
        // user unable to tell which of the two leaked.
        #expect(names.first?.contains("coffee-bar") == true, "live names: \(names)")
        #expect(names.first != AssertionHolder.assertionName, "live names: \(names)")
        #expect(names.first != AssertionHolder.displayAssertionName, "live names: \(names)")
    }

    @Test func theNetworkAssertionIsHeldWhicheverWayTheDisplaySettingIsSet() {
        let holder = AssertionHolder()
        defer { holder.release() }

        // The network hold answers to the MACHINE being held, not to the screen.
        // Named bug this catches — and it is the likely one, because the display
        // assertion is the nearest model to copy: the network assertion wired
        // into the `if displaySleep` branch of `acquire`. Every check that only
        // ever acquires with the hold ON stays green, and the user who leaves the
        // display setting off, which is the SHIPPED DEFAULT and so is most users,
        // silently gets no network assertion at all.
        holder.acquire(displaySleep: false)
        #expect(liveCount(ofType: networkType) == 1, "display OFF dropped the network hold")

        holder.acquire(displaySleep: true)
        #expect(liveCount(ofType: networkType) == 1, "display ON changed the network hold")

        // And back down. `ServingModel.refresh()` calls `acquire` on every tick,
        // so this is the ordinary path a user walks by unticking the box.
        holder.acquire(displaySleep: false)
        #expect(liveCount(ofType: networkType) == 1, "the display downgrade took the network hold with it")
    }

    @Test func acquiringTwiceLeaksNoSecondNetworkAssertion() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire(displaySleep: false)
        holder.acquire(displaySleep: false)

        // `refresh()` runs every 30 seconds and on every hook event, so a holder
        // that created a fresh assertion each time and overwrote its stored id
        // would show 2 here and strand one after the single release below —
        // once per tick, for the life of the process.
        #expect(liveCount(ofType: networkType) == 1)

        holder.release()
        #expect(liveCount(ofType: networkType) == 0)
    }

    @Test func releaseRetiresTheNetworkAssertionToo() {
        let holder = AssertionHolder()

        holder.acquire(displaySleep: false)
        #expect(liveCount(ofType: networkType) == 1)

        holder.release()

        // Named bug this catches: a `release()` that retires the two sleep
        // assertions and forgets the third. The panel then reports nothing held
        // while this process still tells the system it is serving remote
        // clients, and nothing but quitting the app will retire it.
        #expect(holder.isHeld == false)
        #expect(liveCount(ofType: networkType) == 0)
    }

    @Test func acquireAfterReleaseRaisesTheNetworkAssertionAgain() {
        let holder = AssertionHolder()
        defer { holder.release() }

        holder.acquire(displaySleep: false)
        holder.release()

        // Named bug this catches: an id cleared on release but a `nil` check
        // that no longer reaches the create, so the SECOND serving stretch of a
        // session runs without the network hold. Under `Auto` a machine acquires
        // and releases many times a day, so all but the first would be silent.
        #expect(holder.acquire(displaySleep: false) == true)
        #expect(liveCount(ofType: networkType) == 1)
    }

    @Test func deinitReleasesAStillHeldNetworkAssertion() {
        var holder: AssertionHolder? = AssertionHolder()
        holder?.acquire(displaySleep: false)
        #expect(liveCount(ofType: networkType) == 1)

        holder = nil

        // A stranded network assertion outlives the object and keeps telling the
        // system this process is serving remote clients until the process exits,
        // with nothing left to release it — invisible to the user, because the
        // panel reports nothing held.
        #expect(liveCount(ofType: networkType) == 0)
    }
}
