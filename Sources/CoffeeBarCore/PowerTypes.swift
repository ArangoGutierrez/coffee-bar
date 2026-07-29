// Copyright 2026 Carlos Eduardo Arango Gutierrez
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the machine is drawing power from.
public enum PowerSource: String, Codable, Sendable {
    case ac
    case battery
}

/// What the user last asked for through the menu-bar control.
///
/// Three positions, not a Bool, and `.auto` is the default:
///
///   - `.stop` — never hold. An absolute veto, not merely "the user did not
///     ask". coffee-bar overrides the machine's own sleep policy, so an off
///     switch that an agent session can outrank is a product nobody can trust.
///   - `.serve` — hold, whatever the sessions are doing, subject to the
///     battery floor.
///   - `.auto` — the sessions decide, subject to the battery floor.
///
/// M1 had two cases, and `.stop` then carried both meanings at once: `decide`
/// ORed the toggle with the session predicate, so `.stop` meant "no explicit
/// request" and there was no way to express a veto at all. Splitting the two
/// is what makes an off switch possible. Nothing is released, so there is no
/// stored-value migration to answer for.
///
/// `CaseIterable` so `displaySleepAssertionIsNeverRequested` can sweep every
/// case rather than a hand-written list. That check is the one invariant
/// separating this product from `caffeinate -d`; the list it used to carry was
/// the whole enum until this case arrived, and a fourth case would have
/// narrowed the sweep with nothing going red.
public enum UserIntent: String, Codable, Sendable, CaseIterable {
    case serve
    case stop
    case auto
}

/// Why a requested hold is not being honoured.
///
/// Carries the measured value, not just the case, so the UI can say "battery
/// 18%, floor 20%" rather than something vague the user cannot check.
public enum HoldSuppression: Equatable, Sendable {
    case batteryFloor(percent: Int, floor: Int)
}
