// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit.pwr_mgt

/// Holds a `PreventUserIdleSystemSleep` power assertion for as long as
/// coffee-bar is serving, a `NetworkClientActive` beside it for exactly as
/// long, and a `PreventUserIdleDisplaySleep` as well while the user has opted
/// in.
///
/// ## Why the network assertion is not a setting
///
/// `PreventUserIdleSystemSleep` keeps the CPU running; it does not keep the
/// machine answering. A Mac holding only that assertion may still drop its
/// network clients, and an agent reached over SSH or a forwarded port is then
/// being served by a machine that is awake and unreachable — awake for nobody
/// (issue #60). `NetworkClientActive` is the documented assertion for "this
/// machine is serving remote clients", and serving is precisely what this type
/// is asserting.
///
/// So it takes no opt-in: it costs the user nothing visible, unlike the screen,
/// and there is no state in which coffee-bar should hold the machine awake for
/// an agent while letting it stop answering. It is tied to the SYSTEM
/// assertion's lifetime and to no setting.
///
/// What it does NOT do is prove reachability. Apple documents it as a
/// suggestion the system may decline under battery or thermal pressure, and it
/// asks for nothing about the network's state. coffee-bar does not probe: no
/// file linked into the app may name an address-shaped API, which
/// `noLinkedTargetCanReachTheNetworkByAddress` enforces.
///
/// ## Why the display assertion is a setting
///
/// Letting the display sleep while the machine stays awake is the product's
/// central difference from `caffeinate -d` and KeepingYouAwake (design §6.1):
/// an agent can keep working through the night without the screen burning power
/// all night with it. Issue #12 asked whether that is a product PROMISE or a
/// DEFAULT, and the answer is a default — some work is worth watching.
///
/// So it stays off unless asked. `displaySleep` comes from
/// `DesiredPowerState.displaySleepAssertion`, which `PowerBroker` grants only
/// alongside the system hold, so the off switch and the battery floor govern
/// the screen exactly as they govern the machine. This type never reads the
/// setting itself: a second reader is a second answer, and the panel would then
/// be able to disagree with IOKit.
///
/// This is the ONE file in the package entitled to name the display assertion.
/// `onlyAssertionHolderMayCreateADisplaySleepAssertion` refuses it in every
/// other file below the app layer, and
/// `theAppLayerNeverNamesADisplaySleepAssertion` refuses it in the app layer
/// outright.
///
/// ## Concurrency
///
/// `@unchecked Sendable` because the assertion ids are mutable reference state.
/// Every access to them goes through `lock`, which is the only synchronisation
/// discipline this type uses, so the unchecked conformance is sound.
public final class AssertionHolder: @unchecked Sendable {

    /// The string `pmset -g assertions` prints for our assertion. Naming the
    /// product here is how a user finds out who is keeping the machine awake.
    public static let assertionName = "coffee-bar is serving"

    /// The same, for the display hold, and a DIFFERENT sentence.
    ///
    /// The two assertions answer different questions for a user reading `pmset
    /// -g assertions`, and one name printed twice tells them the second line is
    /// a duplicate rather than a second thing they turned on.
    public static let displayAssertionName = "coffee-bar is keeping the display awake"

    /// The same again, for the network hold. A THIRD distinct sentence, for the
    /// reason `SECURITY.md` gives: distinct names are how a stranded assertion
    /// is attributed to the code that stranded it.
    ///
    /// It says what the MACHINE is doing, not what coffee-bar is. "coffee-bar
    /// is reachable" would have claimed something this assertion does not ask
    /// for and cannot know — whether anything can actually get here — and a
    /// user reading it in `pmset -g assertions` would take it as a reachability
    /// report rather than a hold.
    public static let networkAssertionName = "coffee-bar is keeping the network up"

    private let lock = NSLock()

    /// The live system assertion, or `nil` when nothing is held. This doubles
    /// as the `isHeld` flag so the two can never disagree.
    private var assertionID: IOPMAssertionID?

    /// The live display assertion, or `nil` when the hold is off.
    ///
    /// A SEPARATE id, never folded into the one above. The two have different
    /// lifetimes: the setting can go off while the machine is still held, and a
    /// single id could not release one without releasing both.
    private var displayAssertionID: IOPMAssertionID?

    /// The live network assertion, or `nil` when nothing is held.
    ///
    /// A separate id again, though this one shares the SYSTEM assertion's
    /// lifetime rather than the display assertion's — it is taken and retired
    /// with the machine hold, and no setting governs it. Kept separate anyway
    /// because IOKit hands back one id per assertion and only a stored id can
    /// ever be released.
    private var networkAssertionID: IOPMAssertionID?

