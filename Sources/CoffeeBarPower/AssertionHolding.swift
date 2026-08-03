// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Injection seam for the power assertion, alongside `PowerReadingProviding`.
///
/// The app layer reconciles a `DesiredPowerState` against this protocol rather
/// than against `AssertionHolder` directly, so the reconcile logic is testable
/// without registering a real IOKit assertion on the machine running the suite.
///
/// This is a seam, not a second implementation: `AssertionHolder` remains the
/// only type that talks to IOKit.
public protocol AssertionHolding: Sendable {
    /// - Parameter displaySleep: `DesiredPowerState.displaySleepAssertion`.
    ///   The flag is a PARAMETER rather than a setting the holder reads, so the
    ///   app layer reconciles one decision object and there is no second reader
    ///   that can answer differently from `PowerBroker`.
    @discardableResult func acquire(displaySleep: Bool) -> Bool
    func release()
}

extension AssertionHolder: AssertionHolding {}
