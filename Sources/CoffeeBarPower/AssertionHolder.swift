// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IOKit.pwr_mgt

/// Holds a single `PreventUserIdleSystemSleep` power assertion for as long as
/// coffee-bar is serving.
///
/// ## Why only system sleep
///
/// This deliberately does **not** hold `PreventUserIdleDisplaySleep`. Letting the
/// display sleep while the machine stays awake is the product's central
/// difference from `caffeinate -d` and KeepingYouAwake (design §6.1): an agent
/// can keep working through the night without the screen burning power all
/// night with it. Adding a display assertion here would silently delete that
/// difference, so `AssertionHolder_test.swift` asserts the type set is exactly
/// `["PreventUserIdleSystemSleep"]`.
///
/// ## Concurrency
///
/// `@unchecked Sendable` because `assertionID` is mutable reference state.
/// Every access to it goes through `lock`, which is the only synchronisation
/// discipline this type uses, so the unchecked conformance is sound.
public final class AssertionHolder: @unchecked Sendable {

    /// The string `pmset -g assertions` prints for our assertion. Naming the
    /// product here is how a user finds out who is keeping the machine awake.
    public static let assertionName = "coffee-bar is serving"

    private let lock = NSLock()

    /// The live assertion, or `nil` when nothing is held. This doubles as the
    /// `isHeld` flag so the two can never disagree.
    private var assertionID: IOPMAssertionID?

    public init() {}

    deinit {
        // A stranded assertion outlives the object and keeps the machine awake
        // until the process exits, with nothing left to release it.
        release()
    }

    /// Whether an assertion is currently registered with IOKit.
    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }

    /// Registers the assertion, or does nothing if one is already held.
    ///
    /// Idempotent: creating a second assertion would leak the first, since only
    /// one id can be stored and only a stored id can ever be released.
    ///
    /// - Returns: `true` if an assertion is held once the call returns.
    @discardableResult
    public func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if assertionID != nil { return true }

        var newID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &newID)

        guard result == kIOReturnSuccess else { return false }
        assertionID = newID
        return true
    }

    /// Retires the assertion. Safe to call when nothing is held, and safe to
    /// call repeatedly — the id is cleared before the release so a second call
    /// cannot hand IOKit an already-released id.
    public func release() {
        lock.lock()
        defer { lock.unlock() }

        guard let id = assertionID else { return }
        assertionID = nil
        _ = IOPMAssertionRelease(id)
    }
}