    public init() {}

    deinit {
        // A stranded assertion outlives the object and keeps the machine awake
        // until the process exits, with nothing left to release it. A stranded
        // DISPLAY assertion is worse: it burns the battery visibly while the
        // panel reports nothing held.
        release()
    }

    /// Whether an assertion is currently registered with IOKit.
    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }

    /// Brings IOKit in line with the state asked for: the system and network
    /// assertions held, and the display assertion held only while
    /// `displaySleep` is true.
    ///
    /// RECONCILING and not merely additive. `ServingModel.refresh()` calls this
    /// on every tick and on every hook event, and it never calls `release()`
    /// for a setting change, because the machine is still being held. So the
    /// DOWNGRADE — the user unticking the box while an agent works — has to
    /// happen here, or the screen stays lit until the app quits.
    ///
    /// Idempotent in both directions: creating a second assertion of either
    /// kind would leak the first, since only one id of each can be stored and
    /// only a stored id can ever be released.
    ///
    /// - Parameter displaySleep: `DesiredPowerState.displaySleepAssertion`.
    ///   Never a setting read here — `PowerBroker` already weighed the off
    ///   switch and the battery floor against it.
    /// - Returns: `true` if the MACHINE is held once the call returns. A
    ///   display or network assertion IOKit refuses does not make this `false`:
    ///   the hold this product exists for is up, and `isServing` states that
    ///   honestly.
    @discardableResult
    public func acquire(displaySleep: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if assertionID == nil {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.assertionName as CFString,
                &newID)

            // Nothing is held, so the display assertion is not taken either.
            // A screen pinned awake beside a machine free to sleep is the one
            // combination no user asked for.
            guard result == kIOReturnSuccess else { return false }
            assertionID = newID
        }

        // Alongside the machine hold, and governed by no setting: a machine
        // held awake for an agent someone reaches over SSH is being held for
        // nothing if it stops answering. Deliberately NOT inside the
        // `displaySleep` branch below — the screen and the network are
        // unrelated, and the shipped default has the display hold OFF.
        //
        // Its own `nil` check rather than a place inside the block above, so a
        // create IOKit refused once is retried on the next `refresh()` tick
        // instead of being lost for the rest of the serving stretch.
        //
        // Unreached when the system create failed, because that path returns
        // above: a machine free to sleep must not advertise itself as serving
        // remote clients.
        if networkAssertionID == nil {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertNetworkClientActive as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.networkAssertionName as CFString,
                &newID)
            // A refusal here does not make the call `false`, for the same
            // reason the display assertion's does not: the hold this product
            // exists for is up. Apple documents this assertion as a suggestion
            // the system may decline under battery or thermal pressure, so a
            // refusal is an expected outcome and not a broken hold.
            if result == kIOReturnSuccess { networkAssertionID = newID }
        }

        if displaySleep {
            if displayAssertionID == nil {
                var newID = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    Self.displayAssertionName as CFString,
                    &newID)
                if result == kIOReturnSuccess { displayAssertionID = newID }
            }
        } else {
            releaseDisplayAssertion()
        }

        return true
    }

    /// Retires all three assertions. Safe to call when nothing is held, and
    /// safe to call repeatedly — each id is cleared before its release so a
    /// second call cannot hand IOKit an already-released id.
    public func release() {
        lock.lock()
        defer { lock.unlock() }

        releaseDisplayAssertion()
        releaseNetworkAssertion()

        guard let id = assertionID else { return }
        assertionID = nil
        _ = IOPMAssertionRelease(id)
    }

    /// Retires the display assertion alone, leaving the machine held.
    ///
    /// Call with `lock` HELD. It is `private` and has no lock of its own
    /// because `NSLock` is not recursive: taking the lock here would deadlock
    /// both callers, which already hold it.
    private func releaseDisplayAssertion() {
        guard let id = displayAssertionID else { return }
        displayAssertionID = nil
        _ = IOPMAssertionRelease(id)
    }

    /// Retires the network assertion alone.
    ///
    /// Call with `lock` HELD, for the reason `releaseDisplayAssertion` states:
    /// `NSLock` is not recursive and its caller already holds it.
    ///
    /// Unlike the display one this has no caller in `acquire`, because no
    /// setting can turn it off while the machine is still held. It exists so
    /// `release()` reads as three symmetrical retirements rather than two and
    /// an inline special case.
    private func releaseNetworkAssertion() {
        guard let id = networkAssertionID else { return }
        networkAssertionID = nil
        _ = IOPMAssertionRelease(id)
    }
}
